{ config, lib, pkgs, options, ... }:

let
  cfg = config.mobile.quirks.qualcomm;
  inherit (lib)
    any
    id
    mkIf
    mkOption
    optional
    types
  ;
  anyCompatible = any id [
    cfg.sdm845-modem.enable
    cfg.sc7180-modem.enable
  ];

  # Systems for which we read the partition directly.
  # TODO: This is likely the wrong abstraction.
  # Once we have more accrued knowledge, add a discrete option.
  rmtfsReadsPartition = any id [
    cfg.sdm845-modem.enable
  ];

  # TODO: figure out what PD mapper exactly is...
  # is it USB PD or something modem related?
  withPDMapper = any id [
    cfg.sdm845-modem.enable
  ];
in
{
  options.mobile = {
    quirks.qualcomm.sc7180-modem.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable this on a mainline-based SC7180 device for modem/Wi-Fi support
      '';
    };
    quirks.qualcomm.sdm845-modem.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable this on a mainline-based SDM845 device for modem support
      '';
    };
  };
  config = mkIf (anyCompatible) {
    # Makes platform-specific firmware files available in an uncompressed form at:
    # /run/current-system/sw/share/uncompressed-firmware/qcom/sdm845/
    # This is used by userspace components unaware of the possible xz compression.
    # See also: tqftpserv and pd-mapper patches.
    environment.pathsToLink = [ "/share/uncompressed-firmware" ];
    # This package added to the environment will select a few firmware path to keep uncompressed.
    environment.systemPackages = [
      (pkgs.callPackage (
        { lib
        , runCommand
        , buildEnv
        , firmwareFilesList
        }:

        runCommand "qcom-modem-uncompressed-firmware-share" {
          firmwareFiles = buildEnv {
            name = "qcom-modem-uncompressed-firmware";
            paths = firmwareFilesList;
            pathsToLink = [
              "/lib/firmware/rmtfs"
            ]
              ++ optional cfg.sdm845-modem.enable "/lib/firmware/qcom/sdm845"
              ++ optional cfg.sc7180-modem.enable "/lib/firmware/qcom/sc7180-trogdor"
            ;
          };
        } ''
          PS4=" $ "
          (
          set -x
          mkdir -p $out/share/
          ln -s $firmwareFiles/lib/firmware/ $out/share/uncompressed-firmware
          )
        ''
      ) {
        # We have to borrow the pre `apply`'d list, thus `options...definitions`.
        # This is because the firmware is compressed in `apply` on `hardware.firmware`.
        firmwareFilesList = lib.flatten options.hardware.firmware.definitions;
      })
    ];

    # VoLTE. The modem runs its own IMS stack but asks the AP, through the
    # QMI "IMS Data" service (770), to bring up the IMS APN connection.
    # 81voltd serves that and opens the bearer through ModemManager (as on
    # postmarketOS, soc-qcom-modem). Without it calls can only use 2G/3G
    # fallback. Whether the modem then registers IMS depends on the
    # operator profile in the modem firmware.
    #
    # Built against nixpkgs' qrtr: the Mobile NixOS overlay replaces qrtr
    # with a 2020 Makefile build without qrtr.pc, which 81voltd's meson
    # build needs. The rest of the modem stack stays on the overlay's.
    systemd.packages = mkIf config.networking.modemmanager.enable [
      (pkgs._81voltd.override {
        qrtr = pkgs.callPackage "${pkgs.path}/pkgs/by-name/qr/qrtr/package.nix" { };
      })
    ];

    # ModemManager 1.24.2 segfaults in netlink_messages_cb when a bearer
    # is replaced and its qmapmux link re-created: transaction_complete()
    # frees the transaction, then calls its completion_fn. Upstream fix
    # 9317cbc4 (on main, not in a release yet).
    networking.modemmanager.package = lib.mkDefault (pkgs.modemmanager.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./modemmanager-netlink-fix-use-after-free.patch ];
    }));

    systemd.services = {
      "81voltd" = mkIf config.networking.modemmanager.enable {
        wantedBy = [ "multi-user.target" ];
        # The packaged unit orders after "ModemManager.target", which
        # doesn't exist.
        after = [ "ModemManager.service" "qrtr-ns.service" ];
        wants = [ "ModemManager.service" ];
        requires = [ "qrtr-ns.service" ];
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
      rmtfs = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "qrtr-ns.service" ];
        after = [ "qrtr-ns.service" ];
        serviceConfig = {
          # https://github.com/andersson/rmtfs/blob/7a5ae7e0a57be3e09e0256b51b9075ee6b860322/rmtfs.c#L507-L541
          ExecStart = "${pkgs.rmtfs}/bin/rmtfs -s -r ${if rmtfsReadsPartition then "-P" else "-o /run/current-system/sw/share/uncompressed-firmware/rmtfs"}";
          Restart = "always";
          RestartSec = "1";
        };
      };
      qrtr-ns = {
        serviceConfig = {
          ExecStart = "${pkgs.qrtr}/bin/qrtr-ns -f 1";
          Restart = "always";
        };
      };
      tqftpserv = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "qrtr-ns.service" ];
        after = [ "qrtr-ns.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.tqftpserv}/bin/tqftpserv";
          Restart = "always";
        };
      };
      pd-mapper = mkIf withPDMapper {
        wantedBy = [ "multi-user.target" ];
        requires = [ "qrtr-ns.service" ];
        after = [ "qrtr-ns.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.pd-mapper}/bin/pd-mapper";
          Restart = "always";
        };
      };
      # Activates the SIM's USIM application on the modem so ModemManager
      # sees the SIM. The msm-modem script (as on postmarketOS) waits up to
      # 45 s for the modem to answer on QRTR and 4 s for the card to show
      # up; the inline script this replaces asked once, right after boot,
      # and took a modem still starting for "no SIM". No SIM, or no USIM
      # application, exits 0. Type=notify as upstream: the script ends
      # with `systemd-notify --ready` in an EXIT trap under `set -e`; with
      # no NOTIFY_SOCKET (oneshot) that fails and turns exit 0 into 1.
      msm-modem-uim-selection = {
        enable = true;
        after = [ "rmtfs.service" ];
        requires = [ "rmtfs.service" ];
        before = [ "ModemManager.service" ];
        wantedBy = [ "ModemManager.service" "multi-user.target" ];
        serviceConfig = {
          Type = "notify";
          # systemd-notify runs as a child of the script.
          NotifyAccess = "all";
          RemainAfterExit = true;
          ExecStart = "${pkgs.msm-modem}/libexec/msm-modem-uim-selection";
        };
      };
    };
  };
}
