{ lib, pkgs, ... }:

let
  # Contrast-detection autofocus for the software ISP: Jayden Milne's
  # softisp-af branch (github.com/jaydens-tasty-slop/libcamera, 2026-11-01),
  # backported to libcamera 0.7.2 (src/ipa/softisp -> src/ipa/simple), plus
  # a tuning file that starts the IMX519 in continuous AF. Upstream has no
  # soft-ISP AF yet (only RFCs). The patches are made against 0.7.2 exactly.
  libcameraAf = pkgs.libcamera.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./libcamera/0001-libcamera-software_isp-Gather-focus-statistics.patch
      ./libcamera/0002-libcamera-software_isp-Pass-focus-lens-controls-to-a.patch
      ./libcamera/0003-ipa-libipa-Add-contrast-detection-autofocus-algorith.patch
      ./libcamera/0004-ipa-simple-Add-autofocus-algorithm.patch
      ./libcamera/0005-ipa-simple-Start-the-IMX519-in-continuous-autofocus.patch
      # PipeWire sets AfMode at camera start; the simple pipeline dropped it.
      ./libcamera/0006-pipeline-simple-Pass-the-start-controls-to-the-softw.patch
      # Gain models and black levels: without them AGC never raised the gain.
      ./libcamera/0007-ipa-libipa-camera_sensor_helper-Add-IMX371-IMX376-an.patch
      ./libcamera/0008-ipa-Log-autofocus-activity-at-info-level.patch
      # Upstream 7ebae537 (2026-10-29): clipped highlights skewed AWB (cast).
      ./libcamera/0009-libcamera-software_isp-Exclude-saturated-pixels-from.patch
    ];
  });
in
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

  # Autofocus (see libcameraAf above). The patches only change libcamera's
  # internals (soft ISP, its IPA and libipa), not its public ABI, so the
  # patched build replaces libcamera in the system closure without
  # rebuilding PipeWire and everything above it.
  # The lens drivers (lc89821x, lens-focus in the DT) are already in place.
  assertions = [
    {
      assertion = pkgs.libcamera.version == "0.7.2";
      message = "devices/oneplus-enchilada/libcamera: the AF patches are made for libcamera 0.7.2, nixpkgs has ${pkgs.libcamera.version}; rebase them.";
    }
  ];
  system.replaceDependencies.replacements = [
    {
      oldDependency = pkgs.libcamera;
      newDependency = libcameraAf;
    }
  ];

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
