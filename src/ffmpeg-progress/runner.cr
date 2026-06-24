require "./ansi"
require "./analyzer"
require "./progress_bar"
require "./style_options"

module FfmpegProgress
  class Runner
    WARMUP    = 2.seconds
    TICK      = 250.milliseconds
    MIN_WIDTH = 40

    def initialize(@analysis : Analysis, @options : StyleOptions, @args : Array(String))
      @bar = ProgressBar.new
      @bar.total_duration = @analysis.total_duration
      @bar.total_frames = @analysis.total_frames
      @bar.frames_based = @analysis.use_frames?
      @bar.no_color = @options.no_color
      ascii_choice = @options.ascii
      @bar.ascii = ascii_choice.nil? ? !Ansi.utf8_locale? : ascii_choice
      @bar_mutex = Mutex.new
      @tty_mutex = Mutex.new
      @stderr_buffer = IO::Memory.new
      @bar_visible = false
    end

    @log_io : File? = nil
    @console_chan : Channel(String)? = nil
    @signal_count : Atomic(Int32) = Atomic(Int32).new(0)
    @overlay_active : Bool = false
    @overlay_text : String? = nil

    def run : Int32
      analysis_notes_to_stderr

      # Decide whether we'll display our own bar. We can't if:
      #   - user passed --no-progress
      #   - the analysis was inconclusive
      #   - stdout isn't a tty
      show_bar = !@options.no_progress &&
                 @analysis.mode != Analysis::Mode::Unknown &&
                 STDOUT.tty?

      # Overlay only makes sense when we're actually drawing a bar.
      @overlay_active = @options.overlay && show_bar

      # When the analyzer couldn't classify the command, fall back to letting
      # ffmpeg's own progress output reach the console — but only for the
      # default Buffer mode; respect an explicit --log-file or --show-stderr.
      effective_stderr_mode =
        if @analysis.mode == Analysis::Mode::Unknown &&
           @options.stderr_mode == StyleOptions::StderrMode::Buffer
          StyleOptions::StderrMode::Console
        else
          @options.stderr_mode
        end

      # Pre-open the log file if needed.
      if effective_stderr_mode == StyleOptions::StderrMode::LogFile
        if path = @options.log_file
          @log_io = File.open(path, "w")
        end
      end

      # Build the argv we'll hand to ffmpeg.
      argv = build_ffmpeg_argv(show_bar)

      if @options.debug
        STDERR.puts "ffp: mode=#{@analysis.mode} duration=#{@analysis.total_duration} frames=#{@analysis.total_frames}"
        STDERR.puts "ffp: bar ascii=#{@bar.ascii} no_color=#{@bar.no_color} utf8_locale=#{Ansi.utf8_locale?} overlay=#{@overlay_active}"
        STDERR.puts "ffp: argv=#{argv.inspect}"
      end

      process = Process.new(
        "ffmpeg", argv,
        input: Process::Redirect::Close,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      install_signal_traps(process)

      progress_done = Channel(Nil).new(1)
      stderr_done = Channel(Nil).new(1)
      done_chan = Channel(Nil).new(1)
      @console_chan = Channel(String).new(64) if effective_stderr_mode == StyleOptions::StderrMode::Console

      # Reader: ffmpeg's -progress output (only meaningful if show_bar)
      spawn do
        begin
          if show_bar
            read_progress(process.output)
          else
            # If we're not showing a bar but -progress wasn't sent, ffmpeg's
            # output pipe is still open; drain it so the process doesn't block.
            process.output.gets_to_end
          end
        rescue ex
          STDERR.puts "ffp: progress reader error: #{ex.message}" if @options.debug
        ensure
          progress_done.send(nil)
        end
      end

      # Reader: ffmpeg stderr
      spawn do
        begin
          read_stderr(process.error, effective_stderr_mode)
        rescue ex
          STDERR.puts "ffp: stderr reader error: #{ex.message}" if @options.debug
        ensure
          stderr_done.send(nil)
        end
      end

      # Process waiter: only signal "all done" after both readers have
      # flushed their pipes, so the display loop continues consuming
      # console-stderr lines until everything is drained.
      status_chan = Channel(Process::Status).new(1)
      spawn do
        status = process.wait
        status_chan.send(status)
        progress_done.receive
        stderr_done.receive
        done_chan.send(nil)
      end

      # Hide cursor for the duration of the bar
      hide_cursor if show_bar

      # Display loop (handles ticks + console stderr; exits when done_chan fires)
      run_display_loop(show_bar, done_chan)

      status = status_chan.receive

      cleanup(show_bar, status, effective_stderr_mode)
      exit_code_from(status)
    end

    # Always return a non-zero status when ffmpeg didn't exit cleanly with 0,
    # so `set -e` in the caller's shell loop catches it. For signal exits we
    # follow the POSIX convention of `128 + signal`.
    private def exit_code_from(status : Process::Status) : Int32
      if status.normal_exit?
        status.exit_code
      elsif sig = status.exit_signal?
        128 + sig.value
      else
        1
      end
    rescue
      status.success? ? 0 : 1
    end

    private def build_ffmpeg_argv(show_bar : Bool) : Array(String)
      argv = [] of String
      # Always disable stdin and hide the banner (per the spec).
      argv << "-nostdin"
      argv << "-hide_banner"
      if show_bar
        # When overlay mode is on, leave ffmpeg's stats line alone: the
        # stderr reader picks it out and parks it above the bar. Otherwise
        # silence it so our own bar isn't competing with `frame= fps= ...`.
        argv << "-nostats" unless @overlay_active
        argv << "-progress"
        argv << "pipe:1"
      end
      argv.concat(@args)
      argv
    end

    private def install_signal_traps(process : Process)
      Signal::INT.trap { handle_termination_signal(process) }
      Signal::TERM.trap { handle_termination_signal(process) }
      Signal::HUP.trap { handle_termination_signal(process) }
    end

    # On the first interrupt we ask ffmpeg to clean up (SIGINT). If a second
    # arrives before ffmpeg has exited, escalate to SIGTERM. On the third we
    # SIGKILL ffmpeg, restore the terminal, and exit ffp immediately so the
    # caller's shell loop (with `set -e`) can break out.
    private def handle_termination_signal(process : Process)
      count = @signal_count.add(1) + 1
      case count
      when 1
        send_signal_safely(process, Signal::INT)
        write_signal_note "interrupt requested; asking ffmpeg to exit (Ctrl-C again to force)"
      when 2
        send_signal_safely(process, Signal::TERM)
        write_signal_note "sending SIGTERM to ffmpeg (Ctrl-C again to force quit)"
      else
        send_signal_safely(process, Signal::KILL)
        restore_terminal
        Process.exit(130) # 128 + SIGINT(2)
      end
    end

    private def send_signal_safely(process : Process, sig : Signal)
      process.signal(sig)
    rescue
      # Process is already gone — nothing to do.
    end

    private def write_signal_note(msg : String)
      # Signal handlers shouldn't grab @tty_mutex (re-entrancy risk). Best
      # effort: just write directly to stderr.
      STDERR.print "\nffp: #{msg}\n" rescue nil
      STDERR.flush rescue nil
    end

    private def restore_terminal
      STDOUT.print "\n#{Ansi::SHOW_CURSOR}" rescue nil
      STDOUT.flush rescue nil
    end

    private def read_progress(io : IO)
      while line = io.gets
        line = line.strip
        next if line.empty?
        key, _, value = line.partition("=")
        next if value.empty?
        @bar_mutex.synchronize do
          case key
          when "out_time_us", "out_time_ms"
            # out_time_us and out_time_ms are both in microseconds despite the
            # name (an ffmpeg quirk). out_time_us is preferred.
            if microseconds = value.to_i64?
              @bar.update_out_time(microseconds / 1_000_000.0)
            end
          when "out_time"
            if seconds = parse_hhmmss(value)
              @bar.update_out_time(seconds)
            end
          when "frame"
            if frame_number = value.to_i64?
              @bar.update_frame(frame_number)
            end
          when "speed"
            # ffmpeg formats this as "2.2x" or "N/A" (rarely a bare number).
            stripped = value.strip
            stripped = stripped[0..-2] if stripped.ends_with?("x")
            if multiplier = stripped.to_f?
              @bar.update_speed(multiplier)
            end
          end
        end
      end
    end

    private def parse_hhmmss(timecode : String) : Float64?
      parts = timecode.split(":")
      return nil if parts.size != 3
      hours = parts[0].to_f?
      minutes = parts[1].to_f?
      seconds = parts[2].to_f?
      return nil unless hours && minutes && seconds
      hours * 3600.0 + minutes * 60.0 + seconds
    end

    private def read_stderr(io : IO, mode : StyleOptions::StderrMode)
      if @overlay_active
        read_stderr_overlay(io, mode)
      else
        while line = io.gets
          dispatch_stderr_line(line, mode)
        end
      end
    end

    # When overlay is on we can't use line-buffered `gets`: ffmpeg's
    # in-progress stats line is terminated by `\r`, not `\n`, so it would
    # never appear as a discrete record. Read char-by-char and split on
    # either terminator, then peel off any `\r`-terminated `frame=…` /
    # `size=…` chunks into the overlay slot. Everything else flows through
    # the normal stderr-mode dispatch.
    private def read_stderr_overlay(io : IO, mode : StyleOptions::StderrMode)
      buffer = IO::Memory.new
      loop do
        char = io.read_char
        if char.nil?
          flush_stderr_chunk(buffer.to_s, '\n', mode) if buffer.size > 0
          break
        end
        if char == '\r' || char == '\n'
          flush_stderr_chunk(buffer.to_s, char, mode)
          buffer.clear
        else
          buffer << char
        end
      end
    end

    private def flush_stderr_chunk(text : String, terminator : Char, mode : StyleOptions::StderrMode)
      return if text.empty? # collapses \r\n, \n\r, repeated \n, etc.

      if terminator == '\r' && progress_stats_line?(text)
        cleaned = text.rstrip
        @bar_mutex.synchronize { @overlay_text = cleaned }
        return
      end

      dispatch_stderr_line(text, mode)
    end

    private def progress_stats_line?(text : String) : Bool
      trimmed = text.lstrip
      trimmed.starts_with?("frame=") ||
        trimmed.starts_with?("size=") ||
        trimmed.starts_with?("fps=")
    end

    private def dispatch_stderr_line(text : String, mode : StyleOptions::StderrMode)
      case mode
      in .buffer?
        @stderr_buffer << text << "\n"
      in .log_file?
        if log = @log_io
          log.puts text
          log.flush
        end
      in .console?
        if chan = @console_chan
          chan.send(text)
        end
      end
    end

    private def run_display_loop(show_bar : Bool, done_chan : Channel(Nil))
      warmup_until = Time.instant + WARMUP
      console_chan = @console_chan

      loop do
        # Decide our wait time. We want to wake up:
        #   - immediately for a console stderr line
        #   - when done_chan fires
        #   - on every TICK once warmed up
        #   - at the warmup boundary if not yet warm
        timeout_dur = if Time.instant < warmup_until
                        warmup_until - Time.instant
                      else
                        TICK
                      end

        if console_chan
          select
          when line = console_chan.receive
            handle_console_line(line, show_bar && warmup_reached?(warmup_until))
          when done_chan.receive
            return
          when timeout(timeout_dur)
            draw_if_ready(show_bar, warmup_until)
          end
        else
          select
          when done_chan.receive
            return
          when timeout(timeout_dur)
            draw_if_ready(show_bar, warmup_until)
          end
        end
      end
    end

    private def warmup_reached?(warmup_until : Time::Instant)
      Time.instant >= warmup_until
    end

    private def draw_if_ready(show_bar : Bool, warmup_until : Time::Instant)
      return unless show_bar
      return if Time.instant < warmup_until
      draw_bar
    end

    private def draw_bar
      width = Ansi.terminal_width
      width = MIN_WIDTH if width < MIN_WIDTH
      bar_line, overlay = @bar_mutex.synchronize { {@bar.render(width), @overlay_text} }
      @tty_mutex.synchronize do
        write_display_block(bar_line, overlay, width)
        STDOUT.flush
        @bar_visible = true
      end
    end

    private def handle_console_line(line : String, redraw : Bool)
      @tty_mutex.synchronize do
        clear_display_block if @bar_visible
        STDERR.puts line
        STDERR.flush
        if redraw
          width = Ansi.terminal_width
          width = MIN_WIDTH if width < MIN_WIDTH
          bar_line, overlay = @bar_mutex.synchronize { {@bar.render(width), @overlay_text} }
          write_display_block(bar_line, overlay, width)
          STDOUT.flush
          @bar_visible = true
        else
          @bar_visible = false
        end
      end
    end

    # Render the bar (and, with overlay, the ffmpeg stats line above it) in
    # place. Expects @tty_mutex held. Assumes that when @bar_visible the
    # cursor is parked at the end of the bar line, and leaves it there.
    private def write_display_block(bar_line : String, overlay : String?, width : Int32)
      if @overlay_active
        if @bar_visible
          # Move up to the overlay line, clear it.
          STDOUT.print "\e[1A\r\e[2K"
        else
          # First draw: just clear whatever was on the current line.
          STDOUT.print "\r\e[2K"
        end
        STDOUT.print truncate_to_width(overlay || "", width)
        # Move down, clear, return to col 0, then draw the bar.
        STDOUT.print "\n\e[2K\r"
        STDOUT.print bar_line
      else
        STDOUT.print "\r\e[2K"
        STDOUT.print bar_line
      end
    end

    # Erase the display block (1 or 2 lines) and park the cursor at column
    # 0 of the *top* line of where the block was. Expects @tty_mutex held.
    private def clear_display_block
      if @overlay_active
        # Cursor is at end of bar; clear bar, move up, clear overlay.
        STDOUT.print "\r\e[2K\e[1A\r\e[2K"
      else
        STDOUT.print Ansi::CLEAR_LINE
      end
      STDOUT.flush
    end

    private def truncate_to_width(text : String, width : Int32) : String
      return text if text.size <= width
      text[0, width]
    end

    private def hide_cursor
      @tty_mutex.synchronize do
        STDOUT.print Ansi::HIDE_CURSOR
        STDOUT.flush
      end
    end

    private def show_cursor
      @tty_mutex.synchronize do
        STDOUT.print Ansi::SHOW_CURSOR
        STDOUT.flush
      end
    end

    private def cleanup(show_bar : Bool, status : Process::Status, mode : StyleOptions::StderrMode)
      @tty_mutex.synchronize do
        if @bar_visible
          width = Ansi.terminal_width
          width = MIN_WIDTH if width < MIN_WIDTH

          if status.success?
            # Snap the bar's state to 100% so the final frame reads cleanly.
            @bar_mutex.synchronize do
              if td = @bar.total_duration
                @bar.update_out_time(td)
              end
              if tf = @bar.total_frames
                @bar.update_frame(tf)
              end
            end
            bar_line, overlay = @bar_mutex.synchronize { {@bar.render(width), @overlay_text} }
            write_display_block(bar_line, overlay, width)
            # One \n to step past the bar line. With overlay, the cursor was
            # on the bar line so a single \n still lands us below the block.
            STDOUT.puts
          else
            # Failure: erase the display block entirely. clear_display_block
            # leaves us at the start of the top line of the block, so a
            # single \n per cleared line gets us past it.
            clear_display_block
            STDOUT.puts
            STDOUT.puts if @overlay_active
          end
          STDOUT.flush
        end
        STDOUT.print Ansi::SHOW_CURSOR if show_bar
        STDOUT.flush
      end

      # Close the log file if we opened one.
      if log = @log_io
        log.flush rescue nil
        log.close rescue nil
      end

      # If buffered and ffmpeg failed, dump captured stderr to STDOUT.
      if mode.buffer? && !status.success?
        STDOUT.write(@stderr_buffer.to_slice)
        STDOUT.flush
      end
    end

    private def analysis_notes_to_stderr
      @analysis.notes.each do |note|
        STDERR.puts "ffp: #{note}"
      end
    end
  end
end
