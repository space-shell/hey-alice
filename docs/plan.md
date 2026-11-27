# NX1 Voice Companion — Double Diamond Development Plan

> Target device: Bluefox NX1 (MediaTek Helio G81 / MT6769, Android 15, 4.0" 540×1168,
> 3000 mAh, 4G LTE/VoLTE, customizable side key).
> Vision: a docked, always-on Alexa-style voice companion — **Alice** (named for
> Alice & Bob) — that drives Paseo agents: wake word + hold-to-talk, full-duplex audio
> with on-device VAD and barge-in, working over 4G away from home WiFi.

Status: plan v1, requirements settled with owner 2026-11-19.

---

## 1. Settled requirements

| Area | Decision |
| --- | --- |
| OS | Rooted Android (KernelSU or Magisk on `init_boot`). No Linux wipe. |
| Assistant identity | **Alice** (Alice & Bob). Wake word: **"Hey Alice"**. |
| Triggers | Wake word (hands-free) **and** side-button hold-to-talk, both from day one. |
| v1 capabilities | Drive Paseo agents: status queries, send prompts, create/archive sessions. |
| Notes | Speech → new ephemeral Paseo session per note; that session's agent files the note into memos via the memos MCP, then the session is archived. No separate notes store. |
| Audio model | Full-duplex: simultaneous mic-in + TTS-out, on-device VAD, barge-in of TTS by voice. |
| Speech pipeline | Primary: Paseo's integrated speech pipeline (if enableable). Explore z.ai realtime/full-duplex speech models. Fallback: faster-whisper + Kokoro cascade behind one gateway. |
| Networking | Paseo relay (E2EE) first, Tailscale/WireGuard second. |
| Power | Docked, plugged in, always-on primarily. Pocketable profile is a later milestone. |
| Screen | Minimal dark status UI: listening/running/done states, live transcript, attention dots. |
| 4G | Must remain functional (SIM data + VoLTE) for away-from-WiFi use. |

### Assumptions (verify in Discover)

- A1: ~~Device variant~~ **Resolved** — 8 GB / 128 GB variant confirmed by owner.
- A2: Paseo's integrated speech pipeline exposes something addressable (endpoint, protocol, auth). Unverified.
- A3: z.ai subscription includes a realtime/voice API (GLM voice/realtime family) usable server-side. Unverified — spike with kill criteria.
- A4: ~~Side key emits standard Android key events capturable by a foreground app or remappable with root~~ **Resolved 2026-11-21** — side key IS the power key (`/dev/input/event0`, KEY_POWER); raw-event capture works with root (ADR-6).
- A5: NX1's `VOICE_COMMUNICATION` audio source provides working AEC — required for barge-in without the device hearing its own TTS. Unverified.

### Non-goals for v1

- Pocketable battery optimisation (designed for, built later).
- General chat-only mode not tied to agents.
- Camera, apps card, wizard UI, multi-wake-phrase support.
- Voice-actuated permission approve/deny (v1 announces the gate on-screen and by voice; acting on it is a stretch goal).
- Notes retrieval by voice ("what did I note about X" → ephemeral memos query session) — v1.1 stretch goal.

---

## 2. Research findings (2026-11-19)

- SoC MT6769 has **no mainline Linux support** → wiping to Linux loses 4G, audio, charging. Rooted Android chosen; Linux path closed.
- Bootloader unlocks via `fastboot flashing unlock` (wipes data). Root: KernelSU patch of `init_boot` (per TrebleDroid wiki) or Magisk.
- **Unrooting is cleanly reversible**: full partition backup via `mtkclient` from BROM mode before any modification; restore stock `boot`/`init_boot` (or whole firmware via SP Flash Tool/mtkclient) then relock. No Knox-style permanent fuse on MTK.
- LineageOS 22.2 GSI tested working on NX1: mobile data ✅, VoLTE ✅ (needs MTK IMS APK + two phh Treble settings toggles), WiFi ✅, speaker/mic ✅ (audio policy patch needed for calls — available as a Magisk module). DerpFest A16 exists.
- Known GSI caveats: portable-eSIM writing not functional on tested GSI (physical SIM unaffected); boot partition is gzip-compressed — Google GKI boot images break WiFi, so root goes in `init_boot`, not `boot`.
- Community guides: bluefox-guide.neocities.org (bootloader unlock, firmware restore, battery saving).
- Stock Android 15 ships with no bloatware per vendor — debloating may be minimal work.

