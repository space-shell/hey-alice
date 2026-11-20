#!/usr/bin/env bash
# patch-init-boot.sh — build Magisk-patched init_boot images from the backed-up
# stock images, entirely PC-side (no device involved). Plan D1.1 / handover 4.
#
# Patches BOTH A/B slots by default (the NX1 is A/B, current slot a at
# bring-up; whichever slot is active at flash time gets covered):
#   .backups/nx1-<date>/init_boot_a.bin -> init_boot_a.magisk.img
#   .backups/nx1-<date>/init_boot_b.bin -> init_boot_b.magisk.img
#
# Uses the official Magisk APK (pinned below) as the source of truth:
#   lib/x86_64/libmagiskboot.so  -> magiskboot   (host tool)
#   lib/arm64-v8a/*              -> payload binaries embedded into the ramdisk
#   assets/boot_patch.sh + util_functions.sh     (upstream patcher, run as-is)
#
# The stock images are NEVER modified — boot_patch.sh only reads them; the
# patched output lands in new files.
#
# Usage:
#   nix develop -c ../tools/patch-init-boot.sh [--allow-unverified] [STOCK.bin ...]
#     no args: both init_boot slots from the newest .backups/nx1-*/
#     --allow-unverified: required while the backup lacks its VERIFIED marker
#       (the on-disk manifest is still checked); unlock-flash.sh remains gated
#       on VERIFIED regardless
#   MAGISK_VERSION=v31.1 ../tools/patch-init-boot.sh ...  (pin override)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$SCRIPT_DIR/.magisk-work"
MAGISK_VERSION="${MAGISK_VERSION:-v31.1}"   # latest stable, resolved 2026-11-19
APK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk"

ALLOW_UNVERIFIED=0
STOCKS=()
die() { echo "FATAL: $*" >&2; exit 1; }
for a in "$@"; do
  case "$a" in
    --allow-unverified) ALLOW_UNVERIFIED=1 ;;
    --*) die "unknown flag: $a" ;;
    *) STOCKS+=("$a") ;;
  esac
done

log() { echo "[patch] $*"; }

mkdir -p "$WORK"
cd "$WORK"

# ---------- 1. fetch + unpack the official Magisk APK ----------
apk="Magisk-${MAGISK_VERSION}.apk"
if [ ! -f "$apk" ]; then
  log "Downloading $APK_URL"
  curl -fsSL -o "$apk" "$APK_URL" || die "APK download failed"
fi
[ -s "$apk" ] || die "APK file is empty"
# x86_64: host tool (magiskboot only). arm64-v8a: payload binaries embedded
# into the ramdisk — they run on the phone (arm64), never on this host.
stage="$WORK/magisk-${MAGISK_VERSION}"
rm -rf "$stage"; mkdir -p "$stage"
unzip -q -d "$stage" "$apk" \
  'lib/x86_64/libmagiskboot.so' \
  'lib/arm64-v8a/libmagiskinit.so' 'lib/arm64-v8a/libmagisk.so' 'lib/arm64-v8a/libinit-ld.so' \
  'assets/boot_patch.sh' 'assets/util_functions.sh' \
  || die "APK layout unexpected — inspect $apk manually (Magisk ≥31 dropped assets/stub.apk; the patcher needs magiskboot/magisk/magiskinit/init-ld + the two scripts only)"
chmod +x "$stage/lib/x86_64/libmagiskboot.so"

smoke_rc=0
"$stage/lib/x86_64/libmagiskboot.so" >/dev/null 2>&1 </dev/null || smoke_rc=$?
# magiskboot with no args prints usage and exits 1; only exec/missing is fatal
[ "$smoke_rc" -le 1 ] || die "libmagiskboot.so (x86_64) does not execute on this host (exit $smoke_rc) — use the Magisk-app fallback in tools/README.md"

# boot_patch.sh expects its payload next to itself (Magisk ≥31: no stub.apk):
ln -sf "lib/x86_64/libmagiskboot.so" "$stage/magiskboot"
ln -sf "lib/arm64-v8a/libmagiskinit.so" "$stage/magiskinit"
ln -sf "lib/arm64-v8a/libmagisk.so"     "$stage/magisk"
ln -sf "lib/arm64-v8a/libinit-ld.so"    "$stage/init-ld"
ln -sf "assets/boot_patch.sh"           "$stage/boot_patch.sh"
ln -sf "assets/util_functions.sh"       "$stage/util_functions.sh"

# ---------- 2. locate the stock images ----------
backup_dir=""
if [ "${#STOCKS[@]}" -eq 0 ]; then
  backup_dir="$(ls -dt "$REPO_ROOT"/.backups/nx1-* 2>/dev/null | head -1 || true)"
  [ -n "$backup_dir" ] || die "no .backups/nx1-*/ found — run backup.sh read first, or pass stock image paths"
  for s in a b; do
    [ -f "$backup_dir/init_boot_${s}.bin" ] && STOCKS+=("$backup_dir/init_boot_${s}.bin")
  done
else
  backup_dir="$(cd "$(dirname "${STOCKS[0]}")" && pwd)"
