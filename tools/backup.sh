#!/usr/bin/env bash
# backup.sh — NX1 full-partition backup via mtkclient (BROM mode). READ-ONLY.
#
# Plan D1.1 / M0. Reads every GPT partition except userdata, plus the eMMC
# Boot1 region (the real preloader), into .backups/nx1-<date>/, writes a
# sha256sum manifest, then re-reads everything in a second BROM session and
# hard-fails unless every file's hash matches. Only after a clean verify pass
# is the VERIFIED marker written.
#
# Each phase needs TWO BROM entries (rl pass + Boot1 preloader read); the
# script prompts between them and waits for the device itself.
#
# BROM entry (physical, owner):
#   1. if plugged: unplug the USB cable            <- REQUIRED: while the phone
#   2. hold POWER ~10 s until completely off          is attached in normal
#   3. press and hold Vol+ and Vol−                   (adb) mode 0e8d:201c,
#   4. plug USB back in, screen must stay BLACK       mtkclient grabs it and
#   5. release once mtkclient starts reading          handshake-fails forever
#
# Usage:
#   backup.sh read     [DIR] [--skip P1,P2]  # BROM ×2: rl + Boot1 + manifest
#   backup.sh preloader [DIR]                # BROM ×1: Boot1 read (completes a read)
#   backup.sh verify   [DIR] [--skip P1,P2]  # BROM ×2: re-read everything + compare
#   backup.sh status   [DIR]                 # no device needed: manifest report
#
# DIR defaults to the newest .backups/nx1-* directory (for verify) or a fresh
# nx1-<timestamp> (for read). Run each phase in this devshell:
#   cd tools && nix develop -c ../tools/backup.sh read
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUPS_ROOT="$REPO_ROOT/.backups"
DEFAULT_SKIP="userdata"
# Volatile partition: written by the bootloader during normal boots (flags),
# so it legitimately differs between two reads. Warned about, not failed.
VOLATILE="misc.bin"

usage() { grep '^#' "$0" | sed -n '2,25p'; exit 2; }

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[backup] $*"; }

newest_backup_dir() {
  ls -dt "$BACKUPS_ROOT"/nx1-* 2>/dev/null | head -1 || true
}

