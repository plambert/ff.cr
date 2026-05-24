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

    # ASCII fallback for terminals whose locale isn't UTF-8 — the empty/full
    # cells are still distinguishable without any non-ASCII bytes.
    ASCII_FULL_BLOCK     = "#"
    ASCII_PARTIAL_BLOCKS = ["1", "2", "3", "4", "5", "6", "7"]
    ASCII_EMPTY          = "."

    # Best-effort detection of whether the controlling locale will render
    # Unicode block characters. Returns true if LC_ALL / LC_CTYPE / LANG
    # advertises UTF-8 (case-insensitive). A wholly unset locale defaults to
    # true since modern interactive terminals are UTF-8.
    def self.utf8_locale? : Bool
      saw_any = false
      {"LC_ALL", "LC_CTYPE", "LANG"}.each do |name|
        val = ENV[name]?
        next if val.nil? || val.empty?
        saw_any = true
        v = val.downcase
        return true if v.includes?("utf-8") || v.includes?("utf8")
      end
      !saw_any
    end

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
