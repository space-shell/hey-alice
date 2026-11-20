#!/usr/bin/env bash
# patch-init-boot.sh — build a Magisk-patched init_boot.img from a stock image,
# entirely PC-side (no device involved). Plan D1.1 / handover deliverable 4.
#
# Uses the official Magisk APK (pinned below) as the source of truth:
#   lib/x86_64/libmagiskboot.so  -> magiskboot   (host tool)
#   lib/x86_64/libmagisk.so      -> magisk       (host helper: --preinit-device)
#   lib/arm64-v8a/*              -> payload binaries embedded into the ramdisk
#   assets/boot_patch.sh + util_functions.sh     (upstream patcher, run as-is)
#
# Output: <backup-dir>/magisk-patched-init_boot.img + its SHA256, verified by
# unpacking the result and checking the upstream Magisk-patch signature.
#
# Usage:  nix develop -c ../tools/patch-init-boot.sh [STOCK_INIT_BOOT.img]
#   With no argument, picks init_boot_a.bin from the newest .backups/nx1-*/.
#   Override version: MAGISK_VERSION=v31.1 ../tools/patch-init-boot.sh ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$SCRIPT_DIR/.magisk-work"
MAGISK_VERSION="${MAGISK_VERSION:-v31.1}"   # latest stable, resolved 2026-11-19
APK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VERSION}/Magisk-${MAGISK_VERSION}.apk"

die() { echo "FATAL: $*" >&2; exit 1; }
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
stage="magisk-${MAGISK_VERSION}"
rm -rf "$stage"; mkdir -p "$stage"
unzip -q "$apk" \
  'lib/x86_64/libmagiskboot.so' \
  'lib/arm64-v8a/libmagiskinit.so' 'lib/arm64-v8a/libmagisk.so' 'lib/arm64-v8a/libinit-ld.so' \
  'assets/stub.apk' 'assets/boot_patch.sh' 'assets/util_functions.sh' \
  || die "APK layout unexpected — inspect $apk manually"
chmod +x "lib/x86_64/libmagiskboot.so"

host_ok=true
"lib/x86_64/libmagiskboot.so" >/dev/null 2>&1 </dev/null || host_ok=false
$host_ok || die "libmagiskboot.so (x86_64) does not execute on this host — use the Magisk-app fallback in tools/README.md"

# boot_patch.sh expects its payload next to itself:
ln -sf "lib/x86_64/libmagiskboot.so" "$stage/magiskboot"
ln -sf "lib/arm64-v8a/libmagiskinit.so" "$stage/magiskinit"
ln -sf "lib/arm64-v8a/libmagisk.so"     "$stage/magisk"
ln -sf "lib/arm64-v8a/libinit-ld.so"    "$stage/init-ld"
ln -sf "assets/stub.apk"                "$stage/stub.apk"
ln -sf "assets/boot_patch.sh"           "$stage/boot_patch.sh"
ln -sf "assets/util_functions.sh"       "$stage/util_functions.sh"

# ---------- 2. locate the stock init_boot ----------
stock="${1:-}"
if [ -z "$stock" ]; then
  newest_backup="$(ls -dt "$REPO_ROOT"/.backups/nx1-* 2>/dev/null | head -1 || true)"
  [ -n "$newest_backup" ] || die "no .backups/nx1-*/ found — run backup.sh read first, or pass a stock image path"
  [ -f "$newest_backup/VERIFIED" ] || die "$newest_backup is not VERIFIED — refusing to patch from an unverified backup"
  stock="$newest_backup/init_boot_a.bin"
fi
[ -f "$stock" ] || die "stock image not found: $stock"
log "Stock image: $stock ($(stat -c%s "$stock") bytes)"
backup_dir="$(cd "$(dirname "$stock")" && pwd)"

# ---------- 3. run the upstream patcher (BOOTMODE=true: plain stdout) ----------
# Flags mirror the Magisk app defaults for an unlocked-bootloader stock image:
# keep dm-verity + keep force-encrypt so AVB/fstab semantics stay stock.
# PREINITDEVICE: boot_patch would otherwise run ./magisk --preinit-device — an
# arm64 binary this host can't exec. The NX1 GPT has a metadata partition (it is
# in the backup); exporting the name makes the patcher skip that call and pins
# Magisk's pre-init storage deterministically.
out="new-boot.img"
rm -f "$out"
preinit_exports=""
if [ -f "$backup_dir/metadata.bin" ]; then
  preinit_exports="PREINITDEVICE=metadata"
  log "PREINITDEVICE=metadata (from backup GPT)"
else
  log "WARNING: no metadata.bin in backup — PREINITDEVICE unset; magiskinit will auto-detect pre-init storage. Verify root with the Magisk app after first boot."
fi
(
  cd "$stage"
  env $preinit_exports \
  BOOTMODE=true KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false \
  RECOVERYMODE=false LEGACYSAR=false \
  sh ./boot_patch.sh "$stock"
) || die "boot_patch.sh failed — see output above; Magisk-app fallback documented in tools/README.md"
[ -s "$out" ] || die "patcher produced no image"

# ---------- 4. verify the patched image ----------
vdir="$WORK/verify-$(date +%s)"
mkdir -p "$vdir"
(
  cd "$vdir"
  "$WORK/$stage/magiskboot" unpack "$WORK/$out" >/dev/null
  status=0
  "$WORK/$stage/magiskboot" cpio ramdisk.cpio test >/dev/null || status=$?
  [ "$status" -eq 1 ] || { echo "ramdisk test status: $status (0=stock, 1=Magisk-patched)" >&2; exit 1; }
  "$WORK/$stage/magiskboot" cpio ramdisk.cpio "extract .backup/.magisk magisk-config" >/dev/null
  echo "--- embedded magisk config ---"; cat magisk-config; echo "-------------------------------"
) || die "patched image verification FAILED — do not flash this image"
log "Verified: ramdisk carries the Magisk patch signature (test status 1)."

# ---------- 5. publish ----------
dest="$backup_dir/magisk-patched-init_boot.img"
cp -v "$WORK/$out" "$dest"
hash="$(sha256sum "$dest" | cut -d' ' -f1)"
{
  echo "image: magisk-patched-init_boot.img"
  echo "magisk: $MAGISK_VERSION (official release APK)"
  echo "source: $(basename "$stock") (mtkclient backup, VERIFIED)"
  echo "sha256: $hash"
  echo "flags: KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false RECOVERYMODE=false"
} > "$backup_dir/PATCHED-INIT_BOOT.txt"
log "DONE: $dest"
log "sha256: $hash"
log "Flash this in the unlock session: tools/unlock-flash.sh (do NOT run it today)."