# The NX1 in normal (adb) mode is 0e8d:201c; off+plugged without keys sits in
# preloader mode 0e8d:2000/2001 — mtkclient's preloader handshake fails on this
# device (observed 2026-11-20), so ONLY real BROM (0e8d:0003) or a detached
# bus may be handed to mtkclient. Anything else blocks until the owner unplugs
# and redoes the entry with both volume keys held.
phone_blocking() {
  for d in /sys/bus/usb/devices/*/idVendor; do
    [ "$(cat "$d" 2>/dev/null)" = "0e8d" ] || continue
    p="$(cat "${d%/*}/idProduct" 2>/dev/null)"
    [ "$p" = "0003" ] && continue   # real BROM is fine
    return 0                        # 201c / 2000 / 2001 / anything else: block
  done
  return 1
}

wait_phone_unplugged() {
  # After a finished pass the phone reboots back to normal (or preloader) mode.
  # Let that settle — it re-appears on USB within ~1 min of the reset — then
  # require an unplug+proper-BROM-entry before mtkclient starts.
  settled=0
  for i in $(seq 1 25); do
    if phone_blocking; then settled=1; break; fi
    sleep 3
  done
  if [ "$settled" = 1 ]; then
    log "Phone is attached in a non-BROM mode (adb=0e8d:201c or preloader=0e8d:2000/2001)."
    log "UNPLUG it now, power it OFF (hold POWER ~10 s), then:"
    log "  hold Vol+ and Vol− and plug it back in (screen stays black)."
    log "This script starts mtkclient the moment a real BROM device (0e8d:0003)"
    log "appears — or the bus goes quiet."
    while phone_blocking; do sleep 5; done
    log "Handing off to mtkclient."
  fi
}

brom_banner() {
  echo "==================================================================="
  echo "$1 — on the phone, do the BROM entry:"
  echo "  1. if plugged: unplug the USB cable"
  echo "  2. hold POWER ~10 s until the phone is completely off"
  echo "     (screen dead — a charging logo on plug-in means it was NOT off)"
  echo "  3. press and hold Vol+ and Vol− (both, firmly)"
  echo "  4. plug USB back in while holding both keys — the phone screen"
  echo "     must stay BLACK; keep holding ~10 s until activity starts here"
  echo "  5. if the phone shows charging/boot animation: it booted normally;"
  echo "     unplug, force power off again (hold POWER 10 s), retry from step 3"
  echo "==================================================================="
}

# mtk <args...> — BROM read invocation; pre-guarded by wait_phone_unplugged.
mtk_read() {
  wait_phone_unplugged
  mtk --debugmode "$@"
}

SKIP="$DEFAULT_SKIP"
PHASE="${1:-}"; shift || true
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --skip) SKIP="$SKIP,$2"; shift 2 ;;
    --*) usage ;;
    *) DIR="$1"; shift ;;
  esac
done

[ -n "$PHASE" ] || usage
command -v mtk >/dev/null || die "mtk not found — run inside tools devshell: nix develop -c bash backup.sh $PHASE"

case "$PHASE" in
  read)
    [ -z "$DIR" ] && DIR="$BACKUPS_ROOT/nx1-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$DIR"
    rm -f "$DIR/MANIFEST.sha256" "$DIR/VERIFIED" "$DIR/VERIFY-FAILED.txt"
    ;;
  preloader)
    [ -z "$DIR" ] && DIR="$(newest_backup_dir)"
    [ -n "$DIR" ] || die "no backup directory found under $BACKUPS_ROOT"
    ;;
  verify)
    [ -z "$DIR" ] && DIR="$(newest_backup_dir)"
    [ -n "$DIR" ] || die "no backup directory found under $BACKUPS_ROOT"
    ;;
  status) [ -z "$DIR" ] && DIR="$(newest_backup_dir)"; [ -n "$DIR" ] || die "no backup directory found" ;;
  *) usage ;;
esac

write_manifest() { # write_manifest <dir> — sha256 of every dump file (no dotfiles/logs/self/markers)
  ( cd "$1" && find . -maxdepth 1 -type f ! -name '.*' ! -name '*.log' \
      ! -name 'MANIFEST.sha256' ! -name 'VERIFIED' ! -name 'VERIFY-FAILED.txt' \
      -printf '%f\n' | sort | xargs sha256sum > MANIFEST.sha256 )
}

case "$PHASE" in
  status)
    echo "Backup dir: $DIR"
    if [ -f "$DIR/VERIFIED" ]; then echo "Status: VERIFIED ($(cat "$DIR/VERIFIED"))"; else echo "Status: NOT verified"; fi
    if [ -f "$DIR/MANIFEST.sha256" ]; then
      ( cd "$DIR" && wc -l MANIFEST.sha256 && sha256sum --quiet -c MANIFEST.sha256 && echo "On-disk hashes: OK" || echo "On-disk hashes: MISMATCH" )
    else echo "No manifest yet."; fi
    exit 0 ;;
esac

mtk_log="$DIR/mtk-$PHASE.log"

case "$PHASE" in
  read)
    brom_banner "PHASE 1 of 2 — READ (pass 1/2: all GPT partitions)"
    # --skip userdata: owner data + 100+ GB, excluded by plan D1.1.
    if ! mtk_read rl "$DIR" --skip "$SKIP" 2>&1 | tee "$mtk_log"; then
      echo "WARNING: mtk rl exited nonzero — see $mtk_log" >&2
    fi
    count=$(find "$DIR" -maxdepth 1 -type f ! -name '.*' ! -name '*.log' | wc -l)
    [ "$count" -gt 0 ] || {
      if phone_blocking; then
        echo "DIAGNOSIS: the phone is attached in normal (adb) mode (0e8d:201c) — it was" >&2
        echo "ON while plugged, and mtkclient handshake-fails against a running phone." >&2
        echo "Unplug it, power OFF fully (hold POWER ~10 s), hold Vol+ and Vol−, plug in." >&2
      fi
      die "mtkclient produced no files — read failed, see $mtk_log"
    }

    brom_banner "PHASE 1 of 2 — READ (pass 2/2: eMMC Boot1 = the real preloader)"
    if ! mtk_read r preloader "$DIR/preloader-boot1.bin" --parttype boot1 2>&1 | tee -a "$mtk_log"; then
      echo "WARNING: boot1 preloader read failed — see $mtk_log" >&2
    fi
    [ -s "$DIR/preloader-boot1.bin" ] || log "WARNING: preloader-boot1.bin missing or empty"

    write_manifest "$DIR"
    rm -f "$DIR/VERIFIED"
    count=$(grep -c . "$DIR/MANIFEST.sha256")
    log "READ done: $count files hashed, manifest written (NOT yet verified)."
    log "Next: run '$0 verify $DIR' — a SECOND BROM session (same 2 passes) is needed."
    ;;

  preloader)
    brom_banner "PRELOADER — eMMC Boot1 (the real preloader, 4 MB)"
    if ! mtk_read r preloader "$DIR/preloader-boot1.bin" --parttype boot1 2>&1 | tee -a "$DIR/mtk-$PHASE.log"; then
      echo "WARNING: boot1 preloader read failed — see $DIR/mtk-$PHASE.log" >&2
    fi
    size=$(stat -c%s "$DIR/preloader-boot1.bin" 2>/dev/null || echo 0)
    [ "$size" -gt 0 ] || {
      if phone_blocking; then
        echo "DIAGNOSIS: phone attached in normal (adb) mode (0e8d:201c) — unplug, power OFF fully, hold Vol+Vol−, plug in." >&2
      fi
      die "preloader-boot1.bin not written — see $DIR/mtk-$PHASE.log"
    }
    [ "$size" -eq 4194304 ] || log "NOTE: boot1 dump is $size bytes (expected 4194304 = 0x400000)"
    write_manifest "$DIR"
    log "PRELOADER captured ($size bytes); manifest regenerated ($(grep -c . "$DIR/MANIFEST.sha256") files)."
    ;;

  verify)
    [ -f "$DIR/MANIFEST.sha256" ] || die "no MANIFEST.sha256 in $DIR — run 'read' first"
    # expected files from rl = manifest minus preloader-boot1.bin (read separately)
    expected=$(( $(grep -c . "$DIR/MANIFEST.sha256") - 1 ))
    vdir="$DIR/.verify"
    attempt=1
    while [ "$attempt" -le 3 ]; do
      rm -rf "$vdir"; mkdir -p "$vdir"
      brom_banner "PHASE 2 of 2 — VERIFY pass 1/2 — re-read all GPT partitions (attempt $attempt/3)"
      if ! mtk_read rl "$vdir" --skip "$SKIP" 2>&1 | tee -a "$mtk_log"; then
        echo "WARNING: mtk rl exited nonzero — see $mtk_log" >&2
      fi
      vdump=$(find "$vdir" -maxdepth 1 -type f ! -name '.*' | wc -l)
      [ "$vdump" -ge "$expected" ] && break
      echo "VERIFY re-read attempt $attempt incomplete: $vdump/$expected files — retrying" >&2
      attempt=$((attempt+1))
    done
    [ "$vdump" -ge "$expected" ] || {
      if phone_blocking; then
        echo "DIAGNOSIS: the phone is attached in normal (adb) mode (0e8d:201c) — it was" >&2
        echo "ON while plugged, and mtkclient handshake-fails against a running phone." >&2
        echo "Unplug it, power OFF fully (hold POWER ~10 s), hold Vol+ and Vol−, plug in." >&2
      fi
      tail -5 "$mtk_log" >&2
      die "verify re-read produced no files — see $mtk_log"
    }

    brom_banner "PHASE 2 of 2 — VERIFY pass 2/2 — re-read eMMC Boot1 preloader"
    if ! mtk_read r preloader "$vdir/preloader-boot1.bin" --parttype boot1 2>&1 | tee -a "$mtk_log"; then
      echo "WARNING: boot1 preloader re-read failed — see $mtk_log" >&2
    fi

    fail=0
    mismatch=0; missing=0; volatile=0; ok=0
    # every manifest entry must exist in the re-read with an identical hash
    # (volatile partitions may differ — warned, not failed)
    while read -r hash file; do
      if [ ! -f "$vdir/$file" ]; then
        if [ "$file" = "$VOLATILE" ]; then
          echo "VOLATILE missing (not verified): $file" >&2; volatile=$((volatile+1)); continue
        fi
        echo "MISSING in re-read: $file" >&2; missing=$((missing+1)); fail=1
      elif [ "$hash" != "$(sha256sum "$vdir/$file" | cut -d' ' -f1)" ]; then
        if [ "$file" = "$VOLATILE" ]; then
          echo "VOLATILE hash differs (not verified): $file" >&2; volatile=$((volatile+1)); continue
        fi
        echo "HASH MISMATCH: $file" >&2; mismatch=$((mismatch+1)); fail=1
      else ok=$((ok+1)); fi
    done < "$DIR/MANIFEST.sha256"
    # no undeclared files may appear between passes (ignore dotfiles = mtk session artifacts)
    ( cd "$vdir" && find . -type f ! -name '.*' -printf '%P\n' | sort ) > "$vdir/.listing"
    ( cd "$DIR" && awk '{print $2}' MANIFEST.sha256 | sort ) > "$vdir/.expected"
    if ! diff -u "$vdir/.expected" "$vdir/.listing" > "$vdir/.setdiff"; then
      echo "FILE SET CHANGED between passes:" >&2; cat "$vdir/.setdiff" >&2; fail=1
    fi
    if [ "$fail" -ne 0 ]; then
      printf 'VERIFY FAILED %s\n  ok=%d mismatch=%d missing=%d volatile-skipped=%d\n' \
        "$(date -Is)" "$ok" "$mismatch" "$missing" "$volatile" > "$DIR/VERIFY-FAILED.txt"
      log "VERIFY FAILED — $DIR/.verify kept for forensics. DO NOT unlock/flash."
      exit 1
    fi
    rm -rf "$vdir"
    rm -f "$DIR/VERIFY-FAILED.txt"
    printf 'verified %s with mtkclient 2.1.4.1; %d files, 2-pass readback hash match (incl. eMMC Boot1 preloader); volatile skipped: %s\n' \
      "$(date -Is)" "$ok" "$VOLATILE" > "$DIR/VERIFIED"
    log "VERIFY PASSED: $ok files match across two independent BROM reads ($volatile volatile skipped)."
    log "Backup is trustworthy — unlock/flash may proceed in a later session."
    ;;
esac
