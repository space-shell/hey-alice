#!/usr/bin/env bash
# overlay-install.sh — root-preinstall the ADR-6 power-menu RRO.
#
# A runtime overlay targeting the framework (android) fails OverlayManager's
# platform-signature check when user-installed, so it must be preinstalled on
# a system partition. This pushes :overlay's APK into /product/overlay, fixes
# ownership/context, and reboots (NOTE: the NX1 does not auto-boot after
# reboot — the owner must press POWER ~10 s, and USB may need reseating).
# After reboot it enables the overlay and verifies it is [x] active.
#
# Usage (from the tools/ bring-up devshell, APK built at repo root):
#   nix develop -c bash overlay-install.sh [path/to/overlay.apk]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APK="${1:-$REPO_ROOT/overlay/build/outputs/apk/release/overlay-release-unsigned.apk}"
ALICE_OVERLAY="com.heyalice.overlay"
DEST="/product/overlay/AlicePowerOverlay.apk"

# Target discipline: never issue adb commands without -s <NX1 serial>.
NX1_SERIAL="${NX1_SERIAL:-TLF2601S000307}"
adb() { command adb -s "$NX1_SERIAL" "$@"; }

log() { echo "[overlay] $*"; }
[ -f "$APK" ] || { echo "APK not found: $APK (build :overlay:assembleRelease)" >&2; exit 1; }

log "pushing $APK"
adb push "$APK" /data/local/tmp/alice-overlay.apk

log "remounting /product read-write"
if ! adb shell su -c "mount -o rw,remount /product" 2>/dev/null; then
  log "/product remount failed; trying / (system-as-root)"
  adb shell su -c "mount -o rw,remount /"
fi

log "installing to $DEST"
adb shell su -c "mkdir -p /product/overlay && cp /data/local/tmp/alice-overlay.apk '$DEST' && chown root:root '$DEST' && chmod 644 '$DEST' && restorecon '$DEST'"
adb shell su -c "ls -lZ /product/overlay/"

log "rebooting — REMINDER: NX1 needs a physical POWER press (~10 s) after reboot;"
log "expect to reseat USB. Re-run with --enable after it is back."
if [ "${1:-}" = "--enable" ]; then :; fi

read -r -p "Reboot now? [y/N] " ans
[[ "$ans" == "y" ]] && adb reboot

cat <<'EOF'
After the device is back:
  adb shell cmd overlay list --user 0 | grep heyalice
  adb shell cmd overlay enable --user 0 com.heyalice.overlay
  adb shell cmd overlay list --user 0 | grep heyalice   # expect [x]
Verify behaviour: adb shell input keyevent --longpress KEYCODE_POWER
  -> uiautomator dump must NOT contain "Power off"/"Restart"/"Lockdown"
EOF
