{ config, lib, pkgs, ... }:

let
  # Opens the VoiceMMode1 PCMs during calls and, with the patch, starts
  # them: the start triggers the SLIMbus back ends, which is when the
  # WCD934x enables its SLIMbus channels (earpiece and mic).
  q6voiced = pkgs: pkgs.q6voiced.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./q6voiced-start-the-streams.patch ];
  });
in
{
  nixpkgs.overlays = [
    (self: super: {
      # Speakerphone in calls: PipeWire gives the OnePlus 6 separate
      # "Voice Call (Earpiece, Mic)" and "Voice Call (Speaker, Mic)"
      # profiles (one PCM, so never two ports of one sink); the speaker
      # button switches between them instead of between ports.
      callaudiod = super.callaudiod.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./callaudiod-speaker-switches-voice-profile.patch ];
      });
      # GNOME Calls links libcallaudio and is rebuilt with it. Its test
      # suite needs user namespaces (bwrap), which an emulated aarch64
      # build sandbox doesn't provide; the tests don't cover callaudiod.
      calls = super.calls.overrideAttrs { doCheck = false; };

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
          # OnePlus 6: speakerphone in the "Voice Call" verb.
          patches = [
            ./ucm-enchilada-voicecall-speaker.patch
            # ADCn Volume spans 0..+5 dB with the minimum as mute; PipeWire
            # maps any source volume up to 100 % onto it and mutes the mic.
            ./ucm-enchilada-software-capture-volume.patch
            # Calls: earpiece channel present when the voice streams start
            # under HiFi, and ADC gains set by the capture devices.
            ./ucm-enchilada-call-fixes.patch
            # Earpiece silent in calls (speaker fine): RX INT0 routed
            # before the voice stream starts on SLIMBUS_0_RX, and kept
            # routed until it stops, so codec RX port 0 never overflows.
            ./ucm-enchilada-earpiece-path-first.patch
          ];
        } ''
          mkdir -p $out/share/
          cp -rP --no-preserve=mode $src $out/share/alsa
          for p in $patches; do
            patch -d $out/share/alsa -p1 < $p
          done
        ''
      ) {};
    })
  ];

  # Alsa UCM profiles
  mobile.quirks.audio.alsa-ucm-meld = true;
  environment.systemPackages = [
    pkgs.sdm845-alsa-ucm
  ];

  # Stream settings postmarketOS sets for every Qualcomm device (soc-qcom
  # 51-qcom.conf; the reason isn't documented there). Part of the setup
  # with working audio on this phone. It matches all ALSA nodes as pmOS
  # does, so a USB sound card also gets the larger buffer.
  services.pipewire.wireplumber.extraConfig."51-qcom" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          { "node.name" = "~alsa_input.*"; }
          { "node.name" = "~alsa_output.*"; }
        ];
        actions.update-props = {
          "audio.format" = "S16LE";
          "audio.rate" = 48000;
          "api.alsa.period-size" = 4096;
          "api.alsa.period-num" = 6;
          "api.alsa.headroom" = 512;
        };
      }
    ];
  };

  # Call audio. The modem's voice stream runs inside the ADSP (q6voice):
  # the UCM "Voice Call" verb only sets the routes, and the DSP voice
  # session starts once something opens the VoiceMMode1 PCM for playback
  # and capture. q6voiced does that while ModemManager reports a call as
  # dialing, ringing out or active, and closes it when the call ends.
  # Without it a call connects with no audio either way.
  #
  # VoiceMMode1 is PCM 6 on card 0: sdm845-oneplus-common.dtsi (OnePlus 6
  # and 6T) lists MultiMedia1-6, then VoiceMMode1 (as on postmarketOS).
  systemd.packages = [ (q6voiced pkgs) ];
  systemd.services.q6voiced = {
    wantedBy = [ "multi-user.target" ];
    # q6voiced reports with printf(); to the journal (not a tty) stdout is
    # block-buffered, so "PCM devices were opened/closed" never showed up.
    serviceConfig.ExecStart = [
      ""
      "${pkgs.coreutils}/bin/stdbuf -oL ${q6voiced pkgs}/bin/q6voiced hw:\${q6voice_card},\${q6voice_device}"
    ];
  };
  environment.etc."q6voiced/q6voiced.conf".text = ''
    q6voice_card=0
    q6voice_device=6
  '';
}
