{ config, lib, pkgs, ... }:

{
  imports = [
    ../families/sdm845-mainline
    ./bluetooth.nix
  ];

  mobile.device.name = "oneplus-enchilada";
  mobile.device.identity = {
    name = "OnePlus 6";
    manufacturer = "OnePlus";
  };
  mobile.device.supportLevel = "supported";

  mobile.hardware = {
    ram = 1024 * 8;
    screen = {
      width = 1080; height = 2280;
    };
  };

  mobile.device.firmware = pkgs.callPackage ./firmware {};

  # The mainline device tree asks for firmware under the board name
  # (qcom/sdm845/OnePlus/enchilada/ for the GPU zap shader and remoteprocs,
  # qca/OnePlus/enchilada/crnv21.bin for the Bluetooth NVM), but the firmware
  # package ships it under oneplus6/. Without the Bluetooth NVM, btqca fails
  # with "Failed to download NVM (-2)" and a placeholder 00:00:00:00:5A:AD
  # address. These links are for stage-2; the stage-1 copy is left unchanged.
  hardware.firmware = [
    ((pkgs.runCommand "oneplus-enchilada-firmware-paths" {} ''
      fw=${config.mobile.device.firmware}/lib/firmware
      mkdir -p $out/lib/firmware/qcom/sdm845/OnePlus $out/lib/firmware/qca/OnePlus
      ln -s $fw/qcom/sdm845/oneplus6 $out/lib/firmware/qcom/sdm845/OnePlus/enchilada
      ln -s $fw/qca/oneplus6 $out/lib/firmware/qca/OnePlus/enchilada
    '') // { compressFirmware = false; })
  ];

  mobile.system.android.device_name = "OnePlus6";
}
