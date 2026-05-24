require "./ansi"

module FfmpegProgress
  class ProgressBar
    property total_duration : Float64? = nil
    property total_frames : Int64? = nil
    property frames_based : Bool = false
    property started_at : Time::Instant = Time.instant
    property no_color : Bool = false
    property ascii : Bool = false

    # Smoothing factor for the EMA on `speed`. Smaller = smoother but slower
    # to react; 0.3 is a reasonable compromise on ffmpeg's ~0.5s cadence.
    property speed_alpha : Float64 = 0.3

    # Most recent smoothed encoding speed reported by ffmpeg, in seconds of
    # output produced per second of wall time (e.g. 2.2 == "2.2x"). nil until
    # ffmpeg emits its first speed sample.
    property speed : Float64? = nil

    @out_time : Float64 = 0.0
    @frame : Int64 = 0

    def update_out_time(seconds : Float64) : Nil
      @out_time = seconds
    end

    def update_frame(frame : Int64) : Nil
      @frame = frame
    end

    # Apply a fresh raw `speed` sample from ffmpeg, blending it with the
    # existing smoothed value via an exponential moving average.
    def update_speed(raw : Float64) : Nil
      return unless raw.finite? && raw >= 0
      if current = @speed
        @speed = @speed_alpha * raw + (1.0 - @speed_alpha) * current
      else
        @speed = raw
      end
    end

    def percent : Float64
      if frames_based
        if (tf = total_frames) && tf > 0
          return (100.0 * @frame / tf).clamp(0.0, 100.0)
        end
      else
        if (td = total_duration) && td > 0
          return (100.0 * @out_time / td).clamp(0.0, 100.0)
        end
      end
      0.0
    end

    # Render the full line to fit `width` columns.
    def render(width : Int32) : String
      pct = percent
      elapsed = Time.instant - started_at
      eta_seconds = compute_eta(pct, elapsed.total_seconds)

      prefix = sprintf(" %5.1f%%    %s -> ETA %s @ %s ",
        pct,
        fmt_time(elapsed.total_seconds),
        fmt_time(eta_seconds),
        fmt_speed(@speed))

      bar_width = width - prefix.size
      return prefix if bar_width <= 0

      bar = render_bar(bar_width, pct)
      prefix + bar
    end

    # Right-padded 5-char speed slot so prefix width stays stable across
    # updates: "0.04x", "1.23x", "12.5x", "  47x", " 425x", "    -".
    SPEED_SLOT_WIDTH = 5

    def fmt_speed(value : Float64?) : String
      return "%#{SPEED_SLOT_WIDTH}s" % "-" if value.nil? || !value.finite? || value < 0

      # Thresholds are chosen so the formatted string is always <= 5 chars,
      # even after rounding (e.g. 99.95 must not become "100.0x").
      formatted =
        if value >= 99.95
          sprintf("%.0fx", value)
        elsif value >= 9.995
          sprintf("%.1fx", value)
        else
          sprintf("%.2fx", value)
        end

      "%#{SPEED_SLOT_WIDTH}s" % formatted
    end

    private def render_bar(width : Int32, pct : Float64) : String
      filled_cells = (width * (pct / 100.0)).clamp(0.0, width.to_f)
      full = filled_cells.to_i
      frac = filled_cells - full
      partial_eighths = (frac * 8.0).round.to_i
      if partial_eighths >= 8
        full += 1
        partial_eighths = 0
      end
      full = width if full > width
      empty = width - full - (partial_eighths > 0 ? 1 : 0)
      empty = 0 if empty < 0

      full_block = ascii ? Ansi::ASCII_FULL_BLOCK : Ansi::FULL_BLOCK
      partial_blocks = ascii ? Ansi::ASCII_PARTIAL_BLOCKS : Ansi::PARTIAL_BLOCKS
      # When ASCII, paint the empty portion with a visible char so the bar's
      # extent is obvious even without the gray background trick.
      empty_char = if no_color || ascii
                     ascii ? Ansi::ASCII_EMPTY : "."
                   else
                     " "
                   end

      String.build do |s|
        s << Ansi::BAR_COLORS unless no_color
        s << full_block * full
        s << partial_blocks[partial_eighths - 1] if partial_eighths > 0
        s << empty_char * empty
        s << Ansi::RESET unless no_color
      end
    end

    private def compute_eta(pct : Float64, elapsed_sec : Float64) : Float64
      return 0.0 if pct >= 100.0
      return Float64::INFINITY if pct <= 0.0 || !pct.finite?
      total = elapsed_sec / (pct / 100.0)
      remaining = total - elapsed_sec
      remaining < 0 ? 0.0 : remaining
    end

    # Format seconds as "M:SS" or "H:MM:SS".
    def fmt_time(seconds : Float64) : String
      return "--:--" unless seconds.finite? && seconds >= 0
      total = seconds.to_i
      hours = total // 3600
      mins = (total % 3600) // 60
      secs = total % 60
      if hours > 0
        sprintf("%d:%02d:%02d", hours, mins, secs)
      else
        sprintf("%d:%02d", mins, secs)
      end
    end
  end
end
