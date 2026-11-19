{ config, lib, pkgs, ... }:

{
  imports = [
    ./sound.nix
  ];

  mobile.hardware = {
    soc = "qualcomm-sdm845";
  };

  mobile.boot.stage-1 = {
    compression = "xz";
    kernel.package = (config.mobile.boot.stage-1.kernel.pkgs.callPackage ./kernel { });
  };

  hardware.enableRedistributableFirmware = true;

  # Note: on devices it's highly likely no firmware is required during stage-1.
  # DRM *should* work fine without firmware.
  # Modems and such will pick them back up in stage-2.
  # Even though, we're eagerly adding firmware files that fit.
  # This is a workaround for non-modular kernels wanting to load the adsp firmware during stage-1.
  mobile.boot.stage-1.firmware = [
    (pkgs.runCommand "initrd-firmware" {} ''
      cp -vrf ${config.mobile.device.firmware} $out
      chmod -R +w $out
      # Big file, fills and breaks stage-1
      find $out/lib/firmware/qcom/sdm845 -name "modem.mbn" -delete -print

      # Copy extra a630 firmware from linux-firmware
      cp -vf ${pkgs.linux-firmware}/lib/firmware/qcom/{a630_sqe.fw,a630_gmu.bin} $out/lib/firmware/qcom
    '')
  ];


  mobile.system.type = "android";
  mobile.system.android.useSparseImage = true;
  mobile.system.android = {
    # Assumed all SDM845 devices use A/B
    ab_partitions = lib.mkDefault true;
    # Assumed all SDM845 devices can boot with the same options.
    bootimg.flash = {
      offset_base = "0x00000000";
      offset_kernel = "0x00008000";
      offset_ramdisk = "0x01000000";
      offset_second = "0x00000000";
      offset_tags = "0x00000100";
      pagesize = "4096";
    };
    appendDTB = lib.mkDefault [
      "dtbs/qcom/sdm845-${config.mobile.device.name}.dtb"
    ];
  };

  mobile.usb.mode = "gadgetfs";
  # The identifiers used here serve as a compatible well-known identifier.
  mobile.usb.idVendor = lib.mkDefault "18D1"; # Google
  mobile.usb.idProduct = lib.mkDefault "D001"; # "Nexus 4"

  mobile.usb.gadgetfs.functions = {
    adb = "ffs.adb";
    mass_storage = "mass_storage.0";
    rndis = "rndis.usb0";
  };
  mobile.usb.stage-2.udc = lib.mkDefault "a600000.usb";

  mobile.quirks.qualcomm.sdm845-modem.enable = true;

  # The WLAN firmware (WCN3990) runs on the modem. rmtfs (-s) stops the modem
  # when it stops, at every shutdown and reboot. If ath10k is still sending
  # then ("failed to transmit packet: -108"), the SoC dies within seconds and
  # ends in Qualcomm crashdump. On a OnePlus 6: modem stops with Wi-Fi up
  # crashed on the 3rd; with Wi-Fi off, 10 of 10 survived. Unbind ath10k
  # before the modem stops (a link down could be undone by NetworkManager,
  # an rfkill block would be saved by systemd-rfkill), and bind it again
  # when rmtfs starts the modem again.
  systemd.services.rmtfs.serviceConfig = let
    snoc = "/sys/bus/platform/drivers/ath10k_snoc";
    wifiDown = pkgs.writeShellScript "ath10k-snoc-unbind" ''
      for dev in ${snoc}/*.*; do
        [ -e "$dev" ] || continue
        name=''${dev##*/}
        echo "rmtfs: unbinding ath10k $name before the modem stops" > /dev/kmsg
        echo "$name" > ${snoc}/unbind
      done
    '';
    wifiUp = pkgs.writeShellScript "ath10k-snoc-bind" ''
      [ -d ${snoc} ] || exit 0
      for dev in /sys/bus/platform/devices/*; do
        grep -qs wcn3990-wifi "$dev/of_node/compatible" || continue
        [ -e "$dev/driver" ] && continue
        echo "''${dev##*/}" > ${snoc}/bind
      done
    '';
  in {
    # "-": never keep the modem from starting or stopping.
    ExecStartPre = [ "-${wifiUp}" ];
    # Runs before the stop signal; rmtfs then stops the modem.
    ExecStop = [ "-${wifiDown}" ];
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT}=="1", SUBSYSTEMS=="input", ATTRS{name}=="pmi8998_haptics", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra"
  '';
}