fi
[ "${#STOCKS[@]}" -gt 0 ] || die "no init_boot_*.bin images found in $backup_dir"

if [ "$ALLOW_UNVERIFIED" -ne 1 ] && [ ! -f "$backup_dir/VERIFIED" ]; then
  die "$backup_dir is not VERIFIED — rerun with --allow-unverified only on explicit owner/orchestrator order"
fi

# On-disk integrity: every stock image must match the committed manifest
if [ -f "$backup_dir/MANIFEST.sha256" ]; then
  for stock in "${STOCKS[@]}"; do
    ( cd "$backup_dir" && grep -F "$(basename "$stock")" MANIFEST.sha256 | sha256sum --quiet -c - ) \
      || die "$(basename "$stock") does not match MANIFEST.sha256 — backup integrity broken"
  done
  log "Stock images hash-match MANIFEST.sha256."
else
  log "WARNING: no MANIFEST.sha256 in $backup_dir — skipping integrity check"
fi

# ---------- 3. patch each slot ----------
# Flags mirror the Magisk app defaults for an unlocked-bootloader stock image:
# keep dm-verity + keep force-encrypt so AVB/fstab semantics stay stock.
# PREINITDEVICE: boot_patch would otherwise run ./magisk --preinit-device — an
# arm64 binary this host can't exec. The NX1 GPT has a metadata partition; the
# name is pinned so the patcher skips that call and pre-init storage is
# deterministic.
preinit_exports=""
if [ -f "$backup_dir/metadata.bin" ]; then
  preinit_exports="PREINITDEVICE=metadata"
  log "PREINITDEVICE=metadata (from backup GPT)"
else
  log "WARNING: no metadata.bin in backup — PREINITDEVICE unset; magiskinit will auto-detect pre-init storage. Verify root with the Magisk app after first boot."
fi

: > "$backup_dir/PATCHED-INIT_BOOT.txt.new"
echo "magisk: $MAGISK_VERSION (official release APK)" >> "$backup_dir/PATCHED-INIT_BOOT.txt.new"
echo "flags: KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false RECOVERYMODE=false PREINITDEVICE=metadata" >> "$backup_dir/PATCHED-INIT_BOOT.txt.new"

for stock in "${STOCKS[@]}"; do
  slotname="$(basename "$stock" .bin)"                 # e.g. init_boot_a
  out="$backup_dir/${slotname}.magisk.img"
  log "=== Patching $slotname ($(stat -c%s "$stock") bytes) ==="
  ( cd "$stage"
    rm -f kernel ramdisk.cpio ramdisk.cpio.orig stock_boot.img new-boot.img config config.orig *.xz
    BOOTMODE=true KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false \
    RECOVERYMODE=false LEGACYSAR=false \
    env $preinit_exports sh ./boot_patch.sh "$stock"
  ) || die "boot_patch.sh failed for $slotname — Magisk-app fallback documented in tools/README.md"
  [ -s "$stage/new-boot.img" ] || die "patcher produced no image for $slotname"

  # ---------- 4. verify the patched image ----------
  vdir="$WORK/verify-${slotname}-$(date +%s)"
  mkdir -p "$vdir"
  (
    cd "$vdir"
    "$stage/lib/x86_64/libmagiskboot.so" unpack "$stage/new-boot.img" >/dev/null
    status=0
    "$stage/lib/x86_64/libmagiskboot.so" cpio ramdisk.cpio test >/dev/null || status=$?
    [ "$status" -eq 1 ] || { echo "ramdisk test status: $status (0=stock, 1=Magisk-patched)" >&2; exit 1; }
    "$stage/lib/x86_64/libmagiskboot.so" cpio ramdisk.cpio "extract .backup/.magisk magisk-config" >/dev/null
    chmod 0644 magisk-config
    echo "--- $slotname embedded magisk config ---"; cat magisk-config; echo "-----------------------------------------"
  ) || die "patched $slotname verification FAILED — do not flash this image"
  log "Verified: $slotname ramdisk carries the Magisk patch signature (test status 1)."

  mv "$stage/new-boot.img" "$out"
  hash="$(sha256sum "$out" | cut -d' ' -f1)"
  {
    echo "image: ${slotname}.magisk.img"
    echo "source: $(basename "$stock") (mtkclient backup read)"
    echo "sha256: $hash"
  } >> "$backup_dir/PATCHED-INIT_BOOT.txt.new"
  log "DONE: $out  sha256: $hash"
done

# stock originals must still match the manifest after all patching
for stock in "${STOCKS[@]}"; do
  ( cd "$backup_dir" && grep -F "$(basename "$stock")" MANIFEST.sha256 | sha256sum --quiet -c - ) \
    || die "stock $(basename "$stock") changed during patching — integrity broken"
done
mv "$backup_dir/PATCHED-INIT_BOOT.txt.new" "$backup_dir/PATCHED-INIT_BOOT.txt"
log "PATCHED-INIT_BOOT.txt written (provenance for unlock-flash.sh gates)."
log "Flash these in the unlock session: tools/unlock-flash.sh (NOT in the bring-up run)."
