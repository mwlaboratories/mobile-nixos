{ ... }:

{
  # libcamera's software ISP (the only ISP for these raw SRGGB10 sensors)
  # allocates its output buffers from a dma-buf heap. libcamera 0.7.2 tries
  # /dev/dma_heap/{linux,cma,reserved,system} and /dev/udmabuf; on this kernel
  # only {default_cma_region,fastrpc,reserved} exist, root-only. Without
  # access the soft ISP is disabled, PipeWire's libcamera nodes offer no
  # formats and GNOME Snapshot reports "No camera found".
  # default_cma_region (the CMA heap's newer name) is left out because
  # libcamera 0.7.2 does not look for it; fastrpc stays root/DSP-only.
  # uaccess covers the seat user; the video group covers non-seat users.
  services.udev.extraRules = ''
    SUBSYSTEM=="dma_heap", KERNEL=="reserved|system|linux,cma", GROUP="video", MODE="0660", TAG+="uaccess"
  '';
}
