# ffmpeg-progress

A small Crystal wrapper around `ffmpeg` that draws a clean, single-line
progress bar — autosized to the terminal, with sub-cell resolution via
Unicode partial blocks — and that keeps `ffmpeg`'s own stderr out of the way
unless something goes wrong.

```text
 12.3%    10:31 -> ETA 15:11 @ 2.20x ███████████████▎
```

The `@ N.NNx` field is `ffmpeg`'s reported encoding speed (seconds of
output produced per second of wall time), smoothed by an exponential
moving average so it doesn't twitch frame-to-frame. It uses a fixed
5-character slot (`0.04x` … ` 100x` … `1234x`) so the bar doesn't shift
when the value first arrives or rolls between magnitudes.

The bar is green on a gray background (so partial blocks meet the empty
portion flush, with no gap). It shows percent complete, elapsed time, and
estimated time remaining. Update rate is 4 Hz; the bar only appears once a
job has been running for at least 2 seconds, so quick one-shots don't flash
a half-drawn bar.

## What it figures out

Before launching `ffmpeg`, the wrapper inspects the argument list (and runs
`ffprobe` against the inputs) to decide what "100%" means:

| Case | Detection | Total |
|------|-----------|-------|
| Mux / single output | one or more video/audio inputs → single output | `max(input durations)`, clamped by output `-t` / `-to` |
| Concat (filter) | `-filter_complex` (or `-vf` / `-lavfi`) contains `concat=` | sum of input durations |
| Concat (demuxer) | `-f concat -i list.txt` | sum of durations of files in the playlist |
| Image sequence input | input path matches `frame_%06d.png` etc. | `frame_count / framerate` |
| Image sequence output | output path matches `frame_%06d.png` etc. | total frames (frame-based progress) |
| Unknown / can't tell | any of the above can't be determined | no bar; ffmpeg's own progress is forwarded |

When the wrapper falls back to "unknown", it prints a short note on its
stderr explaining why, then lets `ffmpeg`'s own stderr (which includes its
native progress chatter) pass through.

## Always-applied flags

The wrapper always inserts the following before your `ffmpeg` arguments:

* `-nostdin` — disable stdin so `ffmpeg` doesn't try to read keypresses
* `-hide_banner` — suppress the version/build header

When a progress bar will be drawn it additionally adds:

* `-nostats` — silence `ffmpeg`'s own `frame= ... time= ...` chatter on stderr
* `-progress pipe:1` — emit machine-readable progress on stdout (the wrapper
  consumes it; nothing leaks to the caller)

## Building

Requires Crystal `>= 1.20.2`, and `ffmpeg` + `ffprobe` on `PATH` at runtime.

```sh
shards build --release
```

The binary is written to `bin/ffmpeg-progress`. Drop it on your `PATH` or
symlink it.

For a debug/dev build, just:

```sh
shards build
# or
crystal build src/ffmpeg-progress.cr -o bin/ffmpeg-progress
```

To run the spec suite:

```sh
crystal spec
```

## Usage

```text
ffmpeg-progress [STYLE OPTIONS] -- <ffmpeg args>
```

Style options are accepted **only at the start** of the argv, and must be
terminated by `--` before the `ffmpeg` arguments begin. (If no `--` is
present and the first argument doesn't look like a style option, the rest
of the argv is passed straight through to `ffmpeg`.)

### Style options

| Option | Effect |
|--------|--------|
| `--log-file PATH` | Write `ffmpeg`'s stderr to `PATH` as it arrives, instead of buffering. |
| `--show-stderr` | Forward `ffmpeg`'s stderr to the wrapper's stderr live, with the progress bar cleared/redrawn around each line so the display stays tidy. |
| `--no-progress` | Disable the progress bar; behave as a near-passthrough (but still apply `-nostdin -hide_banner`). |
| `--no-color` | Render the bar without ANSI color (uses `.` for empty cells). |
| `--ascii` | Render the bar with plain ASCII (`#` filled, `1`–`7` for partials, `.` empty). Auto-selected when the locale isn't UTF-8. |
| `--utf8` | Force Unicode block characters even if the locale doesn't advertise UTF-8. |
| `--overlay` | Show `ffmpeg`'s own `frame=… fps=… time=… speed=…` stats line on the line *above* the bar, updated in place. |
| `--debug` | Print a one-line summary of the detected mode, total duration/frames, locale/bar choices, and the actual argv passed to `ffmpeg`. |
| `-h`, `--help` | Print help and exit. |
| `--version` | Print version and exit. |

### Default stderr behavior

By default the wrapper **buffers** everything `ffmpeg` writes to stderr.
On a successful exit (`0`), the buffer is silently discarded. On a non-zero
exit, the buffer is flushed to **stdout** so the error reaches the user
(this also makes it easy to capture: `ffmpeg-progress ... > error.log`).

