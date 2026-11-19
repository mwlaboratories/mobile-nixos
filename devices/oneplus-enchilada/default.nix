{ config, lib, pkgs, ... }:

{
  imports = [
    ../families/sdm845-mainline
    ./bluetooth.nix
    ./sensors.nix
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

  # NCM network (172.16.42.1) + ACM serial console once booted.
  mobile.usb.stage-2.enable = lib.mkDefault true;

  # No factory WiFi MAC reaches mainline (postmarketOS uses bootmac), so the
  # address is random per boot and DHCP hands out a new lease after each
  # reboot. "stable" derives one from the machine-id and the connection.
  networking.networkmanager.wifi.macAddress = lib.mkDefault "stable";

  # Start ModemManager at boot, not only on D-Bus activation (e.g. by a GNOME
  # greeter): with no graphical session the modem otherwise stays off.
  systemd.services.ModemManager.wantedBy = lib.mkIf config.networking.modemmanager.enable
    (lib.mkDefault [ "multi-user.target" ]);

  # The modem's QMI port does not survive resume, which loses mobile data
  # and notifications. Screen blanking still saves power.
  systemd.sleep.settings.Sleep.AllowSuspend = lib.mkDefault false;

  mobile.system.android.device_name = "OnePlus6";
}
