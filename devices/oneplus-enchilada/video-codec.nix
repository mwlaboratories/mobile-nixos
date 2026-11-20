{ ... }:

{
  # Venus (the SDM845 video codec block) exposes a stateful H.264/VP8/HEVC
  # encoder (venus_enc, qcom-venus-encoder) and decoder (venus_dec,
  # qcom-venus-decoder) through V4L2 mem2mem.
  #
  # Encoder status on kernel 7.4-rc3 with the enchilada venus.mbn, after the
  # EOS fix (kernel patch 0007), measured 2026-11-20 with
  # `videotestsrc num-buffers=90 ! NV12 ! v4l2h264enc`:
  #  - 640x480, 960x544 and 1280x720 encode fine (720p: 68.6 fps on "snow",
  #    48.2 fps from RGBA through videoconvert, 28.4 fps from the camera);
  #  - 1440x1080 and 1920x1080 stall silently after STREAMON: no frame, no
  #    error. (Earlier, before 0007, such stalls ended in a firmware fault and
  #    once in a ~4.5 min system-wide storage stall.)
  # Every working size needs only the lowest Venus clock (100 MHz) and every
  # stalling one needs 200 MHz, so the clock switch is the prime suspect. Not
  # yet proven.
  #
  # GStreamer ranks v4l2h264enc PRIMARY+1, and Snapshot uses it with
  # "hardware encoding" on. So the encoder may load, but it only offers frames
  # up to 1280x720 (kernel patch 0009). A larger stream is then scaled down by
  # encodebin rather than handed to a size that hangs.
  # Raise or drop this once 1080p encodes work.
  boot.extraModprobeConfig = ''
    options venus_enc max_width=1280 max_height=720
  '';
}
