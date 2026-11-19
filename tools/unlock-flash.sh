#!/usr/bin/env bash
# unlock-flash.sh — NX1 bootloader unlock + Magisk init_boot flash.
#
#   ***  NOT EXECUTED IN THE BRING-UP RUN.  ***
#   This wipes the device (fastboot flashing unlock) and writes to it.
#   Run it ONLY in the dedicated unlock session with the owner physically
#   present (they confirm the on-device unlock prompt with volume-up).
#
# Preconditions (gated below, hard-fails if unmet):
#   - verified backup:   .backups/nx1-<date>/VERIFIED exists
#   - patched image:     .backups/nx1-<date>/magisk-patched-init_boot.img
#                        + PATCHED-INIT_BOOT.txt (sha256 recorded)
#   - owner confirmed wipe on the record (flag or interactive prompt)
#
# Usage:
#   nix develop -c ../tools/unlock-flash.sh                # interactive
#   UNLOCK_CONFIRMED=wipe-and-unlock ../tools/unlock-flash.sh [PATCHED.img]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[unlock-flash] $*"; }
confirm() { # confirm <question> — asks unless non-interactive
  if [ ! -t 0 ]; then die "non-interactive and $1 unanswered — set UNLOCK_CONFIRMED=wipe-and-unlock"; fi
  read -r -p "$1 [type UNLOCK to proceed]: " ans
  [ "$ans" = "UNLOCK" ] || die "aborted by operator"
}

for tool in adb fastboot; do command -v "$tool" >/dev/null || die "run inside tools devshell: nix develop -c bash $0"; done

# ---------- gate 0: explicit wipe consent ----------
if [ "${UNLOCK_CONFIRMED:-}" = "wipe-and-unlock" ]; then
  log "wipe consent recorded via UNLOCK_CONFIRMED"
else
  echo "THIS WIPES THE DEVICE (userdata, apps, settings — everything)."
  confirm "Proceed with bootloader unlock + wipe?"
fi

# ---------- gate 1: verified backup ----------
backup_dir="$(ls -dt "$REPO_ROOT"/.backups/nx1-* 2>/dev/null | head -1 || true)"
[ -n "$backup_dir" ] || die "no backup dir"
[ -f "$backup_dir/VERIFIED" ] || die "$backup_dir has no VERIFIED marker — run backup.sh verify first"
log "backup: $backup_dir (VERIFIED)"

# ---------- gate 2: patched image ----------
patched="${1:-$backup_dir/magisk-patched-init_boot.img}"
[ -f "$patched" ] || die "patched image missing: $patched (run patch-init-boot.sh)"
[ -f "$backup_dir/PATCHED-INIT_BOOT.txt" ] || die "PATCHED-INIT_BOOT.txt missing — provenance unrecorded"
log "patched image: $patched"
sha256sum "$patched"
grep -q "$(sha256sum "$patched" | cut -d' ' -f1)" "$backup_dir/PATCHED-INIT_BOOT.txt" \
  || die "patched image hash not recorded in PATCHED-INIT_BOOT.txt — re-run patch-init-boot.sh"

# ---------- gate 3: device present ----------
adb get-state >/dev/null 2>&1 || adb wait-for-device
[ "$(adb get-state)" = "device" ] || die "adb device not ready"

# ---------- step 1: reboot to bootloader ----------
log "rebooting to bootloader — owner: nothing to do yet"
adb reboot bootloader
for i in $(seq 1 30); do
  fastboot devices | grep -q . && break
  sleep 2
  [ "$i" = 30 ] && die "fastboot device never appeared"
done
log "fastboot online: $(fastboot devices | head -1)"

# ---------- step 2: unlock (WIPES) ----------
if [ "$(fastboot getvar unlocked 2>&1 | awk -F: '{gsub(/ /,"",$2); print $2}')" = "yes" ]; then
  log "bootloader already unlocked — skipping flashing unlock"
else
  echo "------------------------------------------------------------------"
  echo "OWNER ACTION REQUIRED:"
  echo "  'fastboot flashing unlock' will now show a confirmation screen."
  echo "  On the phone: press VOLUME UP to select Unlock, then POWER to confirm."
  echo "  The device wipes itself and reboots (takes a couple of minutes)."
  echo "------------------------------------------------------------------"
  confirm "Owner ready, start flashing unlock?"
  fastboot flashing unlock || true
  echo "Waiting for the wipe to finish and the device to come back..."
  adb wait-for-device || true
  for i in $(seq 1 120); do
    [ "$(adb get-state 2>/dev/null)" = "device" ] && break
    sleep 5
    [ "$i" = 120 ] && die "device did not return to adb after unlock — check screen; if stuck, mtkclient restore path in tools/README.md"
  done
fi

# ---------- step 3: post-wipe re-setup (owner) ----------
echo "------------------------------------------------------------------"
echo "OWNER ACTION REQUIRED (post-wipe setup):"
echo "  1. complete/skip the setup wizard (no SIM needed: skip)"
echo "  2. Settings → About → tap build number 7× → Developer options"
echo "  3. enable USB debugging + OEM unlocking"
echo "  4. accept the 'Allow USB debugging?' RSA prompt on the phone"
echo "------------------------------------------------------------------"
adb wait-for-device
for i in $(seq 1 240); do
  [ "$(adb get-state 2>/dev/null)" = "device" ] && break
  sleep 5
  [ "$i" = 240 ] && die "adb authorization never completed"
done

# ---------- step 4: verify unlock state, flash init_boot ----------
log "rebooting to bootloader again for the flash"
adb reboot bootloader
for i in $(seq 1 30); do fastboot devices | grep -q . && break; sleep 2; [ "$i" = 30 ] && die "no fastboot"; done
unlocked="$(fastboot getvar unlocked 2>&1 | awk -F: '{gsub(/ /,"",$2); print $2}')"
[ "$unlocked" = "yes" ] || die "bootloader reports unlocked='$unlocked' — refusing to flash on a locked bootloader"
log "bootloader confirmed unlocked — flashing init_boot"
# A/B device: plain name flashes the current slot
fastboot flash init_boot "$patched"
fastboot getvar current-slot
log "flash complete — rebooting"
fastboot reboot

# ---------- step 5: root verification ----------
log "waiting for boot (timeout 300s)..."
for i in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
  [ "$i" = 60 ] && { echo "BOOTLOOP SUSPECTED — do not panic: enter BROM (unplug, power off, hold Vol+Vol-, plug) and restore init_boot from the backup with: mtk w init_boot <backup>/init_boot_a.img (restore session, documented in tools/README.md)"; exit 1; }
done
"$SCRIPT_DIR/verify-root.sh"
