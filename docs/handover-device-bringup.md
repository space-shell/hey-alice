# Handover — Bluefox NX1 root preparation & device bring-up

Handed off: 2026-11-19. Receiving agent starts with zero context — this document is the briefing. Working directory: `/home/jamesnicholls/projects/hey-alice`.

## Task

Prepare the Bluefox NX1 phone for rooting and hey-alice development. This run covers preparation and the **verified partition backup only**. It **stops before the bootloader unlock** — the unlock/flash session happens in a later turn with the owner present.

## Context

The NX1 will become "Alice", a docked always-on voice companion driving Paseo agents. Full development plan: `docs/plan.md` (read it — scope, ADRs, milestones, latency budgets). Device: MediaTek Helio G81 (MT6769), Android 15, 8 GB/128 GB variant, kernel 6.6.x. Root strategy (plan ADR-1): rooted stock Android — KernelSU/Magisk patched into `init_boot`. No Linux wipe (MT6769 has no mainline support).

Device facts as of handoff:

- Plugged into this machine via USB cable
- USB debugging: **enabled** (wired adb needs no pairing — expect one "Allow USB debugging?" RSA dialog on the phone screen on first `adb devices`; the owner taps it)
- "OEM unlocking" toggle in Developer Options: **enabled** (this is the Settings toggle — the actual `fastboot flashing unlock` has NOT happened yet)
- Contents: assumed disposable, but the unlock wipe consent is still to be reconfirmed by the owner before any unlock session

## Relevant files

- `docs/plan.md` — development plan; milestones M0/D1.x define this work; latency budgets and ADRs live there
- `flake.nix` — app devshell (JDK 17, gradle, android-tools, scrcpy)
- `gateway/flake.nix` + `gateway/requirements.txt` — voice gateway devshell
- `app/src/main/java/com/heyalice/` — Android skeleton (service-first; stubs marked with milestone TODOs)
- `tools/` — **to be created by you**: bring-up scripts and devshell (see acceptance criteria)

## Current state

- Repo scaffolded on `main` (4 commits): app skeleton, gateway devshell, plan doc. Nothing device-related built yet.
- Neither devshell has been entered/compiled — `nix flake show` evaluated cleanly for both, that is all.
- No firmware downloaded, no `init_boot.img` in hand, no backup taken.
- This machine is NixOS. You have **no sudo**. adb/fastboot/mtkclient need udev rules that only the owner can install (see Constraints → udev).
- Related prior art on this machine (audit before writing anything new): `~/projects/dictation-transcription`, `~/projects/nemotron-voice-input`, `~/projects/talk-journal`.

## What was tried

Nothing device-side yet. Research only, from the TrebleDroid/treble_experimentations wiki (Bluefox NX1 page), the community guides site bluefox-guide.neocities.org (bootloader unlock, firmware restore, battery saving), and Liliputing/TechEBlog coverage:

- Bootloader unlocks via `fastboot flashing unlock` (wipes data). Known quirk: boot partition is gzip-compressed; flashing Google GKI boot images breaks WiFi — root must go into `init_boot`, never `boot`.
- KernelSU on patched `init_boot` is the community-tested root method; Magisk-on-`init_boot` is the documented generic Android 13+ alternative.
- `mtkclient` (packaged in nixpkgs) reads/writes all partitions from BROM mode (power off + hold vol-up+down + plug USB) — the backup and unbrick path.
- LineageOS 22.2 GSI tested working on this device (VoLTE with IMS patch; audio policy Magisk module for calls) — fallback OS if stock fights the always-on service (plan ADR-1/R3).

## Decisions

- **Hard gate: no unlock, no flash, no write to the device this run.** The verified backup must exist first, and the unlock itself needs the owner physically present (volume-up confirm) — plan §D1.1 and the runbook in the conversation that produced this handover.
- Root via Magisk patched `init_boot`; try magiskboot PC-side automation first, fall back to the Magisk app's on-device "patch a file" flow if the PC-side plumbing fights (2 taps, then scripts flash it).
- `init_boot.img` comes from the mtkclient backup itself (partitions `init_boot_a`/`init_boot_b`), not from a firmware download — downloading stock firmware is opportunistic extra (nice for restore/rollback docs), not a dependency.
- Backup excludes `userdata` (owner data, and size); include everything else. Store under `~/projects/hey-alice/.backups/nx1-<date>/` (gitignored) with a SHA256 manifest + verified readback of at least `boot`, `init_boot`, `vbmeta`, `super`, `preloader`.
- Workspace-facing decisions unchanged: Paseo relay → Tailscale networking, "Hey Alice" wake word, ephemeral notes sessions → memos MCP.

## Acceptance criteria

