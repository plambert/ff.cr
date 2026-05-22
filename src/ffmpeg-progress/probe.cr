module FfmpegProgress
  module Probe
    extend self

    # `30000/1001`, `30/1`, `30` → Float64 fps. Returns nil if unparseable
    # or "0/0" (the ffprobe sentinel for unknown).
    def parse_framerate(s : String) : Float64?
      s = s.strip
      return nil if s.empty? || s == "0/0" || s == "N/A"
      if s.includes?("/")
        num_str, _, den_str = s.partition("/")
        num = num_str.to_f?
        den = den_str.to_f?
        return nil unless num && den && den != 0.0
        return num / den
      end
      s.to_f?
    end

    def probe_duration(path : String) : Float64?
      out_io = IO::Memory.new
      status = Process.run(
        "ffprobe", [
          "-v", "error",
          "-show_entries", "format=duration",
          "-of", "default=noprint_wrappers=1:nokey=1",
          path,
        ],
        output: out_io,
        error: Process::Redirect::Close,
        input: Process::Redirect::Close
      )
      return nil unless status.success?
      v = out_io.to_s.strip
      return nil if v.empty? || v == "N/A"
      v.to_f?
    rescue
      nil
    end

    def probe_framerate(path : String) : Float64?
      out_io = IO::Memory.new
      status = Process.run(
        "ffprobe", [
          "-v", "error",
          "-select_streams", "v:0",
          "-show_entries", "stream=avg_frame_rate",
          "-of", "default=noprint_wrappers=1:nokey=1",
          path,
        ],
        output: out_io,
        error: Process::Redirect::Close,
        input: Process::Redirect::Close
      )
      return nil unless status.success?
      parse_framerate(out_io.to_s)
    rescue
      nil
    end

    # Detect ffmpeg image-sequence pattern: contains a printf-style `%[0]Nd`.
    # Note: ffmpeg also accepts `%d` with optional width, optional leading zero.
    IMAGE_PATTERN_RE = /%0?\d*d/

    def image_pattern?(path : String) : Bool
      !!(path =~ IMAGE_PATTERN_RE)
    end

    # Convert `frame_%06d.png` → `frame_*.png` for globbing.
    def image_pattern_to_glob(path : String) : String
      path.gsub(IMAGE_PATTERN_RE, "*")
    end

    def count_image_frames(pattern : String) : Int32?
      glob = image_pattern_to_glob(pattern)
      # Crystal's Dir.glob escapes special chars in the literal portion correctly
      # for typical filenames; we accept whatever it returns.
      files = Dir.glob(glob)
      files.size
    rescue
      nil
    end

    # Parse the concat-demuxer playlist format: lines `file 'path'`. Returns
    # absolute paths resolved against the playlist's own directory.
    def parse_concat_list(path : String) : Array(String)
      files = [] of String
      base_dir = File.dirname(path)
      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        next unless line.starts_with?("file ") || line.starts_with?("file\t")
        rest = line[5..].strip
        # Strip surrounding single or double quotes (ffmpeg accepts both).
        if rest.size >= 2 &&
           ((rest[0] == '\'' && rest[-1] == '\'') ||
           (rest[0] == '"' && rest[-1] == '"'))
          rest = rest[1..-2]
        end
        next if rest.empty?
        rest = File.expand_path(rest, base_dir) unless Path.new(rest).absolute?
        files << rest
      end
      files
    rescue
      [] of String
    end
  end
end
