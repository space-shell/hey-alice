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

# Target discipline: another Android device on this network auto-connects to
# adb via mDNS/TCP. NEVER issue adb commands without -s <NX1 serial>.
# fastboot is USB-only and single-device here; mtkclient targets BROM by VID.
NX1_SERIAL="${NX1_SERIAL:-TLF2601S000307}"
adb() { command adb -s "$NX1_SERIAL" "$@"; }

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

# Flash-relevant set must be on disk and manifest-exact, independent of the
# overall verdict (super risk is documented separately, it does not gate root
# flashing — we only ever flash init_boot).
FLASH_CRITICAL="boot_a.bin boot_b.bin init_boot_a.bin init_boot_b.bin vbmeta_a.bin vbmeta_b.bin preloader-boot1.bin"
for f in $FLASH_CRITICAL; do
  [ -f "$backup_dir/$f" ] || die "flash-critical file missing from backup: $f"
  ( cd "$backup_dir" && grep -F "$f" MANIFEST.sha256 | sha256sum --quiet -c - ) \
    || die "flash-critical file fails manifest check: $f"
done
log "flash-critical set verified on disk: $FLASH_CRITICAL"

# ---------- gate 2: patched images ----------
if [ "${1:-}" ]; then
  patched="$1"
  [ -f "$patched" ] || die "patched image missing: $patched (run patch-init-boot.sh)"
  grep -qF "$(sha256sum "$patched" | cut -d' ' -f1)" "$backup_dir/PATCHED-INIT_BOOT.txt" \
    || die "patched image hash not recorded in PATCHED-INIT_BOOT.txt — re-run patch-init-boot.sh"
  log "patched image (explicit): $patched"
  slot_img_provided=1
else
  # A/B device: pick per-slot images at flash time from the CURRENT slot.
  for s in a b; do
    [ -f "$backup_dir/init_boot_${s}.magisk.img" ] || die "missing $backup_dir/init_boot_${s}.magisk.img — run patch-init-boot.sh (patches both slots)"
    grep -qF "$(sha256sum "$backup_dir/init_boot_${s}.magisk.img" | cut -d' ' -f1)" "$backup_dir/PATCHED-INIT_BOOT.txt" \
      || die "init_boot_${s}.magisk.img hash not recorded in PATCHED-INIT_BOOT.txt — re-run patch-init-boot.sh"
  done
  log "patched images: init_boot_{a,b}.magisk.img (slot picked at flash time)"
  slot_img_provided=0
fi

# ---------- gate 3: device present (skipped when already in fastboot) ----------
if ! fastboot devices | grep -q .; then
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
fi
log "fastboot online: $(fastboot devices | head -1)"

# ---------- step 2: unlock (WIPES) ----------
if [ "$(fastboot getvar unlocked 2>&1 | awk -F: '/unlocked:/{gsub(/ /,"",$2); print $2}')" = "yes" ]; then
  log "bootloader already unlocked — skipping flashing unlock"
else
  echo "------------------------------------------------------------------"
  echo "OWNER ACTION REQUIRED:"
  echo "  'fastboot flashing unlock' starts now — IMMEDIATELY (within a"
  echo "  second or two) press VOLUME UP on the phone (quick press)."
  echo "  Source: bluefox-guide.neocities.org/unlock.html (NX1-verified)."
  echo "  The device wipes itself and reboots (takes a couple of minutes)."
  echo "------------------------------------------------------------------"
  if [ "${UNLOCK_CONFIRMED:-}" = "wipe-and-unlock" ]; then
    log "pre-unlock confirm satisfied via UNLOCK_CONFIRMED"
  else
    confirm "Owner ready, start flashing unlock?"
  fi
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
echo "  2. Settings → About → Version → tap build number 10× →"
echo "     System → Developer options"
echo "  3. enable USB debugging + OEM unlocking"
echo "  4. accept the 'Allow USB debugging?' RSA prompt on the phone"
echo "  If USB debugging cannot be re-enabled, enter fastboot from the"
echo "  physical early-boot menu instead: power off, hold POWER then VOL UP"
echo "  (3-option menu), VOL UP navigates, VOL DOWN confirms → Fastboot."
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
unlocked="$(fastboot getvar unlocked 2>&1 | awk -F: '/unlocked:/{gsub(/ /,"",$2); print $2}')"
[ "$unlocked" = "yes" ] || die "bootloader reports unlocked='$unlocked' — refusing to flash on a locked bootloader"
log "bootloader confirmed unlocked — flashing init_boot"
# A/B device: flash the CURRENT slot's Magisk image (slot confirmed here, not
# assumed — a wipe does not switch slots, but the check is free insurance).
if [ "$slot_img_provided" = 1 ]; then
  fastboot flash init_boot "$patched"
else
  slot="$(fastboot getvar current-slot 2>&1 | awk -F: '/current-slot:/{gsub(/ /,"",$2); print $2}')"
  case "$slot" in a|b) ;; *) die "could not determine current slot (got '$slot') — pass an image path explicitly" ;; esac
  patched="$backup_dir/init_boot_${slot}.magisk.img"
  log "current slot: $slot → flashing $patched"
  sha256sum "$patched"
  fastboot flash init_boot "$patched"
fi
fastboot getvar current-slot
log "flash complete — rebooting"
fastboot reboot

# ---------- step 5: root verification ----------
log "waiting for boot (timeout 300s)..."
for i in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
  [ "$i" = 60 ] && { echo "BOOTLOOP SUSPECTED — do not panic: enter BROM (unplug, power off, hold Vol+Vol-, plug) and restore init_boot from the backup with: mtk w init_boot <backup>/init_boot_a.bin (restore session, documented in tools/README.md)"; exit 1; }
done
"$SCRIPT_DIR/verify-root.sh"
