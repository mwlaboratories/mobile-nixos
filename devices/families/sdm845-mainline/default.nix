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
  # crashed on the 3rd; with Wi-Fi off, 10 of 10 survived.
  #
  # So take the Wi-Fi link down before the modem stops. ath10k stays bound:
  # it gives the MSA memory back to Linux only when it sees the modem's WLAN
  # service go away (ath10k_qmi_event_server_exit). An unbound ath10k never
  # sees that, and binding it again fails ("failed to assign msa map
  # permissions: -22"). NetworkManager is told to leave the link alone
  # (runtime only, nothing is saved) and to take it back once the modem runs
  # again. An rfkill block is avoided: systemd-rfkill would keep it.
  systemd.services.rmtfs.serviceConfig = let
    nm = config.networking.networkmanager;
    nmcli = "${nm.package}/bin/nmcli";
    ip = "${pkgs.iproute2}/bin/ip";
    flag = "/run/rmtfs-wifi-down";
    wifiLinks = ''
      for n in /sys/class/net/*; do
        drv=$(readlink -f "$n/device/driver")
        [ "''${drv##*/}" = ath10k_snoc ] || continue
        echo "''${n##*/}"
      done
    '';
    wifiDown = pkgs.writeShellScript "ath10k-link-down" ''
      links=$(${wifiLinks})
      for link in $links; do
        echo "rmtfs: taking $link down before the modem stops" > /dev/kmsg
        ${lib.optionalString nm.enable ''${nmcli} device set "$link" managed no || true''}
        ${ip} link set "$link" down
        echo "$link" >> ${flag}
      done
    '';
    wifiUp = pkgs.writeShellScript "ath10k-link-back" ''
      [ -e ${flag} ] || exit 0
      # rmtfs starts the modem in the background; WLAN comes up with it.
      for _ in $(seq 60); do
        for r in /sys/class/remoteproc/*; do
          [ "$(cat "$r/name")" = 4080000.remoteproc ] && [ "$(cat "$r/state")" = running ] && break 2
        done
        sleep 1
      done
      sleep 5
      while read -r link; do
        echo "rmtfs: giving $link back" > /dev/kmsg
        ${if nm.enable then ''${nmcli} device set "$link" managed yes'' else ''${ip} link set "$link" up''} || true
      done < ${flag}
      rm -f ${flag}
    '';
  in {
    # Runs before the stop signal; rmtfs then stops the modem.
    # "-": never keep the modem from stopping.
    ExecStop = [ "-${wifiDown}" ];
    ExecStartPost = [ "-${wifiUp}" ];
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT}=="1", SUBSYSTEMS=="input", ATTRS{name}=="pmi8998_haptics", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra"
  '';
}
