require "option_parser"

module FfmpegProgress
  class StyleOptions
    enum StderrMode
      Buffer  # default: capture and dump on non-zero exit
      LogFile # write to file as it arrives
      Console # forward to wrapper's STDERR live
    end

    property stderr_mode : StderrMode = StderrMode::Buffer
    property log_file : String? = nil
    property no_progress : Bool = false
    property no_color : Bool = false
    property ascii : Bool? = nil # nil = auto-detect from locale
    property overlay : Bool = false
    property show_help : Bool = false
    property show_version : Bool = false
    property debug : Bool = false

    # Returns {style_options, ffmpeg_args}.
    # Style options are only parsed at the start of argv. The first non-style
    # arg ends style parsing — either the literal "--" separator (consumed)
    # or any other arg (left in place for ffmpeg).
    def self.parse(argv : Array(String)) : {StyleOptions, Array(String)}
      opts = StyleOptions.new

      style_args = [] of String
      ffmpeg_args = [] of String
      saw_separator = false

      i = 0
      while i < argv.size
        a = argv[i]
        if !saw_separator && a == "--"
          saw_separator = true
          i += 1
          ffmpeg_args = argv[i..].to_a
          break
        elsif !saw_separator && style_option?(a)
          style_args << a
          # Consume value if this option takes one.
          if option_takes_value?(a) && i + 1 < argv.size
            style_args << argv[i + 1]
            i += 1
          end
          i += 1
        else
          # First non-style arg without preceding "--": pass everything (including
          # this arg) through to ffmpeg.
          ffmpeg_args = argv[i..].to_a
          break
        end
      end

      OptionParser.parse(style_args) do |op|
        op.banner = "Usage: ffp [STYLE OPTIONS] -- <ffmpeg args>"

        op.on("--log-file PATH", "Write ffmpeg stderr to PATH instead of buffering") do |path|
          opts.stderr_mode = StderrMode::LogFile
          opts.log_file = path
        end

        op.on("--show-stderr", "Forward ffmpeg stderr to console live (above progress bar)") do
          opts.stderr_mode = StderrMode::Console
        end

        op.on("--no-progress", "Disable the progress bar entirely (pass ffmpeg output through)") do
          opts.no_progress = true
        end

        op.on("--no-color", "Disable ANSI color in the progress bar") do
          opts.no_color = true
        end

        op.on("--ascii", "Use ASCII characters for the bar (auto-detected from locale if unset)") do
          opts.ascii = true
        end

        op.on("--utf8", "Force Unicode block characters for the bar") do
          opts.ascii = false
        end

        op.on("--overlay", "Show ffmpeg's own progress stats line above the bar") do
          opts.overlay = true
        end

        op.on("--debug", "Emit wrapper diagnostics on stderr") do
          opts.debug = true
        end

        op.on("-h", "--help", "Show this help and exit") do
          opts.show_help = true
          STDOUT.puts op.to_s
        end

        op.on("--version", "Show wrapper version and exit") do
          opts.show_version = true
          STDOUT.puts "ffp #{VERSION}"
        end

        op.invalid_option do |flag|
          STDERR.puts "ffp: unknown style option: #{flag}"
          STDERR.puts op.to_s
          exit 2
        end
      end

      {opts, ffmpeg_args}
    end

    private STYLE_OPTIONS_WITH_VALUE = {"--log-file"}
    private STYLE_OPTIONS_BOOLEAN    = {
      "--show-stderr", "--no-progress", "--no-color",
      "--ascii", "--utf8", "--overlay",
      "--debug", "-h", "--help", "--version",
    }

    private def self.style_option?(arg : String) : Bool
      STYLE_OPTIONS_WITH_VALUE.includes?(arg) || STYLE_OPTIONS_BOOLEAN.includes?(arg)
    end

    private def self.option_takes_value?(arg : String) : Bool
      STYLE_OPTIONS_WITH_VALUE.includes?(arg)
    end
  end
end