---

## 3. DIAMOND 1 — Discover

Goal: convert every assumption (A1–A5) into a measured fact or a closed decision.
Each item is a spike with a concrete output. No production code in this phase.

### D1.1 — Safety net + root (do first, everything depends on it)
- `mtkclient`: read **all** partitions except userdata; store with SHA256 manifest; verify readback round-trip.
- Unlock bootloader, root via KernelSU on `init_boot` (fallback: Magisk patch).
- Document the unroot procedure end-to-end and rehearse the restore of one benign partition.
- **Output**: `docs/device/backup-manifest.md`, verified root, rehearsed rollback.
- **Gate**: if KernelSU and Magisk both fail → stop, reassess (fallback exists via mtkclient, but treat as blocker).

### D1.2 — Side key interrogation — **RESOLVED 2026-11-21 (rooted device)**

Measured facts (34 captured presses, `tools/post-root-setup.sh sidekey-log`):

- The NX1 side key **IS the power key**: input device `/dev/input/event0`
  (`mtk-pmic-keys`), emits `KEY_POWER` (0x0074) DOWN/UP; second keycode 0x00f0
  (240) present but unused in practice. 34/34 presses were KEY_POWER.
- There is **no separate shortcut keycode**. The OEM "customizable shortcut"
  (`secure setting double_side_key=1`) is software layering on power-press
  patterns, not a distinct key.
- Raw capture works with root: `getevent -lt /dev/input/event0` through `su`;
  the companion service can read `event0` directly. Magisk auto-denies `su`
  prompts while the screen is locked — capture windows must keep the screen on.

**ADR-6 — Side-key / hold-to-talk contract** — **Status: Accepted (owner sign-off, 2026-11-21)**. Owner explicitly confirmed losing the power-menu long-press is acceptable ("device can be powered down in other ways"). This closes the last open decision blocking M1's audio-engine design: the hold-to-talk input path is fixed — raw `/dev/input/event0` + duration detection via `su`, no framework interference.

- **Hold ≥ 500 ms** on the side key → **PTT talk**. Implementation: companion
  foreground service reads `/dev/input/event0` raw events (root), measures
  DOWN→UP duration; a root-installed Runtime Resource Overlay sets framework
  `config_longPressOnPowerBehavior=0` so the power menu never competes.
- **Short press** → unchanged framework screen toggle (useful when docked).
- **Double press** (two DOWNs within 400 ms) → reserved for an Alice
  quick-action (decide later, not v1).
- Rejected for now: OEM `double_side_key` repoint (double-press → app launch;
  fights our own double-press semantics, adds a Settings dependency), and
  volume-key remap (loses hardware volume while away from dock; D1.2's old
  fallback is unnecessary — raw capture is confirmed working).
- Raw capture logs from the session: `logs/sidekey-*.log` (gitignored; the
  contract above is the durable record).

### D1.3 — Audio path + AEC validation (biggest technical risk)
- Record from mic while playing TTS to speaker on the NX1.
- Compare `VOICE_COMMUNICATION` vs `UNPROCESSED` vs `MIC` sources; check `AcousticEchoCanceler.isAvailable()` and measure real echo suppression.
- Confirm sample formats: target 16 kHz mono 16-bit, 20 ms frames.
- **Output**: audio source decision, measured AEC quality, full-duplex go/no-go for barge-in.
- **Fallback if AEC is unusable**: half-duplex with TTS ducking during capture (graceful degradation; barge-in becomes "press PTT to interrupt").

