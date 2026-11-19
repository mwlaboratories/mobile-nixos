{ lib, pkgs, ... }:

# Sensors (accelerometer, gyroscope, compass, light, proximity) on the SLPI DSP.
#
# The sensors sit behind the Snapdragon Sensor Core on the SLPI. The DSP
# fetches its sensor registry and shared objects from the application
# processor over FastRPC; hexagonrpcd serves them (postmarketOS:
# hexagonrpcd-sdsp). Clients then talk to SSC over QRTR via libssc
# (iio-sensor-proxy built with ssc-support).
#
# The DSP userspace files (dsp/, sensors/ registry, acdb/) are not in the
# pinned firmware package (3ec855b2, lib/firmware only). Take just
# usr/share/qcom from the newer firmware-oneplus-sdm845 commit postmarketOS
# uses (3e31a0c3), leaving lib/firmware (and stage-1) untouched.

let
  dspShare = pkgs.runCommand "oneplus6-dsp-share" {
    src = pkgs.fetchzip {
      url = "https://gitlab.com/sdm845-mainline/firmware-oneplus-sdm845/-/archive/3e31a0c3e5a061645c09f805387b49fa9d35acbf/firmware-oneplus-sdm845-3e31a0c3e5a061645c09f805387b49fa9d35acbf.tar.gz";
      hash = "sha256-DeOlhchDGi0Pso3w8ZlM7q3Tdkmt3Ji+GyEmepkISTE=";
    };
    meta.license = pkgs.lib.licenses.unfree;
  } ''
    mkdir -p $out/share
    cp -r $src/usr/share/qcom $out/share/
  '';
  # hexagonrpcd convention: -R /usr/share/qcom/SOC/VENDOR/DEVICE
  root = "${dspShare}/share/qcom/sdm845/OnePlus/oneplus6";
in
{
  # iio-sensor-proxy's own udev rules tag /dev/fastrpc-sdsp with ssc-light
  # and ssc-compass.
  hardware.sensor.iio.enable = lib.mkDefault true;

  users.groups.fastrpc = { };
  users.users.fastrpc = {
    isSystemUser = true;
    group = "fastrpc";
  };

  services.udev.extraRules = ''
    KERNEL=="fastrpc-*", GROUP="fastrpc", MODE="0660"
    # Upstream only tags ssc-light/ssc-compass; the SSC on this phone also
    # serves the accelerometer (screen rotation) and proximity sensor.
    SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-proximity"
  '';

  systemd.services.hexagonrpcd-sdsp = {
    description = "FastRPC server for the SDSP (sensor registry and DSP libraries)";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/dev/fastrpc-sdsp";
    serviceConfig = {
      ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R ${root}";
      Restart = "always";
      RestartSec = 3;
      User = "fastrpc";
      Group = "fastrpc";
    };
  };
}
