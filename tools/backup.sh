#!/usr/bin/env bash
# backup.sh — NX1 full-partition backup via mtkclient (BROM mode). READ-ONLY.
#
# Plan D1.1 / M0. Reads every GPT partition except userdata (+ preloader region)
# into .backups/nx1-<date>/, writes a sha256sum manifest, then re-reads
# everything in a second BROM session and hard-fails unless every file's hash
# matches. Only after a clean verify pass is the VERIFIED marker written.
#
# The device must be in BROM mode when each phase starts (mtkclient waits for
# it, so start the phase first, then do the physical key combo):
#   1. unplug USB cable
#   2. power the phone OFF (hold power, confirm shutdown)
#   3. press and HOLD volume-up + volume-down
#   4. keep holding while plugging the USB cable back in
#   5. mtkclient picks the device up and the phase proceeds (hold keys ~5s more)
#
# Usage:
#   backup.sh read   [DIR] [--skip P1,P2]   # BROM session 1: read + manifest
#   backup.sh verify [DIR] [--skip P1,P2]   # BROM session 2: re-read + compare
#   backup.sh status [DIR]                  # no device needed: manifest report
#
# DIR defaults to the newest .backups/nx1-* directory (for verify) or a fresh
# nx1-<timestamp> (for read). Run each phase in this devshell:
#   cd tools && nix develop -c ../tools/backup.sh read
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUPS_ROOT="$REPO_ROOT/.backups"
DEFAULT_SKIP="userdata"

usage() { grep '^#' "$0" | sed -n '2,22p'; exit 2; }

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[backup] $*"; }

newest_backup_dir() {
  ls -dt "$BACKUPS_ROOT"/nx1-* 2>/dev/null | head -1 || true
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
    ;&
  verify)
    [ -z "$DIR" ] && DIR="$(newest_backup_dir)"
    [ -n "$DIR" ] || die "no backup directory found under $BACKUPS_ROOT"
    ;;
  status) [ -z "$DIR" ] && DIR="$(newest_backup_dir)"; [ -n "$DIR" ] || die "no backup directory found" ;;
  *) usage ;;
esac

manifest_check() { # manifest_check <dir> — verify every manifest hash on disk
  ( cd "$1" && sha256sum --quiet -c MANIFEST.sha256 )
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

brom_banner() {
  echo "==================================================================="
  echo "$1. On the phone, do the BROM entry:"
  echo "  1. unplug USB   2. power OFF   3. hold Vol+ and Vol-"
  echo "  4. plug USB back in, keep holding the keys ~5 seconds"
  echo "mtkclient is waiting for the device..."
  echo "==================================================================="
}

case "$PHASE" in
  read)
    brom_banner "PHASE 1 of 2 — READ"
    # --write_preloader_to_file: preloader lives outside the GPT; dump it too.
    # --skip userdata: owner data + 100+ GB, excluded by plan D1.1.
    if ! mtk rl "$DIR" --skip "$SKIP" --write_preloader_to_file 2>&1 | tee "$mtk_log"; then
      echo "WARNING: mtk rl exited nonzero — see $mtk_log" >&2
    fi
    # normalise the preloader dump name (mtkclient writes preloader*.bin)
    for f in "$DIR"/preloader*.bin; do
      [ -e "$f" ] || continue
      [ "$f" = "$DIR/preloader.img" ] || mv -v "$f" "$DIR/preloader.img"
    done
    count=$(find "$DIR" -maxdepth 1 -type f ! -name '*.log' | wc -l)
    [ "$count" -gt 0 ] || die "mtkclient produced no files — read failed, see $mtk_log"
    ( cd "$DIR" && find . -maxdepth 1 -type f ! -name '*.log' -printf '%f\n' | sort | xargs sha256sum > MANIFEST.sha256 )
    rm -f "$DIR/VERIFIED"
    log "READ done: $count files, manifest written (NOT yet verified)."
    log "Next: run '$0 verify $DIR' — a SECOND BROM session (same key combo) is needed."
    ;;

  verify)
    [ -f "$DIR/MANIFEST.sha256" ] || die "no MANIFEST.sha256 in $DIR — run 'read' first"
    brom_banner "PHASE 2 of 2 — VERIFY"
    vdir="$DIR/.verify"
    rm -rf "$vdir"; mkdir -p "$vdir"
    if ! mtk rl "$vdir" --skip "$SKIP" --write_preloader_to_file 2>&1 | tee "$mtk_log"; then
      echo "WARNING: mtk rl exited nonzero — see $mtk_log" >&2
    fi
    for f in "$vdir"/preloader*.bin; do
      [ -e "$f" ] || continue
      [ "$f" = "$vdir/preloader.img" ] || mv -v "$f" "$vdir/preloader.img"
    done
    fail=0
    mismatch=0; missing=0; extra=0; ok=0
    # every manifest entry must exist with an identical hash
    while read -r hash file; do
      if [ ! -f "$vdir/$file" ]; then
        echo "MISSING in re-read: $file" >&2; missing=$((missing+1)); fail=1
      elif [ "$hash" != "$(sha256sum "$vdir/$file" | cut -d' ' -f1)" ]; then
        echo "HASH MISMATCH: $file" >&2; mismatch=$((mismatch+1)); fail=1
      else ok=$((ok+1)); fi
    done < "$DIR/MANIFEST.sha256"
    # no undeclared files may appear between passes
    ( cd "$vdir" && find . -type f -printf '%P\n' | sort ) > "$vdir/.listing"
    ( cd "$DIR" && awk '{print $2}' MANIFEST.sha256 | sort ) > "$vdir/.expected"
    if ! diff -u "$vdir/.expected" "$vdir/.listing" > "$vdir/.setdiff"; then
      echo "FILE SET CHANGED between passes:" >&2; cat "$vdir/.setdiff" >&2; extra=1; fail=1
    fi
    if [ "$fail" -ne 0 ]; then
      printf 'VERIFY FAILED %s\n  ok=%d mismatch=%d missing=%d set-changed=%d\n' \
        "$(date -Is)" "$ok" "$mismatch" "$missing" "$extra" > "$DIR/VERIFY-FAILED.txt"
      log "VERIFY FAILED — $DIR/.verify kept for forensics. DO NOT unlock/flash."
      exit 1
    fi
    rm -rf "$vdir"
    printf 'verified %s with mtkclient 2.1.4; %d files, 2-pass readback hash match\n' \
      "$(date -Is)" "$ok" > "$DIR/VERIFIED"
    log "VERIFY PASSED: $ok files match across two independent BROM reads."
    log "Backup is trustworthy — unlock/flash may proceed in a later session."
    ;;
esac