### D1.4 — Paseo speech pipeline audit — **RESOLVED 2026-11-27 (review §1 F2)**
- ~~Inventory what Paseo's integrated speech pipeline exposes: endpoints, auth, streaming vs batch, codecs, language support.~~
- **Output (evidence, Paseo v0.15.3)**: audio is base64 inside JSON; TTS is sent one whole segment at a time (≤260 chars), so first audio waits for the full segment; TTS exists only as an agent's `speak` tool, with no client-callable synthesis; voice mode sends transcripts to an agent — the opposite of the deterministic grammar. **Conclusion: the cascade (faster-whisper + Kokoro behind the gateway) is the v1 backend; the Paseo option is closed.**

### D1.5 — z.ai realtime speech model spike
- Enumerate realtime / voice / multimodal streaming APIs available on the z.ai subscription (websocket audio-in/out, server VAD, barge-in semantics, cost/minute).
- Benchmark: time-to-first-audio, interruption behaviour, transcription quality, vs the cascade baseline.
- **Output**: go/no-go decision with numbers.
- **Kill criteria**: TTFB worse than cascade total budget (§4), no interruption control, or cost prohibitive for always-on use → cascade wins.

### D1.6 — Wake word engine evaluation
- Candidates: openWakeWord (ONNX, custom phrase via synthetic TTS — preferred), microWakeWord, Porcupine (license).
- Train **"Hey Alice"**; measure: CPU load per second on A55 cores, false accepts per 24 h in room noise, miss rate at 3 m.
- **Output**: engine + phrase + measured battery cost while docked.

### D1.7 — Power characterisation (docked)
- Measure drain and thermals with: wake word armed + screen dimmed + WiFi; same on 4G idle.
- Verify Android battery optimizations can be permanently exempted for the foreground service (root: `pm` exemption / Magisk module).
- **Output**: duty-cycle spec for docked profile; inputs for pocketable profile design.

**Discover exit**: A1–A5 all resolved; audio model, wake engine, speech backend decided with numbers.

---

## 4. DIAMOND 1 — Define

### Architecture

```
┌─────────────── NX1 (rooted Android) ───────────────┐      ┌──────────── server ────────────┐
│  Companion app (Kotlin, single APK)                │      │  Paseo daemon(s)               │
│  ├─ Foreground service (never killed, docked)      │      │  ├─ agents (opencode/GLM/z.ai) │
│  ├─ Audio engine: AudioRecord ⇄ AudioTrack         │      │  └─ speech pipeline / gateway  │
│  │    AEC source, 20 ms frames                     │ E2EE │     faster-whisper │ Kokoro    │
│  ├─ Wake word (openWakeWord ONNX, A55)             ├──────┤    or z.ai realtime proxy      │
│  ├─ VAD (Silero ONNX): endpointing + barge-in gate │ relay│                                │
│  ├─ Voice session state machine (§ state model)    │  or  │  (gateway gets its own         │
│  ├─ Paseo connection layer (adapted from           │Tails-│   flake.nix devshell)          │
│  │    illegal-lion: direct WS + relay E2EE;        │ cale │                                │
│  │    multi-daemon remerge deferred)               │      │                                │
│  └─ Minimal Compose status UI (dark, glanceable)   │      │                                │
└────────────────────────────────────────────────────┘      └────────────────────────────────┘
```

