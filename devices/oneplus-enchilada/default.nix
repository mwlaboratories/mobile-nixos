{ config, lib, pkgs, ... }:

{
  imports = [
    ../families/sdm845-mainline
    ./bluetooth.nix
    ./camera.nix
    ./sensors.nix
    ./video-codec.nix
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
  # address. These links are for stage-2.
  #
  # Stage-1 needs the zap shader at the DT path too: msm is built in and
  # initialises the GPU on the first open of the DRM device (the stage-1 boot
  # GUI). If the zap shader is missing then, hw init fails with -2 and the GPU
  # never recovers in stage-2 (software rendering). Copied, not linked, so the
  # initrd holds a real file.
  mobile.boot.stage-1.firmware = [
    (pkgs.runCommand "oneplus-enchilada-initrd-zap" {} ''
      mkdir -p $out/lib/firmware/qcom/sdm845/OnePlus/enchilada
      cp -v ${config.mobile.device.firmware}/lib/firmware/qcom/sdm845/oneplus6/a630_zap.mbn \
        $out/lib/firmware/qcom/sdm845/OnePlus/enchilada/
    '')
  ];

  hardware.firmware = [
    ((pkgs.runCommand "oneplus-enchilada-firmware-paths" {} ''
      fw=${config.mobile.device.firmware}/lib/firmware
      mkdir -p $out/lib/firmware/qcom/sdm845/OnePlus $out/lib/firmware/qca/OnePlus
      ln -s $fw/qcom/sdm845/oneplus6 $out/lib/firmware/qcom/sdm845/OnePlus/enchilada
      ln -s $fw/qca/oneplus6 $out/lib/firmware/qca/OnePlus/enchilada
    '') // { compressFirmware = false; })
  ];

  # A panic hangs (CONFIG_PANIC_TIMEOUT=0) until a long key press; restart by
  # itself instead.
  #
  # TEMPORARY, to catch an early-boot panic (boots that die ~70 s in and
  # restart through panic=10; ramoops is lost on that reset): with download
  # mode on, the panic restart lands in Qualcomm crashdump with DDR kept, so
  # qdl-ramdump (DDRCS0_0) holds the panic record. pstore uncompressed, so
  # the record reads as plain text in the dump; 64 KiB of log per record.
  # Clean reboots clear download mode at shutdown and are unaffected; any
  # crash now waits in crashdump instead of recovering by itself. Drop the
  # last three once the panic is found.
  boot.kernelParams = [
    "panic=10"
    "qcom_scm.download_mode=full"
    "pstore.compress=none"
    "pstore.kmsg_bytes=65536"
  ];

  # No factory WiFi MAC reaches mainline (postmarketOS uses bootmac), so the
  # address is random per boot and DHCP hands out a new lease after each
  # reboot. "stable" derives one from the machine-id and the connection.
  networking.networkmanager.wifi.macAddress = lib.mkDefault "stable";

  # Start ModemManager at boot, not only on D-Bus activation (e.g. by a GNOME
  # greeter): with no graphical session the modem otherwise stays off.
  systemd.services.ModemManager.wantedBy = lib.mkIf config.networking.modemmanager.enable
    (lib.mkDefault [ "multi-user.target" ]);

  mobile.system.android.device_name = "OnePlus6";
}
