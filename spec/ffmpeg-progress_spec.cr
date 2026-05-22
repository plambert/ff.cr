require "./spec_helper"

describe FfmpegProgress::Analyzer do
  it "detects a basic single-output mux" do
    args = ["-i", "input.mp4", "-c", "copy", "output.mp4"]
    a = FfmpegProgress::Analyzer.new(args).analyze
    a.inputs.map(&.path).should eq(["input.mp4"])
    a.outputs.map(&.path).should eq(["output.mp4"])
  end

  it "detects an image-pattern output" do
    args = ["-i", "in.mp4", "-qscale:v", "1", "/tmp/out/frame_%06d.png"]
    a = FfmpegProgress::Analyzer.new(args).analyze
    a.outputs.last.is_image_sequence.should be_true
  end

  it "detects an image-pattern input" do
    args = ["-framerate", "30", "-i", "/tmp/in/frame_%06d.png", "-i", "audio.wav", "out.mp4"]
    a = FfmpegProgress::Analyzer.new(args).analyze
    a.inputs.first.is_image_sequence.should be_true
    a.inputs.first.framerate.should eq(30.0)
  end
end

describe FfmpegProgress::Probe do
  it "parses fractional framerates" do
    FfmpegProgress::Probe.parse_framerate("30000/1001").not_nil!.round(3).should eq(29.970)
    FfmpegProgress::Probe.parse_framerate("30").should eq(30.0)
    FfmpegProgress::Probe.parse_framerate("0/0").should be_nil
  end

  it "matches image patterns" do
    FfmpegProgress::Probe.image_pattern?("frame_%06d.png").should be_true
    FfmpegProgress::Probe.image_pattern?("thumb-%003d.png").should be_true
    FfmpegProgress::Probe.image_pattern?("output.mp4").should be_false
  end

  it "converts patterns to globs" do
    FfmpegProgress::Probe.image_pattern_to_glob("frame_%06d.png").should eq("frame_*.png")
  end
end

describe FfmpegProgress::StyleOptions do
  it "parses style options before --" do
    opts, args = FfmpegProgress::StyleOptions.parse(["--show-stderr", "--", "-i", "in.mp4", "out.mp4"])
    opts.stderr_mode.should eq(FfmpegProgress::StyleOptions::StderrMode::Console)
    args.should eq(["-i", "in.mp4", "out.mp4"])
  end

  it "treats absent -- as immediate ffmpeg args" do
    opts, args = FfmpegProgress::StyleOptions.parse(["-i", "in.mp4", "out.mp4"])
    opts.stderr_mode.should eq(FfmpegProgress::StyleOptions::StderrMode::Buffer)
    args.should eq(["-i", "in.mp4", "out.mp4"])
  end

  it "accepts --log-file with a value" do
    opts, args = FfmpegProgress::StyleOptions.parse(["--log-file", "/tmp/x.log", "--", "-i", "in.mp4", "out.mp4"])
    opts.stderr_mode.should eq(FfmpegProgress::StyleOptions::StderrMode::LogFile)
    opts.log_file.should eq("/tmp/x.log")
    args.should eq(["-i", "in.mp4", "out.mp4"])
  end
end
