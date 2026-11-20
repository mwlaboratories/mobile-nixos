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
}
