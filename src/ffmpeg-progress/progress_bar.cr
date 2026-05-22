require "./ansi"

module FfmpegProgress
  class ProgressBar
    property total_duration : Float64? = nil
    property total_frames : Int64? = nil
    property frames_based : Bool = false
    property started_at : Time::Instant = Time.instant
    property no_color : Bool = false

    @out_time : Float64 = 0.0
    @frame : Int64 = 0

    def update_out_time(seconds : Float64)
      @out_time = seconds
    end

    def update_frame(frame : Int64)
      @frame = frame
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

      prefix = sprintf(" %5.1f%%    %s -> ETA %s ",
        pct,
        fmt_time(elapsed.total_seconds),
        fmt_time(eta_seconds))

      bar_width = width - prefix.size
      return prefix if bar_width <= 0

      bar = render_bar(bar_width, pct)
      prefix + bar
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

      if no_color
        String.build do |s|
          s << Ansi::FULL_BLOCK * full
          s << Ansi::PARTIAL_BLOCKS[partial_eighths - 1] if partial_eighths > 0
          s << "." * empty
        end
      else
        String.build do |s|
          s << Ansi::BAR_COLORS
          s << Ansi::FULL_BLOCK * full
          s << Ansi::PARTIAL_BLOCKS[partial_eighths - 1] if partial_eighths > 0
          # Empty cells: spaces, which show only the gray background.
          s << " " * empty
          s << Ansi::RESET
        end
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
