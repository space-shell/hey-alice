# Architecture-findings tracker — hey-alice

**Purpose:** working checklist for the findings from `docs/review-architecture-2026-11-27.md`
(GLM-5.4 architecture review). This document exists so that development can survive
context compaction: every item is self-contained, with acceptance criteria, so a fresh
or compacted context can pick up work without re-reading the full review.

**How to use (any future context):**
- Work items one by one, in the order the phases dictate (decisions → pre-M2 → M2 → probes → M3).
- When an item is done, set `- [x]`, append the date and the commit hash, and add a
  one-line "Done:" note with evidence (file/ADR/section). Never delete items.
- If reality contradicts an item, do not silently rewrite it — append a `Correction:`
  note and update the plan/ADR as the item says.
- `blocked(…)` means a named decision or input is missing — do not start the item;
  resolve the blocker first.

Status legend: `[ ]` open · `[~]` in progress · `[x]` complete · **blocked(...)**

---

## A. Owner decisions (gate everything below)

- [x] **A1 — ADR-7: voice transport off the LAN** (review §1, §6b, risk #1).
      The Paseo relay carries only the daemon's own protocol — the voice gateway has
      NO relay path, so M3's "all five intents work over relay" and M5's 4G trial
      cannot pass as the plan reads today. Options:
      **A** = Tailscale carries the gateway (works today; plan wording changes;
              off-LAN voice depends on Tailscale being up).
      **B2** = gateway becomes a daemon-side Paseo plugin, voice PCM over plugin
              binary frames (the only true "relay first" path; unverified — needs
              the PRB-1 spike, 50 msg/s through the relay).
      Decision + recorded ADR-7 gates M3 exit criteria and M5 design.
      **Decision 2026-11-27: option A — Tailscale, owner choice, explicitly revisitable.**
      Recorded as ADR-7 in plan.md (revisit trigger + D4 spike noted there).
      Done: 2026-11-27, plan.md ADR-7.
- [ ] **D5 — Install Tailscale on the NX1 + join the tailnet** (follows A1).
      Required before any off-LAN voice work (M3/M5); NOT needed for LAN M2.
      Sideload the Tailscale APK (adb install; login needs an owner tap/browser
      auth on the device), point the app's gateway URL at the server's tailscale
      IP (100.127.193.39) when off-LAN use starts. Note: server firewall already
      trusts tailscale0 (services.nix trustedInterfaces).
      **blocked(owner co-located for login tap; low priority until M3)**

- [x] **A2 — ADR-8: intent-orchestration location** (review §1, "Decisions" #3).
      Reviewer recommendation: deterministic grammar runs in the app, with
      optimistic spoken acks ("sent to X") and a defined speech-queue policy.
      Alternative: routing in the gateway. Confirm location before M3; record ADR-8.
      **Decision 2026-11-27: owner delegated to the review recommendation — grammar
      in the app.** Plain-language note for the owner: "intent routing" is what
      decides what a spoken command MEANS ("note: buy milk" → create a note
      session; "status" → query agents; "tell X to …" → send a prompt). v1 uses a
      fixed pattern-matcher (no LLM), and ADR-8 places it inside the Android app
      where agent state lives, so spoken acks fire immediately and the gateway
      stays a pure speech pipe. Recorded as ADR-8 in plan.md.
      Done: 2026-11-27, plan.md ADR-8.

- [x] **A3 — ADR-2 closure / D1.4 output** (review §1 F2, "Decisions" #2).
      Record on evidence: Paseo v0.15.3's speech stack cannot replace the cascade —
      audio is base64-in-JSON; TTS ships whole segments (≤260 chars) so first audio
      waits for the full segment; TTS exists only as an agent `speak` tool (no
      client-callable synthesis); voice mode sends transcripts to an agent, the
      opposite of the deterministic grammar. Cascade (faster-whisper + Kokoro behind
      the gateway) is the v1 backend. D1.5 (z.ai realtime) stays open, scoped to
      M2's partial-transcript design only.
      Done: 2026-11-27, plan.md §D1.4 marked RESOLVED with the evidence; §8
      decisions log updated.

## B. Before M2 code (cheap now, breaking if deferred)

- [x] **B1 — Cut voice-session protocol v1, carrier-independent** (review §3, risk #4).
      Defined as messages, not WebSocket frames, so the carrier (plain WS now,
      daemon-plugin frames later) can change. Required edits:
      (1) version field + REAL negotiation (v0 sends version, both sides ignore it);
      (2) split the conflated `seq` into turn-id + stream-id;
      (3) `tts_abort{stream, offset}` — scoped abort for barge-in;
      (4) session token + resume (reconnect without losing the turn);
      (5) server `endpoint` events (server re-verifies VAD endpoints);
      (6) document `tts_request` (exists in code, absent from protocol.md).
      Update docs/protocol.md. Acceptance: protocol.md states v1 with all six; both
      sides can still speak v0 (flag-gated) until the M2 client work lands.
      Done: 2026-11-27, protocol.md rewritten as v1 (all six; `endpoint` defined,
      emitted once server VAD lands). Server implements negotiation + resume +
      tts_abort now; v0 compat verified by test_smoke.py §7 (current APK unaffected).

- [ ] **B2 — Plan edits from the review** (review "Decisions" #6, §7).
      (a) Add an endpoint-latency segment to the §4 latency budget (VAD endpoint →
      final affects the 500 ms release→final budget).
      (b) M3 exit criteria and §6.4 must NAME the voice transport from A1.
      (c) Scope "always-on" into a milestone: boot start, auto-connect, supervision,
      reconnect — currently in NO milestone, but §6.5 requires "reboot → armed in
      60 s, no touch".
      (d) Mark D1.4 resolved (per A3).
      Acceptance: plan.md updated; done together with A1–A3.
      **Partial: (b) and (d) done 2026-11-27 (plan.md M3 exit + §6.4 + §D1.4).
      Remaining: (a) endpoint-latency segment — needs M2 VAD numbers, do during
      M2 planning; (c) always-on milestone scoping — needs D1 probe results.**

## C. M2 implementation (the review's "fix at M2 start" set)

- [ ] **C1 — Split the gateway's global inference lock; make TTS cancellable**
      (review §4, §7.2).
      Today one global lock covers STT and TTS and TTS sends happen while holding
      it; TTS tasks are untracked and uncancellable, so a barge-in utterance waits
      behind the interrupted one's synthesis. Split into STT and TTS locks, add a
      per-connection writer queue, track TTS tasks so `tts_abort` can cancel them.
      M3's intent-routing seam is one call site at server.py:134.
      Acceptance: barge-in utterance's first audio does not wait for the aborted
      utterance's synthesis; demo shows TTS stop < 300 ms (M2 exit).
      Done: 2026-11-27, server.py reworked (stt_lock/tts_lock, writer queue with
      aborted-stream frame drop, tracked cancellable TTS tasks, session token +
      resume, F1 buf-snapshot fix). Verified by gateway/test_smoke.py: 16/16 PASS,
      barge-in stop latency 1 ms (budget 300 ms). Also removes the live contention
      seen in the owner's 16:51 test (stt_ms 2748 waiting behind TTS synthesis).

- [ ] **C2 — Extract a single-threaded SessionController from AliceRuntime**
      (review §2, risk #2; est. 2–3 days with JVM tests).
      AliceRuntime holds seven responsibilities; session state is written from three
      threads with no serialisation. Move session/event handling into one
      single-threaded controller (actor or confined handler); AliceRuntime becomes
      composition root + wiring. Unit-testable on the JVM.
      Acceptance: session transitions have a single writer thread; JVM tests cover
      the M2 transitions incl. barge-in.
      **blocked(nothing — M2 start)**

- [ ] **C3 — Capture fan-out with pre-roll** (review §2).
      Capture currently has one gated sink (frames flow to the gateway only between
      start/stopFrameFlow). M2's VAD and M4's wake word need to observe frames
      continuously with a pre-roll ring buffer. Add a fan-out: gateway sink, VAD
      sink, (later) wake-word sink, each independently gated, plus pre-roll.
      Acceptance: VAD sees continuous audio incl. 1–2 s pre-roll without frames
      leaking to the gateway outside PTT.
      **blocked(nothing — lands with C2)**

- [ ] **C4 — AudioEngine playback API: `abort()`, `playedOffset()`, `duck()`**
      (review §2).
      Needed for barge-in (abort current TTS), abort semantics (which samples
      actually played → offset for tts_abort), and ducking fallback (ADR/R1
      half-duplex degrade). AudioEngine is otherwise the right single owner of
      AudioRecord/AudioTrack — extend, don't rework.
      Acceptance: abort stops playback < 50 ms and reports playedOffset; duck()
      scales playback volume without tearing down the track.
      **blocked(nothing — lands with C2)**

- [ ] **C5 — State machine: make the code a machine** (review §5 — the one
      needs-rework verdict).
      State set in VoiceSessionState is right; mechanics are not: transitions are
      ad-hoc writes across three threads; ROUTING and INTERRUPTED are never entered;
      RESPONDING's only exit is the playback-drain callback armed solely by tts_end
      (a `final` with empty text leaves the app stuck in RESPONDING). INTERRUPTED
      must be a one-event transient with a defined exit for every input. In PTT mode
      the 300 ms barge-in clock starts at the 500 ms hold threshold, not key-down.
      Implement inside C2's SessionController with JVM tests.
      Acceptance: every (state, input) pair has a defined transition; empty-final
      returns to IDLE; JVM-tested.
      **blocked(C2)**

- [ ] **C6 — Move connection + reconnect policy out of MainActivity** (review §2).
      MainActivity today triggers connectGateway with the URL from prefs; reconnect
      policy (when the WS drops, who retries, backoff) belongs in the connection
      layer (GatewayClient or a supervisor owned by the runtime), not the UI.
      Acceptance: killing the gateway mid-session → automatic reconnection with
      backoff; UI only displays state.
      **blocked(nothing — lands with C2)**

- [ ] **C7 — Extract the AEC test harness from AliceRuntime** (review §2).
      runAecTest + fetchClip + capturePass are ~100 of AliceRuntime's 282 lines —
      test tooling living in the production runtime. Move to a separate class
      (e.g. debug/AecProbe.kt) behind a debug entry point.
      Acceptance: AliceRuntime carries no AEC-test code; the AEC test still works.
      **blocked(nothing — lands with C2)**

- [~] **C8 — Concurrency harness: fake gateway + automated barge-in/resume tests**
      (review §7.5, next-tier risks).
      No automated tests exist for barge-in timing, soak, or resume, and there is no
      fake gateway to test against. Build a scripted fake gateway (JVM or host
      Python) that can: send partials/finals on cue, stream/cancel TTS, drop the
      socket mid-turn. C2's JVM tests + this harness are the M2 regression net.
      Acceptance: one automated barge-in test and one resume test run in CI/devshell.
      Progress 2026-11-27: gateway/test_smoke.py seeds the host-side half —
      barge-in (1 ms stop), tts_abort, resume, v0-compat all asserted against the
      live gateway (16/16). Remaining: JVM-side client tests + mid-turn socket-drop
      scenario (lands with C2).

## D. Probes (measure before sizing/designing)

- [ ] **D1 — Always-on probe: reboot-to-armed** (review §7.4, risk #3; half a day).
      Today nothing starts at boot and nothing reconnects. Probe on the NX1:
      (a) does a `microphone`-type foreground service start from a BOOT_COMPLETED
      receiver on Android 14+ (documented restriction may apply); (b) if not, what
      is the workable start path on this ROM (root: am start from a Magisk
      boot script? accessibility? device-owner?); (c) process-kill survival of
      AliceService with the battery exemption in place.
      Output: the start mechanism decision, feeding B2(c) milestone scoping.
      **blocked(nothing — half-day device session)**

- [ ] **D2 — Opus codec decision** (review §7.3).
      Opus (ADR-4, needed before the 4G trial) is an APP + PROTOCOL change, not a
      gateway item. Three unknowns: (a) MediaCodec `audio/opus` encoder availability
      on the NX1 (optional in Android — probe it); (b) libopus-via-JNI needs the NDK,
      which is in neither devshell; (c) whether the gateway's locked PyAV wheel
      carries libopus. Output: codec plan for M5 or explicit deferral.
      **blocked(nothing — device + host probes)**

- [ ] **D3 — Telephony/mic exclusivity** (review §7 next tier).
      VoLTE must keep working (device requirement) while the voice loop runs.
      Unmodelled and unverified: what happens to AudioRecord during a call, and can
      the loop coexist with telephony audio focus? Probe during a real call.
      Output: modelled behaviour (duck/pause on call) → plan note.
      **blocked(nothing — needs an actual call on the NX1)**

- [ ] **D4 — PRB-1 spike: daemon-plugin carrier for voice** (review §1, feeds A1).
      Time-boxed spike: can the Paseo relay carry 50 msg/s (20 ms PCM frames + JSON
      control) through a daemon plugin's binary frames without unbounded latency?
      Output: numbers → A1 decision. Skip entirely if the owner picks option A.
      **SKIPPED 2026-11-27: A1 resolved to option A (Tailscale). Only revisit if
      ADR-7's revisit trigger fires.**

## E. M3 items (record now, do in the M3 port)

- [ ] **E1 — SecretStore: Keystore-backed credentials at M3, not M6** (review §6a).
      The M3 port brings the daemon bearer password. xagent stores it in plain
      SharedPreferences — a credential that can create/drive/archive agent sessions
      must not sit in plaintext on a rooted device from day one. Build a
      `SecretStore` interface (Keystore-backed; plain debug impl for LAN) in the M3
      port. Add to ADR-5 amendment.
      **blocked(M3 start)**

- [ ] **E2 — Port the `protected` relay E2EE mode, NOT xagent's legacy crypto**
      (review §6d).
      Relay E2EE modes: `legacy` (X25519+NaCl box, random nonces, NO replay
      protection) vs `protected` (Noise_NK_25519_ChaChaPoly_SHA256 with counters).
      xagent implements legacy (`E2eeCrypto.kt`, `crypto_box_beforenm`) and its
      e2ee_hello carries no `protected` field — ported as-is, Alice depends on the
      daemon never enforcing `protected`. Use xagent as reference only; implement
      `protected` against the Noise fixtures (paseo docs/relay-endpoint-security.md).
      **blocked(M3 start)**

- [ ] **E3 — Decompose the 999-line port source** (review §2 S5, risk #5).
      The M3 connection-layer port source is a 999-line class; port it as focused
      pieces (connection, agent-state model, RPC client), not a single file. ADR-3's
      adapted-copy rule stays.
      **blocked(M3 start)**

- [ ] **E4 — Daemon password must be configured** (review §6e).
      With no password hash configured, the daemon admits any client as owner;
      over the relay the only gate is possession of the pairing. Before any M3/M5
      off-LAN testing: configure the daemon password, then the app's SecretStore
      (E1) holds it.
      **blocked(M3 start; ops task on jn-server)**

- [x] **E5 — Root-equivalent app rule in ADR-5** (review §6c).
      The app holds a Magisk root grant (SideKeyWatcher execs su); anything it
      loads at runtime runs with that grant reachable. Rule: all models (ONNX for
      VAD/wake word, M2/M4) are bundled in the APK — no runtime fetch over an
      unauthenticated channel. One sentence in ADR-5, now.
      Done: 2026-11-27, plan.md ADR-5 amendment sentence added.
- [x] **E6 — E2EE coverage note: voice leg ≠ RPC leg** (review §6b).
      Relay E2EE protects the RPC leg only; the same content ("tell X to …",
      spoken + tts_request text) crosses the voice leg in clear. §6.7's "relay E2EE
      confirmed (ciphertext only)" acceptance test would pass while the voice leg
      is readable. Resolution follows A1: Tailscale (option A) → WireGuard covers
      the voice leg; plugin carrier (B2) → relay ciphertext covers it. Record in
      ADR-7 whichever way.
      Done: 2026-11-27, coverage note recorded inside plan.md ADR-7 (option A:
      WireGuard covers the voice leg).

## F. Bug-adjacent items from the review appendix (fold into M2 branch; "not architectural, unverified at runtime")

- [ ] **F1 — server.py run_final reads self.buf after the lock wait**
      (server.py:124–128). Stage-boundary race; verify and fix during C1's lock
      rework.
- [ ] **F2 — empty-text final leaves the app in RESPONDING**
      (AliceRuntime.kt:96–102). Fixed structurally by C5 (defined transitions);
      verify the empty-final → IDLE case in C5's tests.
- [ ] **F3 — SideKeyWatcher.start() sets running=true after starting the reader
      thread whose loop is `while (running)`** (SideKeyWatcher.kt:50–57). The
      reader can exit before the flag is set → PTT dead until service restart.
      Set the flag before Thread.start().
- [ ] **F4 — runAecTest leaves the engine stopped while connected=true**
      (AliceRuntime.kt:254, 269–272). After an AEC test, PTT is dead until
      reconnect. Interim workaround (documented 2026-11-27): run PTT tests BEFORE
      the AEC test, or reconnect afterwards. Permanent fix lands with C2/C7.

---

## Completion log (append one line per completed item)

| Date | Item | Commit | Note |
| --- | --- | --- | --- |
| 2026-11-27 | tracker created | 8ed7d76 | all items open |
| 2026-11-27 | A1 complete | (this commit) | ADR-7: Tailscale, owner choice, revisitable |
| 2026-11-27 | A2 complete | (this commit) | ADR-8: grammar in the app (delegated) |
| 2026-11-27 | A3 complete | (this commit) | D1.4 resolved with evidence in plan.md |
| 2026-11-27 | B2 partial | (this commit) | (b)+(d) done; (a) waits on M2 numbers, (c) on D1 probe |
| 2026-11-27 | D4 skipped | (this commit) | superseded by A1 option A |
| 2026-11-27 | E5 complete | (this commit) | ADR-5 amendment sentence |
| 2026-11-27 | E6 complete | (this commit) | coverage note in ADR-7 |
| 2026-11-27 | D5 added | (this commit) | Tailscale on NX1 — new follow-up item |
| 2026-11-27 | B1 complete | (this commit) | protocol.md v1 + server negotiation/resume/abort |
| 2026-11-27 | C1 complete | (this commit) | lock split + writer queue + cancellable TTS; smoke 16/16, abort 1 ms |
| 2026-11-27 | C8 progress | (this commit) | host-side smoke seeded; JVM side pending C2 |
