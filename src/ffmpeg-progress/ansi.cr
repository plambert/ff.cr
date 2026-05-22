module FfmpegProgress
  module Ansi
    # Foreground green + background gray (bright black). The gray background
    # is critical: partial Unicode blocks are left-aligned glyphs, so the
    # right portion of a partial cell shows the background — making it gray
    # so the bar has no gap between the filled and unfilled portions.
    BAR_COLORS  = "\e[32;100m"
    RESET       = "\e[0m"
    HIDE_CURSOR = "\e[?25l"
    SHOW_CURSOR = "\e[?25h"
    CLEAR_LINE  = "\e[2K\r"

    FULL_BLOCK     = "█"
    PARTIAL_BLOCKS = ["▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    def self.terminal_width(default : Int32 = 80) : Int32
      if cols = ENV["COLUMNS"]?.try(&.to_i?)
        return cols if cols > 0
      end

      tty = nil
      begin
        tty = File.open("/dev/tty", "r")
      rescue
      end

      output = IO::Memory.new
      input_io = tty || STDIN
      status = Process.run(
        "stty", ["size"],
        input: input_io,
        output: output,
        error: Process::Redirect::Close
      )
      tty.try(&.close)

      if status.success?
        parts = output.to_s.strip.split
        if parts.size == 2
          cols = parts[1].to_i?
          return cols if cols && cols > 0
        end
      end

      default
    rescue
      default
    end
  end
end
