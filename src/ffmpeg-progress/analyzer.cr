require "./probe"

module FfmpegProgress
  class Input
    property path : String
    property ss : Float64? = nil
    property t : Float64? = nil
    property to : Float64? = nil
    property framerate : Float64? = nil
    property format : String? = nil # -f value if set before -i
    property is_image_sequence : Bool = false
    property is_concat_demux : Bool = false

    def initialize(@path)
    end

    def stdin?
      path == "-" || path == "pipe:" || path == "pipe:0"
    end
  end

  class Output
    property path : String
    property ss : Float64? = nil
    property t : Float64? = nil
    property to : Float64? = nil
    property framerate : Float64? = nil
    property vframes : Int64? = nil
    property is_image_sequence : Bool = false

    def initialize(@path)
    end

    def null_sink?
      path == "-" || path == "/dev/null" || path == "pipe:" || path == "pipe:1"
    end
  end

  # Result of analyzing the ffmpeg command line.
  class Analysis
    enum Mode
      # Multiple inputs muxed/encoded into one or more outputs; effective
      # duration is the *max* of input durations.
      Mux
      # Concat: durations of inputs (or playlist entries) summed.
      Concat
      # Output is an image sequence — we measure progress in frames.
      ImageOutput
      # Input is an image sequence, output is a video — we measure in seconds,
      # with total = frames/framerate.
      ImageInput
      # We can't figure it out; let ffmpeg's own progress print pass through.
      Unknown
    end

    property mode : Mode = Mode::Unknown
    property inputs : Array(Input) = [] of Input
    property outputs : Array(Output) = [] of Output
    property total_duration : Float64? = nil
    property total_frames : Int64? = nil
    property notes : Array(String) = [] of String

    def use_frames? : Bool
      mode == Mode::ImageOutput && !total_frames.nil?
    end
  end

  class Analyzer
    # ffmpeg flags that are pure booleans (no following value).
    BOOLEAN_FLAGS = Set{
      "-y", "-n",
      "-nostdin", "-stdin",
      "-hide_banner",
      "-nostats", "-stats",
      "-shortest", "-noshortest",
      "-an", "-vn", "-sn", "-dn",
      "-copyts", "-copytb",
      "-autorotate", "-noautorotate",
      "-accurate_seek", "-noaccurate_seek",
      "-bitexact", "-recast_media", "-ignore_unknown",
    }

    @debug : Bool

    def initialize(@args : Array(String))
      @debug = ENV["FFMPEG_PROGRESS_DEBUG"]? == "1"
    end

    def analyze : Analysis
      result = Analysis.new
      parse_args(result)
      determine_mode(result)
      result
    end

    private def parse_args(result : Analysis)
      i = 0
      # Per-block stash that attaches to the next -i or the next positional output.
      stash_ss = nil
      stash_t = nil
      stash_to = nil
      stash_r = nil         # -r (rate, input or output)
      stash_framerate = nil # -framerate (input only)
      stash_vframes = nil
      stash_format = nil # -f
      has_filter_concat = false

      while i < @args.size
        arg = @args[i]
        case arg
        when "-i"
          break if i + 1 >= @args.size
          path = @args[i + 1]
          input = Input.new(path)
          input.ss = stash_ss
          input.t = stash_t
          input.to = stash_to
          input.framerate = stash_framerate || stash_r
          input.format = stash_format
          input.is_image_sequence = Probe.image_pattern?(path)
          input.is_concat_demux = (stash_format == "concat")
          result.inputs << input
          stash_ss = stash_t = stash_to = stash_r = stash_framerate = nil
          stash_format = nil
          i += 2
        when "-ss"
          stash_ss = consume_value(i).try(&.to_f?)
          i += 2
        when "-t"
          stash_t = consume_value(i).try(&.to_f?)
          i += 2
        when "-to"
          stash_to = parse_time_spec(consume_value(i))
          i += 2
        when "-framerate"
          stash_framerate = Probe.parse_framerate(consume_value(i) || "")
          i += 2
        when "-r"
          stash_r = Probe.parse_framerate(consume_value(i) || "")
          i += 2
        when "-vframes", "-frames:v"
          stash_vframes = consume_value(i).try(&.to_i64?)
          i += 2
        when "-f"
          stash_format = consume_value(i)
          i += 2
        when "-filter_complex", "-lavfi", "-vf", "-af", "-filter"
          val = consume_value(i) || ""
          has_filter_concat = true if val.includes?("concat=")
          i += 2
        else
          if arg.starts_with?("-")
            # Some flag we don't specifically track. Assume it takes one
            # value unless it's in the known-boolean set.
            if BOOLEAN_FLAGS.includes?(arg)
              i += 1
            else
              # Boolean-looking long flags with embedded `=` shouldn't consume.
              if arg.includes?("=")
                i += 1
              else
                i += 2
              end
            end
          else
            # Positional argument: an output filename.
            output = Output.new(arg)
            output.ss = stash_ss
            output.t = stash_t
            output.to = stash_to
            output.framerate = stash_r
            output.vframes = stash_vframes
            output.is_image_sequence = Probe.image_pattern?(arg)
            result.outputs << output
            stash_ss = stash_t = stash_to = stash_r = stash_framerate = nil
            stash_vframes = nil
            stash_format = nil
            i += 1
          end
        end
      end

      @filter_concat = has_filter_concat
    end

    @filter_concat : Bool = false

    private def consume_value(i : Int32) : String?
      return nil if i + 1 >= @args.size
      @args[i + 1]
    end

    # Accepts "HH:MM:SS[.xxx]" or a plain seconds value.
    private def parse_time_spec(s : String?) : Float64?
      return nil unless s
      s = s.strip
      return nil if s.empty?
      if s.includes?(":")
        parts = s.split(":")
        total = 0.0
        parts.each do |p|
          v = p.to_f?
          return nil unless v
          total = total * 60.0 + v
        end
        return total
      end
      s.to_f?
    end

    private def determine_mode(result : Analysis)
      if result.inputs.empty? || result.outputs.empty?
        result.mode = Analysis::Mode::Unknown
        result.notes << "Could not identify inputs and outputs in ffmpeg arguments." if result.inputs.empty? || result.outputs.empty?
        return
      end

      # A single output that is a single frame (`-vframes 1`, `-update 1` with
      # a single-image output, etc.) isn't worth a progress bar.
      if result.outputs.size == 1 && result.outputs[0].vframes == 1_i64
        result.mode = Analysis::Mode::Unknown
        result.notes << "Single-frame output requested (-vframes 1): no progress bar."
        return
      end

      # Reject inputs we can't probe.
      result.inputs.each do |inp|
        if inp.stdin?
          result.mode = Analysis::Mode::Unknown
          result.notes << "Input from stdin (#{inp.path}) cannot be probed."
          return
        end
        # An image-sequence input is fine — we'll handle below.
        next if inp.is_image_sequence
        next if inp.is_concat_demux
        unless File.exists?(inp.path)
          result.mode = Analysis::Mode::Unknown
          result.notes << "Input '#{inp.path}' does not exist; skipping progress bar."
          return
        end
      end

      # Single output: image sequence → ImageOutput.
      if result.outputs.size == 1 && result.outputs[0].is_image_sequence
        analyze_image_output(result)
        return
      end

      # Concat detection
      if @filter_concat
        analyze_concat(result)
        return
      end

      if result.inputs.size == 1 && result.inputs[0].is_concat_demux
        analyze_concat_demux(result)
        return
      end

      # ImageInput (encoding from an image sequence)
      if result.inputs.any?(&.is_image_sequence)
        analyze_image_input(result)
        return
      end

      # Default: Mux (max of input durations).
      analyze_mux(result)
    end

    private def analyze_mux(result : Analysis)
      durations = [] of Float64
      result.inputs.each do |inp|
        dur = Probe.probe_duration(inp.path)
        next unless dur
        effective = effective_input_duration(inp, dur)
        durations << effective if effective > 0
      end

      if durations.empty?
        result.mode = Analysis::Mode::Unknown
        result.notes << "No input has a probeable duration; falling back to ffmpeg's own progress."
        return
      end

      total = durations.max
      # Clamp by output -t/-to if set.
      result.outputs.each do |outp|
        if t = outp.t
          total = t if t < total
        end
        if to = outp.to
          start = outp.ss || 0.0
          d = to - start
          total = d if d > 0 && d < total
        end
      end

      result.total_duration = total
      result.mode = Analysis::Mode::Mux
    end

    private def analyze_concat(result : Analysis)
      total = 0.0
      missing = false
      result.inputs.each do |inp|
        dur = Probe.probe_duration(inp.path)
        if dur
          total += effective_input_duration(inp, dur)
        else
          missing = true
          break
        end
      end
      if missing || total <= 0
        result.mode = Analysis::Mode::Unknown
        result.notes << "Concat detected but one or more inputs lacked duration; falling back."
        return
      end
      result.total_duration = total
      result.mode = Analysis::Mode::Concat
    end

    private def analyze_concat_demux(result : Analysis)
      inp = result.inputs[0]
      files = Probe.parse_concat_list(inp.path)
      if files.empty?
        result.mode = Analysis::Mode::Unknown
        result.notes << "Concat playlist '#{inp.path}' is empty or unreadable."
        return
      end
      total = 0.0
      files.each do |f|
        d = Probe.probe_duration(f)
        unless d
          result.mode = Analysis::Mode::Unknown
          result.notes << "Could not probe duration of '#{f}' in concat playlist."
          return
        end
        total += d
      end
      result.total_duration = total
      result.mode = Analysis::Mode::Concat
    end

    private def analyze_image_input(result : Analysis)
      # Find the (first) image-sequence input.
      img = result.inputs.find(&.is_image_sequence)
      return unless img
      frames = Probe.count_image_frames(img.path)
      if frames.nil? || frames <= 0
        result.mode = Analysis::Mode::Unknown
        result.notes << "Could not enumerate frames matching '#{img.path}'."
        return
      end
      fps = img.framerate || 25.0
      duration = frames.to_f / fps
      result.total_duration = duration
      result.total_frames = frames.to_i64
      result.mode = Analysis::Mode::ImageInput
    end

    private def analyze_image_output(result : Analysis)
      # Compute effective input duration (max over inputs).
      durations = [] of Float64
      input_frames_total : Int64? = nil
      result.inputs.each do |inp|
        if inp.is_image_sequence
          fc = Probe.count_image_frames(inp.path)
          if fc && fc > 0
            input_frames_total = fc.to_i64
            fps = inp.framerate || 25.0
            durations << fc.to_f / fps
          end
        else
          dur = Probe.probe_duration(inp.path)
          if dur
            durations << effective_input_duration(inp, dur)
          end
        end
      end

      if durations.empty?
        result.mode = Analysis::Mode::Unknown
        result.notes << "Image output requested but no input duration could be determined."
        return
      end
      duration = durations.max

      out = result.outputs[0]

      # Determine output framerate. If output has -r, use it. Otherwise inherit
      # from the (first non-image) input's avg framerate.
      output_fps = out.framerate
      if !output_fps
        result.inputs.each do |inp|
          next if inp.is_image_sequence
          fps = Probe.probe_framerate(inp.path)
          if fps && fps > 0
            output_fps = fps
            break
          end
        end
      end

      # Clamp by output -t.
      if t = out.t
        duration = t if t < duration
      end

      # If a vframes cap is set, use that directly.
      if vf = out.vframes
        result.total_frames = vf
        result.total_duration = output_fps ? (vf.to_f / output_fps) : duration
        result.mode = Analysis::Mode::ImageOutput
        return
      end

      if output_fps && output_fps > 0
        result.total_frames = (duration * output_fps).round.to_i64
      end
      result.total_duration = duration
      result.mode = Analysis::Mode::ImageOutput
    end

    # Apply -ss / -t / -to to a file's measured duration.
    private def effective_input_duration(inp : Input, dur : Float64) : Float64
      start = inp.ss || 0.0
      endtime = dur
      if t = inp.t
        endtime = start + t
      elsif to = inp.to
        endtime = to
      end
      endtime = dur if endtime > dur
      v = endtime - start
      v < 0 ? 0.0 : v
    end
  end
end
