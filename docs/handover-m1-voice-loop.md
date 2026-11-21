# Handover — Stage 2: M1 voice-loop skeleton + D1.3 AEC spike

Handed off: 2026-11-21. Receiving agent starts with zero context. Working directory: `/home/jamesnicholls/projects/hey-alice`.
Read `docs/plan.md` first — it is the source of truth for scope, ADRs, latency budgets, and milestones. This document covers only the stage-2 delta.

## Task

Build and demonstrate the **M1 voice-loop skeleton** (plan §5 M1) and produce the **D1.3 AEC verdict** (plan D1.3): press-and-hold the side key on the NX1 → audio streams to a server gateway → faster-whisper transcribes → Kokoro speaks a reply back through the phone speaker — measured against the latency budget in plan §4. Plus the one open device issue below.

## ⚠️ OPEN DEVICE ISSUE — resolve this FIRST

At handoff, the NX1 is **unresponsive**: after an ordinary `adb reboot` (issued 2026-11-21 ~08:50), it never re-appeared on USB — no adb, no fastboot, no BROM enumeration for 15+ minutes. Context: the device had booted fine post-flash twice before (once only after a manual power-cycle; the first boot also appeared hung past a 300 s timeout but completed later). So the likely pattern is **benign**: `adb reboot` leaves the device powered-off/idle and it needs a physical POWER press (~10 s) to boot, OR it boots very slowly on a fresh wipe.

Resolution order (with the owner, who is co-located):
1. Owner: hold **POWER ~10 s**. If it boots → verify `adb devices`, `sys.boot_completed`, `su -c id` → continue the stage.
2. If POWER does nothing and the screen stays black through a 2-min wait → real hang/bootloop: BROM entry (unplug → power off → hold Vol+Vol− → plug) and **restore stock init_boot**: `mtk w init_boot_b .backups/nx1-20261120-003415/init_boot_b.bin` (root gone, phone alive — the image is 2-pass verified). Then root differently: **KernelSU on init_boot** is the community-verified method for this device (TrebleDroid wiki) — the Magisk patch is suspect in the reboot-hang scenario.
3. Record the outcome in `docs/plan.md` §D1.1/§M0 notes and this file's Current state — a root installation that cannot survive `adb reboot` is a stage-2 blocker, not a footnote.

## Relevant files

