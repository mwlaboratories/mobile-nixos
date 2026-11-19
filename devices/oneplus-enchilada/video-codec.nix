{ ... }:

{
  # Venus (the SDM845 video codec block) exposes a stateful H.264/VP8/HEVC
  # encoder (venus_enc, qcom-venus-encoder) and decoder (venus_dec,
  # qcom-venus-decoder) through V4L2 mem2mem.
  #
  # On kernel 7.4-rc3 (sdm845-linus) with the enchilada venus.mbn, the encoder
  # is broken and takes the system down with it. Observed twice on 2026-11-19,
  # with `gst-launch-1.0 videotestsrc ! v4l2h264enc ! fakesink`:
  #  - 1080p NV12: no encoded frame in 60 s, then the firmware reported
  #    "session error: event id:1001 (deadb000)", repeated 1006 errors and an
  #    SFR restart;
  #  - 720p NV12, next run: STREAMOFF hung in D state in
  #    venus_helper_vb2_stop_streaming -> load_scale_v4, and storage I/O
  #    stalled system-wide (jbd2 and fsync in D state, `sync` hung, journald
  #    killed by its watchdog) for ~4.5 min, until venus logged "System error
  #    has occurred, recovery failed to init HFI" and then "(recovered)";
  #    I/O resumed at that same moment.
  # (Why it spreads to I/O is a hypothesis: load_scale_v4 sets clocks and
  # interconnect bandwidth under core->lock, so a stuck vote there may block
  # the shared interconnect/RPMh path that UFS also needs.)
  #
  # Any GStreamer pipeline picks v4l2h264enc on its own (rank PRIMARY+1), and
  # so does Snapshot once "hardware encoding" is switched on in its
  # preferences. Keep the encoder module from loading, so a stray encode can't
  # wedge the phone. The decoder is a separate module and stays available.
  # Remove this once an encode test passes on a newer kernel or firmware.
  boot.blacklistedKernelModules = [ "venus_enc" ];
}