`--log-file` and `--show-stderr` override this.

When the wrapper falls back to "unknown" mode (no bar), and you haven't
explicitly chosen `--log-file`, it switches to live-stderr automatically —
otherwise you'd see no progress at all.

### Overlay

`--overlay` shows `ffmpeg`'s own progress stats line on a second row,
right above the bar:

```text
frame= 864 fps= 54 q=24.0 size= 256KiB time=00:00:28.73 bitrate= 73.0kbits/s …
 95.8%    0:16 -> ETA 0:00 @ 1.76x ██████████████████████████████████████████▏
```

With overlay on, the wrapper drops the `-nostats` flag so `ffmpeg` keeps
emitting its in-place stats line; the wrapper reads it off stderr (char
by char, since those lines end in `\r` rather than `\n`), parks the
latest one in the slot above the bar, and re-renders both rows on each
tick. Non-stats stderr (info, warnings, errors) still flows through the
normal `--log-file` / `--show-stderr` / buffer-on-failure paths. The
overlay line is truncated to the terminal width so it can't wrap and
break cursor positioning.

### Locale and character set

By default the bar uses Unicode block characters (`█`, `▏`–`▉`) for
sub-cell resolution and writes a green-on-gray ANSI region so partial
cells meet the empty portion with no gap. If the controlling locale isn't
UTF-8 (`LC_ALL` / `LC_CTYPE` / `LANG` doesn't advertise it), the wrapper
falls back to an ASCII bar (`#` fill, `1`–`7` partials, `.` empty) so the
terminal doesn't render the block bytes as `?`. Use `--ascii` or `--utf8`
to force the choice; `--debug` reports which was selected.

### Examples

Re-encode a file, with progress:

```sh
ffmpeg-progress -- -y -i in.mp4 -vf scale=-1:720 -c:v libx264 -crf 18 \
  -preset slow -c:a copy out.mp4
```

Extract a PNG sequence (frame-based progress):

```sh
ffmpeg-progress -- -i in.mp4 -qscale:v 1 -qmin 1 frames/frame_%06d.png
```

Encode from a PNG sequence (sums up the directory's frame count):

```sh
ffmpeg-progress -- -framerate 30 -i frames/frame_%06d.png \
  -i in.mp4 -map 0:v -map 1:a\? -c:v libx264 -crf 18 -pix_fmt yuv420p out.mp4
```

Two-pass GIF (palettegen then paletteuse), each gets its own bar:

```sh
ffmpeg-progress -- -ss 10 -t 5 -i in.mp4 -filter_complex "[0:v]palettegen" pal.png
ffmpeg-progress -- -ss 10 -t 5 -i in.mp4 -i pal.png \
  -filter_complex "[0:v][1:v]paletteuse" out.gif
```

Send `ffmpeg`'s stderr to a log file while the bar is on screen:

```sh
ffmpeg-progress --log-file encode.log -- -y -i in.mp4 -c copy out.mkv
```

Pass-through mode (no bar, no buffering, just the always-applied flags):

```sh
ffmpeg-progress --no-progress --show-stderr -- -i in.mp4 -f null -
```

### Exit status and interrupts

The wrapper exits with `ffmpeg`'s exit status. `2` is used for its own
argument-parsing errors (e.g. nothing after `--`). When `ffmpeg` is killed
by a signal, the wrapper exits with `128 + signal_number` (POSIX
convention) — so `set -e` in a shell loop will always see a non-zero
status and bail out, even if `ffmpeg`'s own shutdown wasn't graceful.

Pressing **Ctrl-C** sends `SIGINT` to the whole foreground process group;
the wrapper escalates as you press it again:

1. **First Ctrl-C** — forward `SIGINT` to `ffmpeg` (graceful clean-up).
2. **Second Ctrl-C** — forward `SIGTERM`.
3. **Third Ctrl-C** — `SIGKILL` `ffmpeg`, restore the terminal, and exit
   the wrapper immediately with `130`.

Hardware encoders (e.g. `hevc_videotoolbox`) sometimes take a moment to
honor `SIGINT`; the escalation lets you push harder without giving up
on a clean teardown the first time.

## Project layout

```text
src/
  cli.cr                         # binary entrypoint (shard.yml target)
  ffmpeg-progress.cr             # module + FfmpegProgress.main
  ffmpeg-progress/
    ansi.cr                      # escapes, blocks, terminal width
    style_options.cr             # wrapper option parsing
    probe.cr                     # ffprobe + image-pattern helpers
    analyzer.cr                  # mode detection + duration/frame totals
    progress_bar.cr              # bar rendering
    runner.cr                    # process spawn, stderr modes, draw loop
spec/                            # specs (analyzer, probe, options)
```

## Contributing

1. Fork it (<https://github.com/plambert/ffmpeg-progress.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

* [Paul M. Lambert](https://github.com/plambert) - creator and maintainer
