{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkIf
    mkMerge
    mkOption
    types
  ;
  cfg = config.mobile.usb.stage-2;
  inherit (config.mobile.device) identity;
  inherit (config.networking) hostName;

  # Stage-1 builds its gadget as g1 and leaves it behind (empty) on
  # switch_root; stage-2 tears it down and rebuilds it.
  gadget = "/sys/kernel/config/usb_gadget/g1";
  inherit (cfg) udc;

  teardown = ''
    if [ -d ${gadget} ]; then
      echo "" > ${gadget}/UDC 2>/dev/null || true
      find ${gadget}/configs -mindepth 2 -maxdepth 2 -type l -delete
      for d in ${gadget}/configs/*/strings/* ${gadget}/configs/* \
               ${gadget}/functions/* ${gadget}/strings/*; do
        [ -d "$d" ] && rmdir "$d"
      done
      rmdir ${gadget}
    fi
  '';
in
{
  options.mobile.usb.stage-2 = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Configure a USB gadget in stage-2 (the booted system) with:

         - an NCM network function (usb0). With NetworkManager enabled, the
           device takes `address` and hands the host an address by DHCP
           ("shared" connection), so `ssh root@172.16.42.1` works without WiFi.
           Without NetworkManager, usb0 is left for you to configure.
         - an ACM serial function with a getty on /dev/ttyGS0 (on a Linux
           host: /dev/ttyACM0).

        Stage-1 only builds a gadget for initrd networking and adbd, so without
        this the host sees nothing on USB once the system has booted.
        Conflicts with `mobile.adbd`, which re-uses the stage-1 gadget.
      '';
    };
    udc = mkOption {
      type = types.str;
      example = "a600000.usb";
      description = ''
        Name of the USB device controller to bind the gadget to (an entry of
        /sys/class/udc).
      '';
    };
    address = mkOption {
      type = types.str;
      default = "172.16.42.1/24";
      description = ''
        Address (with prefix length) of the device on the USB network, when
        NetworkManager manages it.
      '';
    };
  };

  config = mkMerge [
    {
      # Ensure configfs is mounted if needed.
      fileSystems."/sys/kernel/config" = mkIf (config.mobile.usb.mode == "gadgetfs") {
        device = "none";
        fsType = "configfs";
      };
    }

    (mkIf cfg.enable {
      assertions = [
        { assertion = config.mobile.usb.mode == "gadgetfs";
          message = "mobile.usb.stage-2 requires mobile.usb.mode = \"gadgetfs\"";
        }
        { assertion = !config.mobile.adbd.enable;
          message = "mobile.usb.stage-2 replaces the stage-1 gadget that mobile.adbd re-uses; enable only one of them.";
        }
      ];

      systemd.services.usb-gadget = {
        description = "USB gadget (NCM network + ACM serial)";
        wantedBy = [ "multi-user.target" ];
        after = [ "sys-kernel-config.mount" ];
        requires = [ "sys-kernel-config.mount" ];
        before = [ "NetworkManager.service" "serial-getty@ttyGS0.service" ];
        path = [ pkgs.coreutils pkgs.findutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          # Wait for the UDC (dwc3 can probe late).
          for i in $(seq 50); do [ -e /sys/class/udc/${udc} ] && break; sleep 0.2; done

          # Drop the empty gadget stage-1 left behind.
          ${teardown}

          mkdir ${gadget}
          cd ${gadget}
          echo 0x${config.mobile.usb.idVendor} > idVendor
          echo 0x${config.mobile.usb.idProduct} > idProduct
          mkdir strings/0x409
          echo ${lib.escapeShellArg identity.manufacturer} > strings/0x409/manufacturer
          echo "${hostName} (Mobile NixOS)" > strings/0x409/product
          cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0' > strings/0x409/serialnumber || echo ${lib.escapeShellArg hostName} > strings/0x409/serialnumber

          mkdir functions/ncm.usb0
          # Fixed MACs: stable interface name/lease on the PC across reboots.
          echo 02:00:00:1c:a7:01 > functions/ncm.usb0/dev_addr
          echo 02:00:00:1c:a7:02 > functions/ncm.usb0/host_addr
          mkdir functions/acm.GS0

          mkdir configs/c.1
          mkdir configs/c.1/strings/0x409
          echo "NCM + ACM" > configs/c.1/strings/0x409/configuration
          echo 500 > configs/c.1/MaxPower
          ln -s functions/ncm.usb0 configs/c.1/
          ln -s functions/acm.GS0 configs/c.1/

          echo ${udc} > UDC
        '';
        preStop = teardown;
      };

      # Serial console over the ACM function.
      systemd.services."serial-getty@ttyGS0" = {
        enable = true;
        wantedBy = [ "multi-user.target" ];
        after = [ "usb-gadget.service" ];
        requires = [ "usb-gadget.service" ];
      };

      # DHCP/DNS from NetworkManager's dnsmasq to the host, and ssh over the link.
      networking.firewall.trustedInterfaces = [ "usb0" ];
    })

    (mkIf (cfg.enable && config.networking.networkmanager.enable) {
      networking.networkmanager.ensureProfiles.profiles.usb-gadget = {
        connection = {
          id = "usb-gadget";
          type = "ethernet";
          interface-name = "usb0";
          autoconnect = "true";
        };
        ipv4 = {
          method = "shared";
          address1 = cfg.address;
        };
        ipv6.method = "ignore";
      };

      # The USB link is for reaching the device (ssh), not for routing the
      # host through it: "shared" would otherwise hand the host a default
      # route and DNS via the device, which can win over the host's own
      # network and dies with the device's uplink. An option without data
      # tells dnsmasq not to send it; requests are tagged with the interface
      # they came in on, so other shared connections (a hotspot) keep theirs.
      environment.etc."NetworkManager/dnsmasq-shared.d/usb-gadget.conf".text = ''
        dhcp-option=tag:usb0,option:router
        dhcp-option=tag:usb0,option:dns-server
      '';

      # NetworkManager's 85-nm-unmanaged.rules unmanages every DEVTYPE=gadget
      # interface, so the profile above would never activate. Re-manage usb0;
      # NetworkManager reads this when usb0 is added.
      services.udev.extraRules = ''
        SUBSYSTEM=="net", ACTION=="add|change", KERNEL=="usb0", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
      '';
    })
  ];
}
