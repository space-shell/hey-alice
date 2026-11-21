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
          python312
          uv          # venv + pip install (venvShellHook path was unreliable here)
          espeak-ng   # phonemiser used by Kokoro TTS
          git
          # native libs for pypi binary wheels (PyAV needs libz; torch needs libstdc++)
          zlib
          stdenv.cc.cc.lib
        ];
        shellHook = ''
          export LD_LIBRARY_PATH="${pkgs.zlib}/lib:${pkgs.stdenv.cc.cc.lib}/lib:$LD_LIBRARY_PATH"
          [ -d .venv ] || uv venv --python ${pkgs.python312}/bin/python3.12 .venv
          source .venv/bin/activate
          # reinstall when requirements.txt changes (marker file)
          if [ ! -f .venv/.deps ] || [ requirements.txt -nt .venv/.deps ]; then
            uv pip install -r requirements.txt && touch .venv/.deps
          fi
          echo "gateway devshell — venv at .venv (deps from requirements.txt)"
        '';
      };
    };
}
