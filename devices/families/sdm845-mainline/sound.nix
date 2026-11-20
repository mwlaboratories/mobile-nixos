{ config, lib, pkgs, ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      sdm845-alsa-ucm = self.callPackage (
        { runCommand, fetchFromGitLab }:

        runCommand "sdm845-alsa-ucm" {
          src = fetchFromGitLab {
            name = "sdm845-alsa-ucm";
            owner = "sdm845-mainline";
            repo = "alsa-ucm-conf";
            # The commit postmarketOS ships (alsa-ucm-conf-sdm845, 2026-05-09).
            # Over the 2022 pin: OnePlus 6/6T get a "Voice Call" verb
            # (earpiece + bottom mic, q6voice routes to SLIMBUS_0), the
            # earpiece in HiFi, and another mic route: bottom mic ADC4
            # through AMIC4_5 SEL on MultiMedia2 (hw:0,1). The 2022 config
            # captured ADC3 on MultiMedia3 and recorded silence on 7.4.
            rev = "1b8d290e5aa2ca16b7f2fa8d74910ad19ef88b3a";
            hash = "sha256-Kg4vxDrli/ffNeUwDBL5GfdJsbwFRPAUieQEsjVKADw=";
          };
        } ''
          mkdir -p $out/share/
          ln -s $src $out/share/alsa
        ''
      ) {};
    })
  ];

  # Alsa UCM profiles
  mobile.quirks.audio.alsa-ucm-meld = true;
  environment.systemPackages = [
    pkgs.sdm845-alsa-ucm
  ];

  # Call audio. The modem's voice stream runs inside the ADSP (q6voice):
  # the UCM "Voice Call" verb only sets the routes, and the DSP voice
  # session starts once something opens the VoiceMMode1 PCM for playback
  # and capture. q6voiced does that while ModemManager reports a call as
  # dialing, ringing out or active, and closes it when the call ends.
  # Without it a call connects with no audio either way.
  #
  # VoiceMMode1 is PCM 6 on card 0: sdm845-oneplus-common.dtsi (OnePlus 6
  # and 6T) lists MultiMedia1-6, then VoiceMMode1 (as on postmarketOS).
  systemd.packages = [ pkgs.q6voiced ];
  systemd.services.q6voiced.wantedBy = [ "multi-user.target" ];
  environment.etc."q6voiced/q6voiced.conf".text = ''
    q6voice_card=0
    q6voice_device=6
  '';
}
