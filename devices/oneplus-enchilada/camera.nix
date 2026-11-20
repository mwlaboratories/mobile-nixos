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

  # Both rear sensors report location "back", so WirePlumber names both
  # nodes "Built-in Back Camera". GNOME Snapshot stores the chosen camera by
  # that name and can't tell them apart. Name them by sensor; the node name
  # comes from the libcamera ID, which is the DT path of the sensor:
  #   cci i2c-bus@0 camera@1a  IMX519, main          -> "Back Camera"
  #   cci i2c-bus@1 camera@10  IMX376K, second       -> "Back Camera 2"
  #   (cci i2c-bus@0 camera@10 is the IMX371 front camera, left as is.)
  # The second camera also gets a lower priority than the main one (750 by
  # default for "back"), so the main camera stays the preferred rear one.
  services.pipewire.wireplumber.extraConfig."51-enchilada-cameras" = {
    "monitor.libcamera.rules" = [
      {
        matches = [ { "node.name" = "~libcamera_input.*i2c-bus_0_camera_1a"; } ];
        actions.update-props = {
          "node.description" = "Back Camera";
        };
      }
      {
        matches = [ { "node.name" = "~libcamera_input.*i2c-bus_1_camera_10"; } ];
        actions.update-props = {
          "node.description" = "Back Camera 2";
          "priority.session" = 740;
        };
      }
    ];
  };
}