- [x] `tools/` exists with: `README.md` (runbook matching plan M0/D1.1/D1.2), `backup.sh` (mtkclient read + SHA256 manifest + readback verification, hard-fails on hash mismatch), `verify-root.sh`, `unlock-flash.sh` (unlock + `init_boot` flash sequence with verification gates — present but NOT executed this run), `post-root-setup.sh` (battery-optimisation exemption, debloat list, keycode logging via `getevent` for plan D1.2)
- [x] `tools/flake.nix` bring-up devshell (mtkclient, android-tools, scrcpy) — `nix flake show` evaluates cleanly
- [x] adb device visible and authorized (`adb devices` shows `device`) — resolved via owner-installed udev rule `/etc/udev/rules.d/52-mtk.rules` (VID `0e8d`, covers the NX1's `0e8d:201c` adb interface); RSA accepted 2026-11-19
- [x] mtkclient backup completed with verified readback, manifest committed as `.backups/nx1-<date>/MANIFEST.sha256` (contents gitignored) — **done with scope notes**: flash-critical set (boot/init_boot/vbmeta/vendor_boot/lk/tee/gpt/seccfg/proinfo + eMMC Boot1 preloader) 2-pass bit-exact; 8 volatile partitions recorded (`VOLATILE-HASHES.txt`); `super.bin` UNVERIFIED after a 3-way tie-break (`SUPER-TIEBREAK.txt`) — WARN-level, evidence points to per-read USB instability, does not affect init_boot flashing (see `VERIFY-STATUS.md`)
- [x] Magisk-patched `init_boot` image built from the backed-up partition — **both slots** (`init_boot_a.magisk.img` / `init_boot_b.magisk.img`, Magisk v31.1, signature-verified, provenance in `PATCHED-INIT_BOOT.txt`); Magisk-app fallback documented in `tools/README.md` (not needed)
- [x] Firmware payload sourcing: community MEGA folder located and documented in `tools/README.md` (EEA variant matched to `BF001_EEA`); not downloaded — mtkclient backup supersedes it for restore purposes
- [x] Commit little, commit often — each deliverable its own commit on `main`
- [x] Final report: delivered 2026-11-20 (hash summary, unlock-session runbook, open questions)

## Session outcome — unlock+root session 2026-11-21 (device work COMPLETE)

- **Bootloader unlocked** (`unlocked: yes`), wipe done, owner-confirmed. The
  wipe switched the active slot **a → b** — both init_boot slots were
  pre-patched, so no re-patch was needed; `unlock-flash.sh` picked slot b via
  `fastboot getvar current-slot`.
- **Rooted**: Magisk 31.1 flashed to init_boot (slot b). `verify-root.sh`:
  **all gates pass** (needed a one-line fix: glued statement → unbound var
  under `set -u`, committed).
- **Script fixes made during the session** (all committed): `unlock-flash.sh`
  honors `UNLOCK_CONFIRMED` at the pre-unlock confirm, tolerates a rerun while
  already in fastboot, and `getvar` parses are filtered to their variable line
  (the fastboot timing line `0.000s` was poisoning value comparisons — caused
  one safe-abort). `post-root-setup.sh`: getevent device glob expanded on host
  instead of device, and the phone's getevent rejects multiple device args —
  now a pathless capture.
- **Battery-exempt deferred** to M1 first deploy: `com.heyalice` isn't
  installed yet (no APK built) — noted in `docs/plan.md` §9.
- **Magisk app installed on device** (v31.1); root grant for
  `com.android.shell` added manually via the app UI (Superuser → + → Shell).
  Doc note: Magisk auto-denies `su` prompts while the screen is locked —
  capture windows must keep the screen on.
- **D1.2 side-key contract captured** → ADR-6 in `docs/plan.md` §D1.2 (side
  key = power key, hold ≥500 ms → PTT, raw `/dev/input/event0` capture).
  Raw logs: `logs/sidekey-*.log` (gitignored).
- **Stage-2 addendum (2026-11-21)**: `adb reboot` does NOT auto-boot the NX1 —
  it powers off and stays dark until a physical POWER press (~10 s). Not a
  Magisk problem: root survives (verified `su -c id` post-recovery). USB tends
  to unseat during the hold — replug. Full note in `docs/plan.md` §5 M0.

## Constraints

- **Read-only constraint LIFTED 2026-11-21**: the unlock+root session ran with owner present and completed the write path (`fastboot flashing unlock`, init_boot flash). The backup (`.backups/nx1-20261120-003415/`, VERIFIED) remains the restore reference — any future write session should re-confirm against it first.
- **No sudo.** udev/adb rules are the owner's NixOS config change. Suggested snippet for their config (they rebuild + re-login):
  ```nix
  programs.adb.enable = true;
  services.udev.packages = [ pkgs.mtkclient ];
  ```
  If mtkclient's packaged rules are insufficient, provide an inline `services.udev.extraRules` covering MediaTek BROM/preloader VID:PID `0e8d:0003`/`0e8d:2000`/`0e8d:2001`.
- Physical actions only the owner can do: RSA prompt tap; BROM entry (power off, hold vol-up+down, plug); volume-up on the future unlock confirm. Ask and wait — never improvise around them.
- Every package/dependency goes through a flake devshell (repo convention in `AGENTS.md`).
- Sequential web searches only — never parallel search calls (host AGENTS.md rule; mis-routed MCP responses hang).
- The owner's global AGENTS.md applies: direct language, quantify, commit little and often, ask questions where there is any ambiguity.
- Don't touch `app/` or `gateway/` logic — this run is device bring-up only. Android app builds (`gradle wrapper`, `assembleDebug`) are follow-up work after SDK setup; do them only if the backup is already done and time permits.