Key decisions to record as ADRs:
- **ADR-1 Host OS**: rooted stock Android 15 first; LineageOS GSI only if stock fights the always-on service or we need cleaner key handling. — **rooted stock confirmed 2026-11-21** (bootloader unlocked, Magisk 31.1 on init_boot).
- **ADR-2 Speech backend**: decided by D1.4/D1.5 numbers (Paseo pipeline vs z.ai realtime vs whisper+Kokoro cascade). The gateway interface is designed so backends are swappable behind one protocol.
- **ADR-3 Code layout**: **standalone new repo** for the Alice app — repo `hey-alice` at `~/projects/hey-alice`. `xagent` (illegal-lion) stays a UI-first launcher; Alice is service-first — foreground service, audio engine, wake word, with a minimal status UI, not a card deck. Port the proven Paseo connection architecture (direct WS + relay E2EE, reconnect, agent-state model) into the new repo as adapted code, not shared Gradle modules — avoid coupling a headless assistant to the launcher's release cycle. Extract a shared connection library later only if divergence cost proves out. Alice connects to a single daemon connection in v1; multi-daemon remerge is launcher-specific and deferred.
- **ADR-4 Transport codec**: PCM 16 kHz mono on WiFi; Opus 16–24 kbps before 4G field trials (radio-on-time matters on battery).
- **ADR-5 Security**: device stores daemon bearer credentials in Android Keystore; full-disk encryption on; relay E2EE as first link, Tailscale second; gateway refuses unauthenticated streams. — **Amendment 2026-11-27 (review §6c)**: the app is root-equivalent (it execs `su` for ADR-6 PTT); anything it loads at runtime runs with that grant reachable. All models (ONNX VAD, wake word) are therefore bundled in the APK — no runtime fetch over an unauthenticated channel.
- **ADR-6 Side key / hold-to-talk** — **Status: Accepted (owner sign-off, 2026-11-21)**: side key = power key (`/dev/input/event0`, KEY_POWER); hold ≥ 500 ms → PTT via raw-event capture + RRO disabling power-menu long-press (owner approved losing the power menu); double press reserved. See §D1.2. — **Deployed and verified on-device 2026-11-27** (static RRO via Magisk module v1.2; `mLongPressOnPowerBehavior=LONG_PRESS_POWER_NOTHING`; short press still toggles screen).
- **ADR-7 Voice transport off the LAN** — **Status: Accepted (owner decision, 2026-11-27, revisitable)**: **Tailscale carries the voice gateway.** The NX1 joins the owner's tailnet and points at the server's tailscale IP; WireGuard then covers the voice leg off-LAN. Rationale: the Paseo relay carries only the daemon's own protocol, so "relay first" cannot apply to voice without the unproven daemon-plugin carrier (review §1 F1). The relay remains first for the **agent RPC leg** (M3). Revisit trigger: if Tailscale proves operationally annoying (login/holes-on-4G) or a real off-LAN requirement appears that Tailscale can't meet, the daemon-plugin carrier may be re-opened after a time-boxed spike of 50 msg/s relay throughput (tracker D4, skipped while this ADR stands). Coverage note (review §6b): relay E2EE protects the RPC leg only; this ADR is what covers the voice leg.
- **ADR-8 Intent orchestration lives in the app** — **Status: Accepted (owner delegated to review recommendation, 2026-11-27)**: the M3 deterministic grammar (no LLM router) runs in the Android app, not the gateway. The app knows agent/session state, can speak optimistic acks immediately ("sent to X"), and the gateway stays a pure STT/TTS pipe. Includes a defined speech-queue policy (what happens when a spoken result arrives while TTS is already talking).

### Voice session protocol (one bidirectional WebSocket per session)

Client → server: framed audio (20 ms), VAD events (`speech_start`, `speech_end`), barge-in signal, PTT state.
Server → client: partial + final transcripts, intent acks, agent state events, TTS audio chunks with sequence numbers, error events.
VAD placement: on-device Silero does barge-in gating + client-side endpointing assist; server re-verifies endpoints (single source of truth = server).

### State machine

```
IDLE ──wake/PTT──▶ CAPTURING ──endpoint──▶ TRANSCRIBING ──▶ ROUTING ──▶ RESPONDING ──▶ IDLE
  ▲                   │ no-speech 5s          (streaming     (Paseo RPC)   (TTS streams;
  └───────────────────┘                       partials)                    agent events async)
                         RESPONDING ──voice barge-in──▶ INTERRUPTED ──▶ CAPTURING
                         any state ──error──▶ spoken error ──▶ IDLE
```

### Latency budget (cascade baseline; realtime model must beat it to win)

| Segment | Budget |
| --- | --- |
| PTT release → final transcript | < 500 ms |
| Transcript → intent ack TTS start | < 300 ms |
| Wake/PTT → first spoken ack, end-to-end | < 1.5 s (LAN), < 2.0 s (relay/4G) |
| Agent status query → spoken answer | < 3 s |
| Wake word false accepts | < 1 per 24 h |
| Prompt send → agent ack spoken ("sent to X") | < 1 s |

**Define exit**: ADRs signed off, protocol doc written, repo layout chosen, milestones costed.

---

## 5. DIAMOND 2 — Develop (milestones, each with exit criteria)

