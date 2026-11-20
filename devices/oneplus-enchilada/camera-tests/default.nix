# Camera regression test for the OnePlus 6 (not part of the system).
#
# swaptest drives two cameras the way PipeWire does when an application
# switches between them (configure A, configure B, start A; start B while
# A streams) and can restart one camera N times to count streams that
# stall ("cycle N").
#
# Build for the phone and copy it over:
#   nix-build -E 'with import <nixpkgs> { system = "aarch64-linux"; };
#     callPackage ./devices/oneplus-enchilada/camera-tests { }'
#   nix copy --to ssh://root@172.16.42.1 ./result
# Run it against the deployed (patched) libcamera, with Snapshot closed:
#   L=$(dirname $(ldd $(readlink -f /run/current-system/sw/lib/spa-0.2/libcamera/libspa-libcamera.so) | grep -o '/nix/store/[^ ]*libcamera.so[^ ]*'))
#   LD_LIBRARY_PATH=$L swaptest bus@0/camera@1a bus@1/camera@10
#   LD_LIBRARY_PATH=$L swaptest bus@0/camera@1a bus@1/camera@10 cycle 30
{ stdenv, pkg-config, libcamera }:

stdenv.mkDerivation {
  name = "enchilada-camera-swaptest";
  src = ./.;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libcamera ];
  buildPhase = ''
    $CXX -O2 -std=c++17 swaptest.cpp $(pkg-config --cflags --libs libcamera) -o swaptest
  '';
  installPhase = "install -Dm755 swaptest $out/bin/swaptest";
}
