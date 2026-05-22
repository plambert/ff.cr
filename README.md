# ffmpeg-progress

A small Crystal wrapper around `ffmpeg` that draws a clean, single-line
progress bar — autosized to the terminal, with sub-cell resolution via
Unicode partial blocks — and that keeps `ffmpeg`'s own stderr out of the way
unless something goes wrong.

```text
 12.3%    10:31 -> ETA 15:11 ███████████████▎
```

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
| `--debug` | Print a one-line summary of the detected mode, total duration/frames, and the actual argv passed to `ffmpeg`. |
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

### Exit status

The wrapper exits with `ffmpeg`'s exit status. `2` is used for its own
argument-parsing errors (e.g. nothing after `--`).

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