### M0 — Device ready (≈1 day)
Backup, unlock, root, battery-optimisation exemption, ADB-over-WiFi.
**Exit**: D1.1 complete; device survives reboot loop test and rollback rehearsal.

**Device quirk (found 2026-11-21, stage 2): `adb reboot` does NOT auto-boot the
NX1.** The device powers off and stays dark (no USB enumeration in any mode)
until someone physically presses POWER ~10 s. Not a Magisk/bootloop problem —
root survives the reboot fine once booted. Project rule: after any reboot, ask
the owner to power-press; also expect the USB cable to come loose during the
hold — replug before adb will see the device. Reboot-survival evidence:
2026-11-21 ~08:50 `adb reboot` → dark ~40 min → owner POWER press →
`su -c id` = `uid=0(root) … context=u:r:magisk:s0`. Second deliberate test
pending (M1 checklist).

### M1 — Voice loop skeleton (the riskiest integration first; ≈1 week)
New `alice` repo: service-first Android app skeleton. Throwaway UI: PTT (side key or on-screen) → AudioRecord → WS → server STT → TTS → AudioTrack.
Server: minimal gateway (Python, flake.nix devshell) with faster-whisper + Kokoro, PCM in/out. Before building the gateway from scratch, audit existing owner projects for reusable pieces: `dictation-transcription`, `nemotron-voice-input`, `talk-journal` (all in `~/projects`).
**Exit**: round trip works on LAN; measured segment latencies within 2× budget; AEC verdict recorded (D1.3).

### M2 — Gateway hardening (≈1 week)
VAD endpointing (Silero server-side), streaming partials, barge-in semantics, sequence-numbered TTS, reconnect/resume, Opus option.
**Exit**: barge-in demo: user speaks over TTS, TTS stops < 300 ms, new utterance captured cleanly. 30-min soak, no leaked buffers.

### M3 — Paseo agent wiring (≈1–2 weeks)
Adapt the connection layer ported from illegal-lion (ADR-3): daemon connect over relay + Tailscale, agent list, prompt send, status subscribe.
Intent routing (deterministic grammar first, no LLM router in v1):
- "note: …" → create ephemeral notes session (named `alice-note-<ts>`), agent files the note into memos via the memos MCP, session archived on completion, spoken "Noted."
- "status / what's X doing" → status subscribe → spoken summary
- "tell X to …" / "ask X to …" → prompt send → spoken ack
- "new session on Y" → create (wizard-free defaults) 
- "archive X" → optimistic archive (launcher semantics)
Notes-session defaults (tweakable): provider/model = owner's GLM default; the notes system prompt mandates the memos tool and one note per session.
**Exit**: all five intents work end-to-end over the ADR-7 transport (voice via Tailscale, agent RPC via relay + Tailscale); spoken acks within budget; attention states shown on status UI.

### M4 — Wake word + always-on docked profile (≈1 week)
openWakeWord always-on, VAD-gated capture window after wake, chime acks, docked power profile (screen dim, WiFi preferred, 4G standby).
**Exit**: D1.6/D1.7 numbers met: <1 false accept/24 h docked, thermals stable over 48 h plugged in.

### M5 — Full-duplex hardening + 4G field trial (≈1 week)
Barge-in under TTS echo (real speaker volume), relay jitter tolerance, 4G day-trip: wake → note → status away from home.
**Exit**: field-trial checklist passes; reconnect over relay/4G transparent; transcripts survive handoff WiFi↔4G.

### M6 — Deliver (≈1 week)
Minimal status UI polish (agent dots, live transcript, error states), set companion as home/launcher-adjacent, install/update path (adb or simple updater), docs: flashing guide, rollback guide, gateway ops guide.
**Exit**: acceptance tests §6 green; owner signs off daily-driver week.

---

## 6. DIAMOND 2 — Deliver (acceptance + field validation)

