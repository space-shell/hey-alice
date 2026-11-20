#!/usr/bin/env bash
# super-tiebreak.sh — resolve a super.bin hash disagreement between backup
# reads with a tie-break third read. Plan D1.1 / verify session.
#
# Inputs:
#   read #1 hash  = MANIFEST.sha256 entry (original read session)
#   read #2 hash  = .verify/super.bin      (first verify re-read)
#   read #3 hash  = .verify3/super.bin     (tie-break re-read)
#
# Verdict (all three must be full-size 9,663,676,416 B):
#   h3 == h1  → read#2 was a verify-pass glitch; backup good; super verified
#               by reads 1+3; super.bin on disk (read#1) kept.
#   h3 == h2  → read#1 was glitched at that offset; backup good (2+3 agree);
#               super.bin replaced with the agreeing copy and the manifest
#               line updated so the committed manifest matches the kept file.
#   neither   → super UNVERIFIED (warn-level): read#1 file kept, restore of
#               super carries risk; everything else stays verified. Root
#               flashing (init_boot) does not depend on super.
#
# Path convention: the tie-break (third) read must land as `super.bin` inside
# its read directory — mtkclient names dumps after the partition requested,
# so `mtk r preloader .verify3/super.tiebreak.bin` writes super.tiebreak.bin;
# rename it to super.bin (or symlink) before running this script.
#
# READ-ONLY against the device. Usage:
#   nix develop -c ../tools/super-tiebreak.sh [DIR [READ2_DIR [READ3_DIR]]]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[super-tiebreak] $*"; }

DIR="${1:-$(ls -dt "$REPO_ROOT"/.backups/nx1-* 2>/dev/null | head -1 || true)}"
[ -n "$DIR" ] || die "no backup dir"
R2="${2:-$DIR/.verify}"
R3="${3:-$DIR/.verify3}"
[ -f "$DIR/MANIFEST.sha256" ] || die "no MANIFEST.sha256 in $DIR"

expected_size=9663676416
h1="$(awk '$2=="super.bin"{print $1}' "$DIR/MANIFEST.sha256")"
[ -n "$h1" ] || die "manifest has no super.bin entry"
[ -f "$R2/super.bin" ] || die "no $R2/super.bin"
[ -f "$R3/super.bin" ] || die "no $R3/super.bin — run the tie-break read first"
h2="$(sha256sum "$R2/super.bin" | cut -d' ' -f1)"
h3="$(sha256sum "$R3/super.bin" | cut -d' ' -f1)"
s1="$(stat -c%s "$DIR/super.bin")"; s2="$(stat -c%s "$R2/super.bin")"; s3="$(stat -c%s "$R3/super.bin")"

out="$DIR/SUPER-TIEBREAK.txt"
{
  echo "super.bin tie-break — $(date -Is)"
  echo "expected size: $expected_size"
  echo "read1 (manifest + on disk): $h1  ($s1 B)"
  echo "read2 (verify re-read):     $h2  ($s2 B)"
  echo "read3 (tie-break):          $h3  ($s3 B)"
} > "$out"

[ "$s1" -eq "$expected_size" ] && [ "$s2" -eq "$expected_size" ] && [ "$s3" -eq "$expected_size" ] \
  || log "WARNING: at least one super read is not full-size — treat verdict with care"

rc=0
if [ "$h3" = "$h1" ] && [ "$h1" != "$h2" ]; then
  echo 'verdict: GLITCH IN READ #2 — reads 1+3 agree; backup good; super VERIFIED' >> "$out"
  log "verdict: read#2 glitch — backup good, super verified (1+3 agree)"
elif [ "$h3" = "$h2" ] && [ "$h1" != "$h2" ]; then
  echo 'verdict: GLITCH IN READ #1 — reads 2+3 agree; backup good; super.bin replaced with the agreeing copy; manifest updated' >> "$out"
  cp -v "$R3/super.bin" "$DIR/super.bin" >> "$out" 2>&1
  newh="$(sha256sum "$DIR/super.bin" | cut -d' ' -f1)"
  [ "$newh" = "$h3" ] || die "replacement super.bin hash mismatch after copy"
  sed -i "s/^$h1  super.bin\$/$newh  super.bin/" "$DIR/MANIFEST.sha256"
  grep -q "^$newh  super.bin$" "$DIR/MANIFEST.sha256" || die "manifest super.bin line update failed"
  log "verdict: read#1 glitch — super.bin replaced, manifest updated to $newh"
elif [ "$h1" = "$h2" ] && [ "$h1" = "$h3" ]; then
  echo 'verdict: ALL THREE AGREE — super verified outright' >> "$out"
  log "verdict: all three reads agree — super verified"
else
  echo 'verdict: SUPER UNVERIFIED — reads disagree with no majority; read#1 file kept; WARN-level (super restore carries risk; init_boot flashing unaffected)' >> "$out"
  log "verdict: SUPER UNVERIFIED — warn-level, backup otherwise stands"
  rc=2
fi

cat "$out"
exit "$rc"
