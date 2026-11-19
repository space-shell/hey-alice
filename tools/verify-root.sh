#!/usr/bin/env bash
# verify-root.sh — post-flash root verification for the NX1 (run AFTER the
# unlock session + Magisk init_boot flash + reboot). Read-only against device.
#
# Gates (each printed PASS/FAIL, exit 1 if any FAIL):
#   1. adb device online and boot completed
#   2. bootloader unlocked (vbmeta/verifiedbootstate props)
#   3. su works (uid 0)
#   4. Magisk binary answers, and the manager app is installed
#   5. Magisk's first-boot install completed (/data/adb exists, needs root)
#
# Usage: nix develop -c ../tools/verify-root.sh
set -uo pipefail

# Target discipline: another Android device on this network auto-connects to
# adb via mDNS/TCP. NEVER issue adb commands without -s <NX1 serial>.
NX1_SERIAL="${NX1_SERIAL:-TLF2601S000307}"
adb() { command adb -s "$NX1_SERIAL" "$@"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail=0
pass() { echo "PASS: $*"; }
failf() { echo "FAIL: $*"; fail=1; }

command -v adb >/dev/null || { echo "FATAL: run inside tools devshell (nix develop)"; exit 2; }

adb get-state >/dev/null 2>&1 || adb wait-for-device
state="$(adb get-state 2>/dev/null)"[ "$state" = "device" ] && pass "adb device online" || failf "adb state is '$state'"

boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
[ "$boot_completed" = "1" ] && pass "boot completed" || failf "sys.boot_completed=$boot_completed (bootloop? see tools/README.md → recovery)"

vbmeta_state="$(adb shell getprop ro.boot.vbmeta.device_state 2>/dev/null | tr -d '\r')"
vboot_state="$(adb shell getprop ro.boot.verifiedbootstate 2>/dev/null | tr -d '\r')"
[ "$vbmeta_state" = "unlocked" ] && pass "vbmeta device_state=unlocked" || failf "ro.boot.vbmeta.device_state=$vbmeta_state (expected unlocked)"
[ "$vboot_state" = "orange" ] && pass "verifiedbootstate=orange" || failf "ro.boot.verifiedbootstate=$vboot_state (expected orange)"

su_uid="$(adb shell su -c 'id -u' 2>/dev/null | tr -d '\r')"
[ "$su_uid" = "0" ] && pass "su → uid 0" || failf "su unavailable or not uid 0 (got '$su_uid')"

magisk_ver="$(adb shell su -c 'magisk -v 2>/dev/null || /data/adb/magisk/magisk -v' 2>/dev/null | tr -d '\r')"
echo "$magisk_ver" | grep -qi magisk && pass "magisk binary: $magisk_ver" || failf "magisk binary did not answer: '$magisk_ver'"

manager="$(adb shell pm list packages com.topjohnwu.magisk 2>/dev/null | tr -d '\r')"
[ -n "$manager" ] && pass "Magisk manager installed" || failf "com.topjohnwu.magisk not installed (install the APK from the release used for patching)"

preinit="$(adb shell su -c 'ls -d /data/adb 2>/dev/null' 2>/dev/null | tr -d '\r')"
[ "$preinit" = "/data/adb" ] && pass "pre-init dir /data/adb present" || failf "/data/adb missing — Magisk first-boot install did not complete"

echo "----------------------------------------"
if [ "$fail" -eq 0 ]; then
  echo "ROOT VERIFIED — all gates passed."
else
  echo "ROOT NOT VERIFIED — fix the FAIL items above. Recovery: tools/unlock-flash.sh rerun or mtkclient restore (tools/README.md)."
fi
exit "$fail"
