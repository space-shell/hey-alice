{
  description = "Bluefox NX1 device bring-up devshell — adb/fastboot, mtkclient, scrcpy";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          android-tools   # adb + fastboot
          mtkclient       # BROM-mode partition backup / restore (MediaTek MT6769)
          scrcpy          # screen mirror + control over adb
          curl            # fetch Magisk release APK (magiskboot/magiskinit live in it)
          unzip           # extract magiskboot + magisk init binaries from the APK
          jq              # parse GitHub release JSON to resolve download URLs
        ];

        shellHook = ''
          echo "NX1 bring-up shell: adb, fastboot, mtkclient, scrcpy"
          echo "magiskboot: run tools/patch-init-boot.sh (fetches pinned Magisk APK)"
        '';
      };
    };
}
