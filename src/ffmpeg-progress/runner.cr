require "./ansi"
require "./analyzer"
require "./progress_bar"
require "./style_options"

module FfmpegProgress
  class Runner
    WARMUP   = 2.seconds
    TICK     = 250.milliseconds
    MIN_WIDTH = 40

    def initialize(@analysis : Analysis, @options : StyleOptions, @args : Array(String))
      @bar = ProgressBar.new
      @bar.total_duration = @analysis.total_duration
      @bar.total_frames = @analysis.total_frames
      @bar.frames_based = @analysis.use_frames?
      @bar.no_color = @options.no_color
      @bar_mutex = Mutex.new
      @tty_mutex = Mutex.new
      @stderr_buffer = IO::Memory.new
      @bar_visible = false
    end

    @log_io : File? = nil
    @console_chan : Channel(String)? = nil

    def run : Int32
      analysis_notes_to_stderr

      # Decide whether we'll display our own bar. We can't if:
      #   - user passed --no-progress
      #   - the analysis was inconclusive
      #   - stdout isn't a tty
      show_bar = !@options.no_progress &&
                 @analysis.mode != Analysis::Mode::Unknown &&
                 STDOUT.tty?

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
        path = @options.log_file.not_nil!
        @log_io = File.open(path, "w")
      end

      # Build the argv we'll hand to ffmpeg.
      argv = build_ffmpeg_argv(show_bar)

      if @options.debug
        STDERR.puts "ffmpeg-progress: mode=#{@analysis.mode} duration=#{@analysis.total_duration} frames=#{@analysis.total_frames}"
        STDERR.puts "ffmpeg-progress: argv=#{argv.inspect}"
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
          STDERR.puts "ffmpeg-progress: progress reader error: #{ex.message}" if @options.debug
        ensure
          progress_done.send(nil)
        end
      end

      # Reader: ffmpeg stderr
      spawn do
        begin
          read_stderr(process.error, effective_stderr_mode)
        rescue ex
          STDERR.puts "ffmpeg-progress: stderr reader error: #{ex.message}" if @options.debug
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
      status.exit_code
    end

    private def build_ffmpeg_argv(show_bar : Bool) : Array(String)
      argv = [] of String
      # Always disable stdin and hide the banner (per the spec).
      argv << "-nostdin"
      argv << "-hide_banner"
      if show_bar
        # Suppress the noisy `frame= fps= ...` lines from stderr; our bar
        # replaces them. ffmpeg's -progress stream goes to pipe:1.
        argv << "-nostats"
        argv << "-progress"
        argv << "pipe:1"
      end
      argv.concat(@args)
      argv
    end

    private def install_signal_traps(process : Process)
      Signal::INT.trap do
        forward_signal(process, Signal::INT)
      end
      Signal::TERM.trap do
        forward_signal(process, Signal::TERM)
      end
      Signal::WINCH.trap do
        # No-op; we re-read terminal width on every draw.
      end
    end

    private def forward_signal(process : Process, sig : Signal)
      begin
        process.signal(sig)
      rescue
      end
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
            if v = value.to_i64?
              @bar.update_out_time(v / 1_000_000.0)
            end
          when "out_time"
            if t = parse_hhmmss(value)
              @bar.update_out_time(t)
            end
          when "frame"
            if v = value.to_i64?
              @bar.update_frame(v)
            end
          end
        end
      end
    end

    private def parse_hhmmss(s : String) : Float64?
      parts = s.split(":")
      return nil if parts.size != 3
      h = parts[0].to_f?
      m = parts[1].to_f?
      sec = parts[2].to_f?
      return nil unless h && m && sec
      h * 3600.0 + m * 60.0 + sec
    end

    private def read_stderr(io : IO, mode : StyleOptions::StderrMode)
      while line = io.gets
        case mode
        in .buffer?
          @stderr_buffer << line << "\n"
        in .log_file?
          if log = @log_io
            log.puts line
            log.flush
          end
        in .console?
          if chan = @console_chan
            chan.send(line)
          end
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
      line = @bar_mutex.synchronize { @bar.render(width) }
      @tty_mutex.synchronize do
        STDOUT.print "\r"
        STDOUT.print line
        STDOUT.flush
        @bar_visible = true
      end
    end

    private def handle_console_line(line : String, redraw : Bool)
      @tty_mutex.synchronize do
        if @bar_visible
          STDOUT.print Ansi::CLEAR_LINE
          STDOUT.flush
        end
        STDERR.puts line
        STDERR.flush
        if redraw
          width = Ansi.terminal_width
          width = MIN_WIDTH if width < MIN_WIDTH
          bar_line = @bar_mutex.synchronize { @bar.render(width) }
          STDOUT.print "\r"
          STDOUT.print bar_line
          STDOUT.flush
          @bar_visible = true
        else
          @bar_visible = false
        end
      end
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
          if status.success?
            # Final draw at 100% then newline.
            @bar_mutex.synchronize do
              if td = @bar.total_duration
                @bar.update_out_time(td)
              end
              if tf = @bar.total_frames
                @bar.update_frame(tf)
              end
            end
            width = Ansi.terminal_width
            width = MIN_WIDTH if width < MIN_WIDTH
            STDOUT.print "\r"
            STDOUT.print @bar_mutex.synchronize { @bar.render(width) }
          else
            STDOUT.print Ansi::CLEAR_LINE
          end
          STDOUT.puts
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
        STDERR.puts "ffmpeg-progress: #{note}"
      end
    end
  end
end
