#!/usr/bin/env bash
# overlay-install.sh — install the ADR-6 power-menu RRO (config_longPressOnPowerBehavior=0).
#
# Verified on-device 2026-11-27:
#   - Direct /product/overlay write FAILS: /product is an EROFS dynamic
#     partition (dm-*), read-only even for `mount -o rw,remount` under root.
#   - Unsigned APKs fail PackageManager scan even preinstalled — the overlay
#     MUST be signed (any cert works for preinstall trust; debug keystore OK).
#   - Working path: Magisk module zip + `magisk --install-module` (magiskd
#     writes /data/adb/modules itself; the su shell's magisk:s0 context is
#     denied raw writes to /data/adb on this device — plain su AND su -mm).
#   - Module activates on reboot. NX1 quirk: `adb reboot` powers OFF — owner
#     must press POWER ~10 s (and possibly reseat USB).
#
# After reboot the script (or a human) runs:
#   adb shell cmd overlay enable --user 0 com.heyalice.overlay
#   adb shell cmd overlay list --user 0 | grep heyalice      # expect [x]
#   adb shell input keyevent --longpress KEYCODE_POWER       # synthetic check:
#   #   uiautomator dump must NOT contain "Power off"/"Restart"/"Lockdown"
#
# Usage: nix develop -c bash tools/overlay-install.sh   (repo root)
# Requires: ANDROID_HOME build-tools (apksigner via java -jar; the wrapper's
# #!/bin/bash shebang does not exist on NixOS), ~/.android/debug.keystore.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${1:-$REPO_ROOT/overlay/build/outputs/apk/release/overlay-release-unsigned.apk}"
BT="${ANDROID_HOME:?set ANDROID_HOME}/build-tools/34.0.0"
KS="$HOME/.android/debug.keystore"
ZIP="$REPO_ROOT/overlay/build/outputs/apk/release/alice_power_overlay.zip"

# Target discipline: never issue adb commands without -s <NX1 serial>.
NX1_SERIAL="${NX1_SERIAL:-TLF2601S000307}"
adb() { command adb -s "$NX1_SERIAL" "$@"; }

log() { echo "[overlay] $*"; }
[ -f "$SRC" ] || { echo "overlay APK not found: $SRC (build :overlay:assembleRelease)" >&2; exit 1; }

log "signing overlay (debug keystore — preinstall trust is by location, not cert)"
SIGNED="$REPO_ROOT/overlay/build/outputs/apk/release/overlay-release-signed.apk"
java -jar "$BT/lib/apksigner.jar" sign --ks "$KS" --ks-pass pass:android \
  --ks-key-alias androiddebugkey --out "$SIGNED" "$SRC"

log "packing Magisk module zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/system/product/overlay"
cp "$SIGNED" "$STAGE/system/product/overlay/AlicePowerOverlay.apk"
printf 'id=alice_power_overlay\nname=Alice Power Overlay\nversion=1.1\nversionCode=2\nauthor=hey-alice\ndescription=ADR-6 power-menu RRO (config_longPressOnPowerBehavior=0)\n' \
  > "$STAGE/module.prop"
( cd "$STAGE" && python3 -c "
import zipfile, os
with zipfile.ZipFile('$ZIP', 'w') as z:
    for root, dirs, files in os.walk('.'):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, '.'))
" )

log "pushing + installing via magiskd"
adb push "$ZIP" /data/local/tmp/alice_power_overlay.zip
adb shell su -c '/data/adb/magisk/magisk --install-module /data/local/tmp/alice_power_overlay.zip'

log "installed. reboot now — OWNER must press POWER ~10 s when it goes dark"
read -r -p "Reboot now? [y/N] " ans
[ "$ans" = "y" ] && adb reboot
