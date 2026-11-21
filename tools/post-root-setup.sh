#!/usr/bin/env bash
# post-root-setup.sh — NX1 tuning after a successful root (plan D1.2/D1.7 prep).
#
#   battery-exempt   whitelist com.heyalice from doze/background kills (D1.7)
#   debloat          remove the listed packages for user 0 (stock NX1 ships
#                    near-zero bloat — list starts empty; extend as found)
#   sidekey-log [s]  capture side-key InputEvents via getevent for N seconds
#                    into logs/sidekey-<ts>.log (D1.2 keycode contract)
#   all              battery-exempt + debloat (never sidekey-log)
#
# Usage: nix develop -c ../tools/post-root-setup.sh <command> [args]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS="$REPO_ROOT/logs"

ALICE_PKG="com.heyalice"
# Nothing on the stock NX1 today; candidate pattern if bloat appears:
# e.g. DEBLOAT=(com.google.android.googlequicksearchbox com.android.chrome)
DEBLOAT=()

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "[post-root] $*"; }
# Target discipline: another Android device on this network auto-connects to
# adb via mDNS/TCP. NEVER issue adb commands without -s <NX1 serial>.
NX1_SERIAL="${NX1_SERIAL:-TLF2601S000307}"
adb() { command adb -s "$NX1_SERIAL" "$@"; }
command -v adb >/dev/null || die "run inside tools devshell: nix develop -c bash $0 $*"
adb get-state >/dev/null 2>&1 || adb wait-for-device

battery_exempt() {
  log "whitelisting $ALICE_PKG from battery optimisation"
  adb shell dumpsys deviceidle whitelist +"$ALICE_PKG"
  # appops belt-and-suspenders: allow run-anywhere even outside doze whitelist
  adb shell appops set "$ALICE_PKG" RUN_ANY_IN_BACKGROUND ignore 2>/dev/null \
    || log "appops RUN_ANY_IN_BACKGROUND not settable yet (package not installed?)"
  adb shell su -c "dumpsys deviceidle whitelist" | grep -q "$ALICE_PKG" \
    && log "verified: $ALICE_PKG in deviceidle whitelist" \
    || log "WARNING: $ALICE_PKG not visible in whitelist (install the app first, then rerun)"
}

debloat() {
  if [ "${#DEBLOAT[@]}" -eq 0 ]; then
    log "debloat list empty — stock NX1; nothing to remove. Edit DEBLOAT=() in this script if bloat appears."
    return 0
  fi
  for pkg in "${DEBLOAT[@]}"; do
    log "removing (user 0): $pkg"
    adb shell pm uninstall -k --user 0 "$pkg" || log "skip $pkg (not present?)"
  done
}

sidekey_log() {
  secs="${1:-30}"
  mkdir -p "$LOGS"
  logfile="$LOGS/sidekey-$(date +%Y%m%d-%H%M%S).log"
  echo "------------------------------------------------------------------"
  echo "OWNER ACTION REQUIRED (${secs}s): press the side key in this pattern,"
  echo "about 2 s apart:  short · long-hold · double-press"
  echo "------------------------------------------------------------------"
  log "capturing getevent -lt for ${secs}s → $logfile"
  timeout "$secs" adb shell "getevent -lt" | tee "$logfile" || true
  log "events captured: $(grep -c EV_ "$logfile" || true)"
  log "key lines (non-touch):"
  grep -E "KEY_|BTN_" "$logfile" | grep -v BTN_TOUCH | sort | uniq -c | sort -rn | head -20 || true
  log "Send this filtered block back for the D1.2 keycode contract."
}

case "${1:-}" in
  battery-exempt) battery_exempt ;;
  debloat) debloat ;;
  sidekey-log) sidekey_log "${2:-30}" ;;
  all) battery_exempt; debloat ;;
  *) grep '^#' "$0" | sed -n '2,14p'; exit 2 ;;
esac
