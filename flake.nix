{
  description = "hey-alice — Alice, a voice companion for Paseo (Android app devshell)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          jdk17
          gradle
          android-tools   # adb / fastboot — NX1 bring-up (plan D1.x)
          scrcpy
          curl
          unzip           # SDK bootstrap (tools/setup-sdk.sh)
        ];

        shellHook = ''
          export JAVA_HOME=${pkgs.jdk17.home}
          # Gradle needs an Android SDK (platform 35). Point ANDROID_HOME at a
          # sdkmanager-installed SDK, or swap in androidenv.composeAndroidPackages
          # for a pure-nix SDK if you prefer.
          export ANDROID_HOME=''${ANDROID_HOME:-$HOME/Android/Sdk}
          echo "hey-alice devshell — JAVA_HOME=$JAVA_HOME ANDROID_HOME=$ANDROID_HOME"
        '';
      };
    };
}
