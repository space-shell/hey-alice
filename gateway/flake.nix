{
  description = "hey-alice voice gateway — streaming STT/TTS behind one WebSocket";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          (python312.withPackages (ps: with ps; [ venvShellHook pip ]))
          espeak-ng    # phonemiser used by Kokoro TTS
          git
        ];
        venvDir = ".venv";
        postVenvCreation = ''
          pip install -r requirements.txt
        '';
        postShellHook = ''
          echo "gateway devshell — venv at $venvDir (deps from requirements.txt)"
        '';
      };
    };
}
