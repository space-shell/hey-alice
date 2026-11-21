#!/usr/bin/env bash
# setup-sdk.sh — one-time Android SDK bootstrap for building the hey-alice app.
# Run inside the ROOT flake's app devshell (has jdk17+gradle):
#   cd ~/projects/hey-alice && nix develop -c bash tools/setup-sdk.sh
# (Do NOT run from tools/ — that flake is the bring-up shell: adb/fastboot/mtkclient.)
set -euo pipefail

SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
# Google cmdline-tools build number; override CMDLINE_URL if this 404s.
CMDLINE_URL="${CMDLINE_URL:-https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip}"

command -v java >/dev/null || { echo "FATAL: no java — run inside tools devshell"; exit 2; }
command -v curl >/dev/null || { echo "FATAL: no curl — run inside tools devshell"; exit 2; }
command -v unzip >/dev/null || { echo "FATAL: no unzip — run inside tools devshell"; exit 2; }

export ANDROID_HOME="$SDK"
mkdir -p "$SDK/cmdline-tools"

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "[setup-sdk] downloading cmdline-tools..."
  cd "$SDK/cmdline-tools"
  curl -fL --retry 3 -o tools.zip "$CMDLINE_URL"
  unzip -q tools.zip
  mv cmdline-tools latest
  rm -f tools.zip
else
  echo "[setup-sdk] cmdline-tools already present"
fi

echo "[setup-sdk] accepting licenses..."
yes | "$SDK/cmdline-tools/latest/bin/sdkmanager --licenses" >/dev/null 2>&1 || true

echo "[setup-sdk] installing platform-tools, platforms;android-35, build-tools;35.0.0 (this downloads ~500 MB)..."
"$SDK/cmdline-tools/latest/bin/sdkmanager" --install \
  "platform-tools" "platforms;android-35" "build-tools;35.0.0" 2>&1 | grep -vE '^\[' | tail -3

echo "[setup-sdk] SDK READY at $SDK"