- `docs/plan.md` — plan: ADR-6 (accepted hold-to-talk contract), §4 protocol + latency budget, §5 M1
- `app/` — Android skeleton: `AliceService.kt` (foreground service), `audio/AudioEngine.kt` (stub with AEC TODOs), `voice/VoiceSessionState.kt` (state machine), `paseo/PaseoConnection.kt` (stub), `MainActivity.kt` (status UI)
- `gateway/` — flake.nix devshell + requirements.txt (faster-whisper, kokoro, websockets); implementation is yours
- `tools/` — unlock-flash.sh, verify-root.sh, post-root-setup.sh (battery-exempt, sidekey-log), super-tiebreak.sh, patch-init-boot.sh, setup-sdk.sh
- `.backups/nx1-20261120-003415/` — verified backup + `init_boot_{a,b}.magisk.img` + stock images + `PATCHED-INIT_BOOT.txt`
- Audit before writing new audio code: `~/projects/dictation-transcription`, `~/projects/nemotron-voice-input`, `~/projects/talk-journal` (owner's prior STT/audio projects)

## Current state

- **RESOLVED 2026-11-21 ~09:30**: the dark device was the benign case — after
  `adb reboot` the NX1 does not auto-boot; it needs a physical POWER press
  (~10 s). Owner pressed; device booted; root intact (`su -c id` →
  `uid=0(root) … u:r:magisk:s0`). Project rule: after any reboot the owner
  powers the device on, and expect to replug USB (it comes loose during the
  hold). Quirk recorded in `docs/plan.md` §5 M0 and `.backups/…/VERIFY-STATUS.md`.
- **Device**: rooted NX1 (Magisk 31.1, 8/8 verify gates passed), bootloader unlocked, serial `TLF2601S000307`, Android 15, slot `b`, `com.android.shell` has a Magisk superuser grant (su works over adb), Alice skeleton APK installed, Magisk app installed (battery-exempt still deferred to this stage).
- **Build pipeline**: SDK at `~/Android/Sdk` (platform 35, build-tools 34/35), gradle wrapper committed, `./gradlew :app:assembleDebug` works (~90 s incremental) — run from repo root in the ROOT flake devshell (`nix develop -c ...`), NOT from tools/ (that's the bring-up flake: no java).
- **Commits**: main has stage-1 history (14+ commits) + docs closure (ADR-6 accepted: hold-to-talk = raw `/dev/input/event0` + ≥500 ms hold detection via su + root-installed RRO disabling framework power-menu; side key IS the power key, `KEY_POWER` on `mtk-pmic-keys`).
- **Known device quirks** (all documented in VERIFY-STATUS.md + stage-1 report): Magisk auto-denies su prompts while the screen is locked — keep screen on (`svc power stayon usb`) during capture windows; the phone's `getevent` rejects multiple device args; flaky USB link historically (super.bin read instability) — prefer wired stability and keep sessions short.
- **Gateway**: nothing implemented. requirements.txt is unpinned by intent — pin at M1.
- **Wallet note**: the D1.3 AEC test must run through the app's real audio path (`AudioRecord` with `VOICE_COMMUNICATION` + simultaneous `AudioTrack`), not root tinycap/tinyplay — Android's AEC lives in the framework audio path, which is exactly what we're validating.

## What was tried

- Full stage-1 bring-up succeeded end-to-end (verified backup incl. 3-way super tie-break; unlock; Magisk root; 8/8 verify gates; D1.2 keycode contract; SDK + first build + deploy). History in `docs/handover-device-bringup.md`, `VERIFY-STATUS.md`, and the git log.
- Reboot reliability: post-flash boot #1 exceeded a 300 s wait then completed after a manual power-cycle; later `adb reboot` (stage-2 handoff moment) left the device dark on USB ≥15 min — unresolved at handoff, resolution order above.
- 546 handshake failures taught us: mtkclient must only see the phone in genuine BROM (`0e8d:0003`) — backup.sh enforces this with a detach-guard; keep that discipline for any future mtk use.

## Decisions (standing, from plan ADRs + owner sign-off)

- ADR-6 (accepted 2026-11-21): hold ≥500 ms on side key → PTT; service reads `/dev/input/event0` raw via su; root-installed RRO sets `config_longPressOnPowerBehavior=0`; short press unchanged; double press reserved. Owner accepted losing the power menu.
- Speech backend: cascade (faster-whisper + Kokoro) is the M1 default; z.ai realtime/Paseo-pipeline swap is gated on the D1.4/D1.5 audits (later milestones — not this stage).
- Transport: PCM 16 kHz mono, 20 ms frames on WiFi (Opus deferred to M5).
- Deterministic grammar for intents; no LLM router in v1 (M3 concern — not this stage).

## Acceptance criteria

- [ ] Device issue resolved + documented: root survives `adb reboot` (test twice), OR rollback+KernelSU re-root done and documented with the same reboot test
- [ ] Gateway: one WebSocket endpoint; client streams 20 ms PCM frames; server runs faster-whisper streaming partials + Kokoro TTS chunks; sequences numbered; runs under `gateway/` devshell with pinned requirements
- [ ] App: `AudioEngine` implemented (full-duplex AudioRecord + AudioTrack, `VOICE_COMMUNICATION` source, AEC availability check), PTT: hold side key ≥500 ms (raw event0 via su per ADR-6) starts capture, release stops and sends
- [ ] D1.3 verdict with numbers: play TTS through speaker while capturing — measure residual echo in capture (energy/spectral check vs baseline); verdict AEC-good / AEC-weak / AEC-absent recorded in `docs/plan.md` D1.3
- [ ] End-to-end demo: hold key → speak → release → transcript on screen → spoken reply audible, first-reply latency logged vs plan §4 budget (ack < 1.5 s LAN target; record actual)
- [ ] `post-root-setup.sh battery-exempt` re-run after app install (it was deferred — package now exists)
- [ ] Commits little and often; final response = stage report (latency numbers, AEC verdict, deviations)

## Constraints

- No bootloader re-lock, no flashing except `adb install` of our own APK, no mtkclient writes except the documented init_boot restore path if (and only if) the device needs rescue
- Root grant for `com.android.shell` exists; keep it (don't revoke in the app UI)
- Sequential web searches only (never parallel — mis-routes and hangs, host AGENTS.md rule)
- All dependency management via flake devshells; pin gateway requirements at M1
- Owner is co-located and hands-on — ask at physical gates (button holds, screen taps), never improvise around them
- The repo `AGENTS.md` conventions apply: commit little/often, direct language, quantified claims