1. **Latency**: log-segmented measurement of 20 utterances vs budget table (§4).
2. **Wake word**: 24 h docked log; false accepts ≤ 1, misses ≤ 5% at 3 m.
3. **Barge-in**: 10 interruptions mid-TTS at conversational volume; zero self-triggered false interrupts.
4. **Mobility**: 4G-only session (WiFi off, voice over Tailscale per ADR-7): note capture, status query, prompt send — all green.
5. **Recovery**: kill daemon mid-session → spoken "reconnecting" → session resumes; device reboot → fully armed within 60 s, no touch.
6. **Rollback**: mtkclient restore rehearsed; documented unroot procedure verified step-by-step.
7. **Security**: credentials in Keystore, no plaintext secrets on disk, relay E2EE confirmed by relay-side capture (ciphertext only).

---

## 7. Risk register

| # | Risk | Likelihood | Mitigation |
| --- | --- | --- | --- |
| R1 | NX1 AEC insufficient → self-barge-in on TTS echo | Medium | D1.3 early; ducking fallback (half-duplex); barge-in requires PTT if AEC fails |
| R2 | Side key not capturable/remappable | ~~Low–Medium~~ **Closed 2026-11-21** | Raw `/dev/input/event0` capture confirmed working with root; ADR-6 contract decided |
| R3 | OEM Android kills foreground service despite exemption | Medium | Root-level `pm` exemption, Magisk module; GSI (ADR-1) if stock fights |
| R4 | Relay/4G jitter breaks streaming feel | Medium | Opus + jitter buffer; Tailscale path as failover (owner priority #2) |
| R5 | z.ai realtime model absent/costly for always-on | Medium | Cascade baseline is the design default; realtime is an upgrade gate, not a dependency |
| R6 | Kokoro needs GPU unavailable on server | Low | CPU fallback accepted slower TTS; ack phrases pre-synthesised |
| R7 | Device theft/loss exposes daemon credentials | Low | Keystore + remote daemon token revoke; FDE on |
| R8 | Boot partition gzip quirk bricks root attempts | Low | mtkclient backup before anything; root via `init_boot` only |

---

## 8. Decisions log

Resolved (2026-11-19):
1. ~~Repo layout~~ → **standalone new repo** (ADR-3); illegal-lion remains UI-first, Alice adapts its connection architecture.
2. ~~Wake phrase~~ → **"Hey Alice"**; assistant persona named Alice.
3. ~~Notes destination~~ → **ephemeral Paseo session per note, filed to memos via memos MCP**, session archived after filing.
4. ~~Device variant~~ → **8 GB / 128 GB confirmed**.

Still open:
1. **Notes-session default model**: owner's GLM default proposed; confirm at M3.
2. **GSI vs stock**: stock first per ADR-1; switch trigger = R3/R2 evidence, not preference — confirm acceptable.

Resolved since (2026-11-27, architecture review):
1. ~~Voice transport off LAN~~ → **ADR-7: Tailscale carries the gateway** (owner decision, revisitable; revisit trigger recorded).
2. ~~Intent-orchestration location~~ → **ADR-8: deterministic grammar in the app** (owner delegated to review recommendation).
3. ~~Speech backend Paseo option~~ → **D1.4 closed on evidence**; cascade is the v1 backend (D1.5 z.ai realtime stays open, scoped to M2 partial transcripts).

Scaffolded 2026-11-19: repo `hey-alice` at `~/projects/hey-alice`; this document is its founding doc (`docs/plan.md`).

## 9. Immediate next actions

1. ~~Scaffold `hey-alice`~~ — done 2026-11-19 (`~/projects/hey-alice`); remaining: gradle wrapper + first `assembleDebug` inside the devshell.
2. ~~D1.1 backup + root~~ — **M0 COMPLETE 2026-11-21**: backup VERIFIED (`.backups/nx1-20261120-003415/`, super caveat documented), bootloader unlocked (owner-confirmed wipe; wipe switched active slot a→b — both init_boot slots were pre-patched), Magisk 31.1 flashed to init_boot, `verify-root.sh` all gates pass. Battery-optimisation exemption **deferred to M1 first deploy** (com.heyalice APK doesn't exist yet). D1.2 side-key contract resolved (ADR-6).
3. **Next: D1.3 audio/AEC spike** (longest technical unknown) + M1 voice loop skeleton.
4. Draft voice-session protocol doc during M1 so M2/M3 build against a written contract.
