module FfmpegProgress
  {% begin %}
  VERSION = {{ `shards version`.strip.stringify }}
  {% end %}
end

require "./ffmpeg-progress/ansi"
require "./ffmpeg-progress/style_options"
require "./ffmpeg-progress/probe"
require "./ffmpeg-progress/analyzer"
require "./ffmpeg-progress/progress_bar"
require "./ffmpeg-progress/runner"

module FfmpegProgress
  def self.main(argv : Array(String)) : Int32
    options, ffmpeg_args = StyleOptions.parse(argv)
    return 0 if options.show_help || options.show_version

    if ffmpeg_args.empty?
      STDERR.puts "ffp: no ffmpeg arguments given. Use '--' to separate style options from ffmpeg args, e.g. `ffmpeg-progress -- -i in.mp4 out.mp4`."
      return 2
    end

    analysis = Analyzer.new(ffmpeg_args).analyze
    Runner.new(analysis, options, ffmpeg_args).run
  rescue ex : File::NotFoundError
    STDERR.puts "ffp: #{ex.message}"
    127
  rescue ex
    STDERR.puts "ffp: #{ex.class}: #{ex.message}"
    1
  end
end
