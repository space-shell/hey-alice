# Architecture review — hey-alice

> Reviewed 2026-11-27 against plan v1 (`docs/plan.md`), protocol v0
> (`docs/protocol.md`) and the tree at `02961fa` (M0 done, M1 voice loop working
> on-device). Architecture only: does the shape fit the M2→M6 roadmap. Not a bug
> hunt. No code changed, nothing committed.

## 0. Evidence and unknowns

Read in full: plan, protocol, handover-m1, both READMEs, the ten Kotlin files
under `app/src/main/java/com/heyalice/`, `gateway/server.py`,
`gateway/test_client.py`, manifests, Gradle files, flake devshells.

Two questions (off-LAN voice, the M3 port) cannot be answered from this repo.
For them I read:

- the port source: the `space-shell/xagent` worktree at
  `~/.paseo/worktrees/357w34dc/illegal-lion`, branch
  `bluefox-nx1-voice-companion-plan` (cited `xagent:`);
- the Paseo monorepo at `/home/jamesnicholls/projects/paseo` (`54b34b3`, v0.15.3,
  cited `paseo:`): public docs plus the voice, TTS, relay, admission and plugin
  frame code. Every Paseo claim cited below was checked against the source
  lines.

Unknowns the verdicts are conditional on:

| Unknown | Evidence | Why it matters |
| --- | --- | --- |
| D1.3 AEC verdict not recorded | `plan.md` D1.3 has no result; the verdict script `tools/analyze-aec.sh` is untracked | Decides whether M2 barge-in is voice-triggered or PTT-only with ducking (plan D1.3 fallback). Also an unmet M1 exit criterion. |
| D1.5 (z.ai realtime) not run | No output doc; A3 still "Unverified" (`plan.md:33`) | Affects M2's partial-transcript design only |
| No M1 latency breakdown in `docs/` | 1.26 s first chunk exists only as a commit subject (`d3caeaf`); the server comment puts the "You said:" clause at 0.75 s (`server.py:154–156`) | Leaves 0.24 s against the 1.5 s LAN budget before M2–M3 add anything |

Verdict labels: **sound** / **sound-with-caveats** / **needs-rework**.

## Summary

| # | Question | Verdict | Core reason |
| --- | --- | --- | --- |
| 1 | Coherence | sound-with-caveats | Shape is right on the LAN, and the cascade is validated against Paseo's own speech stack. Off the LAN the gateway has no relay path; a daemon plugin is the only relay-compatible carrier and it is unproven. |
| 2 | App layering | sound-with-caveats | The singleton as composition root is fine. Seven responsibilities and one gated capture sink will not carry VAD, barge-in, wake word and Paseo events. |
| 3 | Protocol v0 | sound-with-caveats | Framing is right. The message set is not sufficient for M2; four needed edits are breaking if deferred. |
| 4 | Gateway shape | sound-with-caveats | Single file is right at 254 lines. One global inference lock, sends under the lock, no cancellable TTS. |
| 5 | State machine | needs-rework | State set is right. The code is not a machine: writes are unserialised across three threads, RESPONDING has no declared exit. |
| 6 | Security | sound-with-caveats | Deferral is OK. Keystore must arrive with M3; E2EE on the Paseo leg does not cover the voice leg; the port source implements the legacy relay mode. |
| 7 | Milestones made harder | — | Five items, §7 |

---

## 1. Coherence — sound-with-caveats, conditional on one decision

**What holds up**

- One voice channel (JSON control + binary PCM) is the right app/gateway
  boundary: the app stays an audio and I/O client, models sit where the compute
  is, and the boundary is the ADR-2 swap point.
- Building `AudioEngine` full-duplex in M1 is why M2 barge-in needs no audio-I/O
  rework. `AudioRecord` and `AudioTrack` are live for the whole gateway session
  (`AudioEngine.kt:62–96`, `154–207`); frames are only gated (`:92–93`).
- The deterministic grammar limits the damage of false accepts. A spurious wake
  or VAD trigger can match a fixed grammar or nothing; it cannot be
  "interpreted" into an agent action. (Paseo's own voice mode routes the
  transcript into an agent session — `paseo: voice.md:23`.)
- M2's "server is the endpoint source of truth" (`plan.md:164`) is what makes
  the protocol backend-agnostic. It stops `ptt_end` being the only turn
  delimiter, which a speech-to-speech backend (A3) could not honour.
- First-clause streaming TTS and raw binary PCM (commit `d3caeaf`) are the
  right call. Paseo's own stack has neither (F2).

**Where it fights the roadmap**

**F1 — M3/M5: the voice channel has no "relay first" path.** The plan says
"Paseo relay (E2EE) first, Tailscale/WireGuard second" (`plan.md:24`). The
relay terminates at the daemon's session admission (`paseo:
packages/server/src/server/websocket/secure-relay-ingress.ts:5–8`) and forwards
frames unmodified (`paseo: packages/relay/src/types.ts:8`). Whatever crosses it
must be a daemon session message. xagent speaks exactly that: `e2ee_hello`, then
daemon envelopes as ciphertext (`xagent: PaseoDaemonClient.kt:385–402`). The
gateway is a second server on a different port with no auth (`server.py:245`)
and its own protocol; nothing carries it. Off the LAN it is reachable only
through Tailscale or a public endpoint.

Consequences:

- M3's exit criterion "all five intents work over relay" (`plan.md:225`) is not
  satisfiable for the voice leg as written.
- For voice, Tailscale is mandatory, not second. The plan's priority order
  holds only for the Paseo leg.

Three ways out; one needs choosing before M3 design:

| Option | What it is | Cost | Verdict |
| --- | --- | --- | --- |
| **A** | Tailscale carries the gateway off the LAN | None in code; plan wording; Tailscale becomes a hard dependency for voice | Works today |
| **B1** | Paseo's own voice messages over the daemon socket | None new for transport | Rejected on evidence — F2 |
| **B2** | The gateway as a daemon-side Paseo plugin; PCM over plugin binary frames | Plugin host is TypeScript (bridge or port the Python gateway); Kotlin client speaks plugin frames; 50 msg/s through the relay unverified | The only option that keeps "relay first" for voice |

B2 is mechanically real. Plugin subscription events and RPC inputs carry a
top-level `Uint8Array` as binary, without JSON or base64 (`paseo:
public-docs/plugins/reference.md:2554–2556`); `plugin-examples/media-stream`
"streams video and audio this way and uploads a frame back through an RPC"
(`:2619–2620`); opcodes 0x20–0x2f are reserved for it (`paseo:
packages/protocol/src/binary-frames/plugin.ts:3–15`). Protocol v0's
JSON-control / binary-PCM split maps onto it unchanged.

- Decide with a time-boxed spike (D1.4 re-scoped): 50 msg/s each way through
  the relay, time-to-first-chunk, with A as the fallback.
- To keep the choice open without rework, separate the voice protocol codec
  from its socket on both sides in M2 (§3, §4). The carrier is then a plain
  WebSocket today and plugin frames later, with session logic untouched.

**F2 — M2: ADR-2 is open; a desk audit of Paseo's speech stack now settles the
Paseo option.** A2 is still "Unverified" (`plan.md:32`) and D1.4 has no output
in `docs/`. What Paseo v0.15.3 implements:

- Audio is base64 inside JSON text frames: `voice_audio_chunk`, `audio_output`
  (`paseo: packages/protocol/src/messages.ts:990–995`, `3750–3761`). The binary
  demux has no audio kind (`paseo:
  packages/protocol/src/binary-frames/demux.ts:15–20`).
- TTS is segment-at-a-time, not streamed. The manager collects the whole
  provider stream for a text segment (`MAX_TTS_SEGMENT_CHARS = 260` — `paseo:
  packages/server/src/server/agent/tts-manager.ts:30`) and emits one
  `audio_output` with `chunkIndex: 0, isLastChunk: true` (`:386–412`). First
  audio waits for the whole segment.
- TTS exists only as an agent's `speak` tool (`paseo:
  packages/server/src/server/session/voice/voice-session.ts:1053–1071`; the
  only production caller of `generateAndWaitForPlayback`). There is no
  client-callable synthesis.
- Voice-mode partial transcripts are logged, not sent (`voice-session.ts:601–606`).
  Dictation does stream (`dictation_stream_*` — `messages.ts:1800–1823`).
- Voice mode sends the final transcript to an agent as spoken input
  (`voice-session.ts:1049`) — the opposite of the deterministic grammar.
  Transcription without an agent is available (`:759–763`).
- Client SDKs: TypeScript only.

So Paseo's stack could supply the STT half (transcription-only mode or
dictation), not the TTS half, and it cannot bound time-to-first-audio by the
first clause. The cascade is the right v1 backend on evidence, not by default.
**Close ADR-2 for the Paseo option and record this as D1.4's output.** D1.5
(z.ai realtime) stays open; it affects only M2's partial-transcript design, not
VAD, endpointing, abort or resume.

**F3 — M3: where orchestration lives is implied, not decided.** The plan's
diagram and `PaseoConnection.kt:15–21` put intent routing and Paseo RPCs in the
app, and the state machine has `ROUTING` on the device. Read literally, the flow
is: transcript arrives from the gateway → grammar on-device → RPC over a second
socket → result text goes back up to the gateway for synthesis (`tts_request` —
implemented at `GatewayClient.kt:109–110`, absent from protocol.md). The plan
does not account for three consequences:

1. Two long-lived sockets with different security models and reconnect regimes
   — unless F1 option B2 puts voice on the daemon socket.
2. Up to two extra WAN round trips per spoken ack (RPC response, then
   `tts_request` → first chunk). Issuing the ack on the transcript instead of
   the RPC response removes one; the plan already accepts optimistic archive.
3. Speech that arrives with no turn (agent finished → announce) has no path in
   the state machine (§5).

The alternative — routing inside the gateway, which becomes a Paseo client —
gives one socket from the device and LAN-speed RPCs, but puts daemon credentials
on the gateway and forfeits relay E2EE for agent control. I would keep
app-side: the status UI needs the daemon subscription anyway (`plan.md:225`).
It should be an ADR, with the three consequences designed.

**F4 — M4: capture is bound to the gateway.** Audio starts from the gateway's
`onReady` (`AliceRuntime.kt:87–92`) and has one gated sink (§2 S2). A wake word
has to run before and without a gateway connection.

**F5 — plan gap: no latency segment for endpointing.** In wake mode nothing
replaces the key release, so the server's silence threshold adds to response
latency before STT even starts. 1.26 s release→first chunk leaves 0.24 s against
the 1.5 s LAN budget (`plan.md:182`). For scale: Paseo's own turn detector uses
800 ms of speech confirmation and 1000 ms of end-of-speech silence (`paseo:
packages/server/src/server/speech/providers/local/sherpa/silero-vad-session.ts:19–20`).
Decide the endpoint budget before choosing M2's thresholds, and say whether
"wake → first spoken ack" measures the chime (cacheable, immediate) or the
answer.

---

## 2. App layering — sound-with-caveats

`AliceRuntime` (282 lines) is a process-wide `object` with seven
responsibilities:

| # | Responsibility | Where |
| --- | --- | --- |
| R1 | gateway connection lifecycle | `connectGateway`, `disconnect`, `Listener` wiring — `AliceRuntime.kt:83–146` |
| R2 | audio lifecycle, started from the gateway's `onReady` | `:87–92`, `151–160` |
| R3 | uplink routing (anonymous `FrameSink` → `sendPcm`) | `:154–158` |
| R4 | session-state transitions | `:72–78`, `96–102`, `129–137`, `164–181` |
| R5 | UI-observable state (8 `MutableStateFlow`s) | `:38–45` |
| R6 | latency instrumentation | `:30–36`, `56–57`, `99–101`, `112–116` |
| R7 | D1.3 AEC test harness (≈100 lines, 36% of the file) | `:59–61`, `183–281` |

Will it hold when VAD, barge-in, wake word and Paseo state join? No. The
singleton is not the problem — a single-device, single-user app needs exactly
one process-wide owner and no DI framework. The problem is that R2–R4 are fused:
the same object decides when audio runs, where frames go and what the session
state is, with no serialisation between them.

**Seams to extract, in the order they are needed**

**S1 — M2: `SessionController`.** Today `state` is written at five sites in
four functions, on three threads: OkHttp's reader (`onFinal`, `onClosed`), the
`alice-play` thread (`onDrained` → `toIdle`) and the `alice-sidekey` thread
(`pttStart`, `pttEnd`). The only guards are ad-hoc reads of `state.value`
(`:78`, `:174`). M2 adds a VAD thread, M4 a wake-word thread, M3 Paseo
callbacks. Extract one event loop — a `Channel<SessionEvent>` on a
single-thread dispatcher — that is the only writer of `state` and the only
caller of the audio and gateway commands. Everything else posts events. This
also makes the transition table unit-testable on the JVM, which `AliceRuntime`
is not (`android.util.Log`, `SystemClock`, `Context` throughout; `app/src` has
no test source set and `app/build.gradle.kts:36–48` no test dependencies).

**S2 — M2: capture fan-out.** `AudioEngine` has one sink and one gate
(`@Volatile var sink: FrameSink?`, `flowOpen` — `AudioEngine.kt:56–57`,
`92–93`, `128–129`). Barge-in needs VAD on the same frames while RESPONDING;
wake word needs them while IDLE; both need pre-roll (VAD confirms speech only
after its minimum-speech window, which is tens to a few hundred of ms depending
on the Silero version; the wake engine has its own window), and the gate
discards every closed frame. Make `AudioEngine` emit every frame unconditionally
to a frame bus with a ring buffer (≥1 s); VAD, wake word and the uplink
subscribe and re-chunk to their own frame sizes. Separately, start capture from
the service, not from `onReady`.

**S3 — M2: playback transport API.** `AudioEngine` offers `enqueueTts`,
`flushAndNotifyDrain`, `stopPlayback` (`:210–224`). Barge-in needs:

- `abort()` — pause + flush without tearing the track down. It must also reset
  `bytesWritten`, or the drain check at `:190–194` compares a reset
  `playbackHeadPosition` against a stale count.
- `playedOffset()` — the playback cursor for the current stream, for the
  `tts_abort` report and for resume (§3).
- `duck()` — if D1.3 comes back AEC-weak or absent (plan D1.3 fallback).

M5 adds jitter buffering in the same place: today `enqueueTts` → `track.write`
is immediate and the track buffer is `minBuf` in low-latency mode (`:171–172`),
i.e. zero jitter tolerance. Keep all of this inside `AudioEngine`; it is the
right home.

**S4 — M2/M5: `GatewayConnectionManager`.** The connect trigger and URL
persistence live in `MainActivity` (`:86–89`, `116–121`); each connect builds a
fresh `OkHttpClient` that is never shut down (`GatewayClient.kt:35–38`);
`onFailure` sets an error string and nothing retries (`:84–88`). A sticky
restarted service therefore never reconnects. One object should own the client,
the URL, the backoff (xagent's `scheduleReconnect` is a usable pattern: 1 s ×
2ⁿ, cap 30 s — `xagent: PaseoDaemonClient.kt:476–494`), WiFi↔4G handoff and the
resume token. Also make connection state a sealed type: `connection` is a
free-text `MutableStateFlow<String>` and `onClosed` branches on
`startsWith("error")` (`AliceRuntime.kt:134–135`).

**S5 — M3: intent router + Paseo orchestration.** New pure-Kotlin package, no
Android imports, grammar unit-tested against transcripts. `PaseoConnection.kt`
is an empty class whose comment lists the right TODOs; the design fits the
skeleton, but the source it names does not:

- xagent's `PaseoDaemonClient` is 999 lines mixing socket, E2EE, JSON, RPC
  correlation and agent-state merging. Port it as three types (transport +
  crypto, RPC client, agent store).
- There is no Kotlin SDK for the daemon protocol (TypeScript only), so the
  port is hand-rolled by necessity. Budget it as such.
- Two items are missing from the stub's TODO list: the `protected` relay mode
  (§6, item d) and, if F1 option B2 is chosen, plugin frames.
- Two things not to carry over: plain-`SharedPreferences` credential storage
  (§6, item a) and a second JSON library (xagent uses kotlinx.serialization;
  this app uses `org.json`).

**S6 — now: AEC harness out of the runtime.** `runAecTest` / `capturePass` stop
and restart the engine's capture and playback while the gateway may be
connected (`:254–255`, `:269–272`), leaving PTT dead until reconnect. It is
disposable once D1.3 is recorded; move it to a debug-only class.

**Stubs against their planned design**

- `Vad.kt` fits if `Vad` is a pure consumer/producer: frames in from the bus,
  `Flow<VadEvent>` out to the controller, no Android imports. Its dependency is
  S2, which the stub cannot show. Nothing in the stub needs changing.
- `WakeWordEngine.kt`: `arm()` / `disarm()` fits. One choice to make at M4:
  whether the engine is also armed during RESPONDING. "Hey Alice" spoken over
  TTS is a lower-false-positive barge-in trigger than open VAD; if wanted, the
  controller arms it in two states and treats a detection during RESPONDING as
  an interrupt.
- `PaseoConnection.kt`: see S5.

**Supervision (M4/M5).** Nothing has a restart policy. `SideKeyWatcher`'s reader
returns on EOF without calling `onError` (`SideKeyWatcher.kt:73`), so a dead
`su cat` is silent until process restart. `AudioRecord` init failure throws
(`AudioEngine.kt:78`). `AliceService` is `START_STICKY` with no boot receiver
(`AndroidManifest.xml:4–8`). After a sticky restart the service returns with a
key watcher and nothing else: the gateway connects only from `MainActivity`'s
button, audio only from `onReady`. An always-on device needs one owner of
liveness; `AliceService` is the natural home.

---

## 3. Protocol v0 — sound-with-caveats

The framing is right and should not change: text frames carry JSON control,
binary frames carry PCM without base64, and the 8-byte downlink header (`u32
seq`, `u32 offset`) gives drop detection and the primitive resume needs.

The message set is not sufficient for M2's barge-in or reconnect/resume. v0
promises "message names above stay stable" (`protocol.md:49`); four of the edits
below change existing semantics, so they are breaking if deferred past M2. Cut a
v1 before M2 code lands — today there is one server, one client and one test
client to update.

**G1 — no version, and negotiation is decorative.** `hello{sr, ch, fmt, t_ms}`
is sent (`GatewayClient.kt:49–51`) and ignored: the server answers `ready`
unconditionally (`server.py:207–209`). `ready.sr` is received and dropped —
`startAudio(ttsSr)` ignores its argument and `AudioEngine` is built with the
default `ttsSampleRate = 24_000` (`AliceRuntime.kt:51`, `:151–152`;
`AudioEngine.kt:28`). Opus (M2 "Opus option", required by ADR-4 before M5)
changes the meaning of every binary frame in both directions. Add `v` to
`hello`/`ready`, reject mismatches, make `fmt`/`sr` load-bearing. **Breaking.**

**G2 — one id space for three things.** `seq` is "TTS utterance number (matches
final.seq)" (`protocol.md:39`). The server increments `utt_seq` for a transcript
(`server.py:122`) and borrows it for a TTS-only request (`:228–229`). M3 needs a
turn id (one utterance), a stream id (one TTS output) and RPC request ids: one
turn can yield 0 streams (silence — `:133`), 2 (ack now, answer later), and
agent events yield streams with no turn at all. **Breaking** (`seq` meaning
changes).

**G3 — no TTS-scoped abort.** `cancel` targets "the in-flight utterance"
(`protocol.md:19`) and on the server cancels only the partial task
(`server.py:187–190`, `222–225`). `Session.tts_task` is declared and never
assigned (`:106`); TTS runs as an untracked task (`:220`, `:231`). Barge-in
needs `tts_abort{stream, offset}` — offset = bytes actually played, from S3 —
so the server stops synthesis and, at M3, knows how much of an answer was heard.

**G4 — no server→client endpoint events.** The server is the endpoint authority
and M4 has no `ptt_end`, yet v0's only endpoint signal is `final`, and an empty
`final` is ambiguous (no speech vs unintelligible). Add
`endpoint{turn, reason: silence | ptt_end | timeout | cancel}` and the client's
advisory `vad{speech_start | speech_end}` (plan §4 already names the client
events).

**G5 — no session identity, so no resume.** Session state lives in the
connection object (`Session(ws)`, `server.py:100–107`) and `hello` carries no
token. Resume needs `hello{v, session_token, resume{played[{stream, offset}]}}`
plus a server-side session registry that outlives the socket (TTL) and retains
stream audio — today PCM is generated, sent and discarded (`:163–180`). A 30 s
stream at 24 kHz s16 is 1.44 MB. **Breaking** for `hello`.

**G6 — `error` has no spoken-error contract.** The plan has "any state → error →
spoken error → IDLE"; v0 `error{msg}` is emitted only for unknown types
(`server.py:234`). Add `code` and `speak`.

**G7 — `partial.committed` is not honoured.** The spec says committed is
append-only (`protocol.md:29`); the server re-transcribes the whole buffer after
each 0.65 s sleep and sends the full revisable text as `committed` with
`tentative=""` (`server.py:136–149`); the client reads only `committed`
(`GatewayClient.kt:60`). Either implement a stable-prefix rule or rename the
field.

**G8 — doc drift.** `tts_request` exists in code, not in protocol.md — and it is
the primitive app-side orchestration depends on (§1 F3). `cancel` is specified
and never sent by the runtime.

**Vocabulary fix underlying G2 and G5.** "One WebSocket per voice session" is
not what the code does: one long-lived connection carries many PTT turns, and
the state machine's "session" is one turn. Define four levels — connection
(socket) > dialog (survives reconnect, owns the token) > turn (one utterance) >
stream (one TTS output) — and name ids at each.

**Carrier independence.** Define v1 as messages, never as WebSocket frames. If
F1 option B2 is chosen, Paseo plugin frames carry bytes separately from JSON by
the same rule v0 already uses — a `Uint8Array` nested in an object is rejected,
so bytes and metadata travel as separate messages (`paseo:
public-docs/plugins/reference.md:2573–2576`). A codec that does not assume "one
WS frame = one message" moves between the two carriers unchanged.

---

## 4. Gateway shape — sound-with-caveats

A single file is right at 254 lines. `Engines` shared across sessions (models
loaded once), `Session` per connection, a thin `handle` dispatcher, asyncio with
blocking inference in an executor — all correct for one device. Split when M2
starts, not before.

**What will bite in M2**

- **One global lock for both engines.** `ENGINES.infer_lock` (`server.py:53`) is
  taken by `run_final` (`:126`), `run_partial` (`:142`) and `stream_tts`
  (`:163`). Under barge-in the new utterance's partials and final queue behind
  synthesis of the utterance being interrupted, and nothing can cancel that
  synthesis (§3 G3). Give STT and TTS separate locks and executors: they are
  independent native runtimes (CTranslate2, PyTorch) and need not exclude each
  other.
- **Sends under the lock.** `stream_tts` awaits `self.ws.send(...)` inside the
  locked loop (`:178`). websockets applies write-buffer flow control at
  `write_limit` (default 32 KiB in the installed 17.4). A stalled 4G client
  blocks the send, which holds the lock, which stalls all STT. Push into a
  per-connection outbound queue consumed by one writer task; never hold a lock
  across a network send.
- **Mutable buffer across the stage boundary.** `run_final` snapshots
  `audio = bytes(self.buf)` for logging, then passes `self.buf` again after
  acquiring the lock (`:124–128`); `ptt_start` replaces `self.buf` (`:212`).
  Under contention the final can transcribe a different buffer than the one
  logged. Stages should hand each other an immutable `Utterance(id, pcm, bounds)`
  created at endpoint.
- **Untracked tasks.** `asyncio.create_task(session.run_final())` (`:220`) and
  the TTS task (`:231`) keep no handles; disconnect cleanup cancels only
  `partial_task` (`:239`).
- **Partials are quadratic in utterance length.** Each partial re-decodes from
  t=0 after a 0.65 s sleep (`:138–147`). Fine for 5 s utterances with `tiny.en`;
  not for M3's 30–60 s notes with a larger model. Pick a streaming design for M2
  (windowed re-decode with a stable-prefix commit), and let server VAD skip the
  decode entirely on no-speech turns.

**Growth path (no rewrite)**

```
gateway/
  server.py          # entrypoint only — keeps `nix develop -c python server.py`
  alice_gw/
    protocol.py      # message types, encode/decode, header pack, version check
    connection.py    # the only module that knows the carrier: socket + queue + writer
    session.py       # registry that outlives the socket; turns; id allocation
    speech.py        # speech queue: text → TTS stream → retained PCM, abort at offset
    engines/         # stt.py, tts.py, vad.py — one lock + executor each (ADR-2 swap point)
    responder.py     # on_final(turn) -> [Speech]; EchoResponder (M1)
```

The M3 seam already exists as one call site: `await self.stream_tts(ECHO_PREFIX
+ text, seq)` (`server.py:134`). Replace it with a `Responder`: `EchoResponder`
now; at M3 either a no-op (app-side orchestration — the gateway only serves
`tts_request`) or an intent router (gateway-side). That one line keeps the F3
decision open until it is made.

**Tests.** None exist for the protocol: `test_client.py` is a manual tool, and
the app has no test source set. M2's exit criteria (TTS stops < 300 ms; 30-min
soak, no leaked buffers) are concurrency properties that on-device manual
testing cannot establish. Minimum: (a) Python conformance tests over
`protocol.py` with a fake engine, (b) JVM tests for `SessionController` once it
leaves `AliceRuntime`, (c) a scripted fake gateway to replay disconnect-mid-TTS
and resume against the device.

---

## 5. State machine — needs-rework (small, contained)

`VoiceSessionState` is a bare enum (19 lines). The state set is right. What
exists in code is not a machine: there is no transition table, no single owner,
and the exits of RESPONDING are a property of a media callback.

**Evidence**

- All transitions are assignments in `AliceRuntime`: five write sites in four
  functions, three threads, one guard (`pttEnd`, `:174`). `ROUTING` and
  `INTERRUPTED` are never entered.
- RESPONDING has two exits: playback drain, armed only by `tts_end` →
  `flushAndNotifyDrain()` (`:78`, `:120–123`), and socket close (`:136`). A
  `final` with empty text — which the server sends without TTS
  (`server.py:132–134`) — leaves the state in RESPONDING with nothing armed.
  That is the structural problem: the exit exists only if a media callback
  happens to be armed.
- `onError` changes a text field only (`:125–127`). The plan's "any state →
  error → spoken error → IDLE" does not exist, and there is no state for it.
- `pttStart` goes to CAPTURING from any connected state (`:164–171`). Pressing
  PTT during TTS relabels the state while playback continues and the server
  keeps synthesising. M1 therefore already has a capture-over-TTS path that is
  not a barge-in.
- The plan annotates TRANSCRIBING as the streaming-partials state
  (`plan.md:169–171`); the UI needs partials during CAPTURING, which is what the
  code does. Fix the diagram.

**Is the model right for barge-in?** With four additions, yes.

1. **INTERRUPTED needs a defined exit for every input, or it dead-ends.** PTT
   released while INTERRUPTED is ignored by `pttEnd` (it only accepts
   CAPTURING). Make INTERRUPTED a bounded transient: entry action = `abort()` +
   `tts_abort{stream, playedOffset}`; exit = the next event (hold confirmed or
   VAD speech → CAPTURING; release or timeout → IDLE). Both entry actions are
   local or fire-and-forget, so its lifetime is one event. Keep the state — it
   is useful to the UI and to tests — and record `{stream, offset}` on it.
2. **Say what starts the 300 ms clock.** In PTT mode the interrupt fires at the
   500 ms hold threshold, not at key-down: ADR-6 reserves the short press for
   the screen toggle, so stopping TTS on key-down would add a third behaviour.
   In voice mode it fires at VAD `speech_start`. M2's "TTS stops < 300 ms"
   (`plan.md:214`) should state which.
3. **Guard the echo tail.** After `abort()` the mic still carries speaker and
   AEC tail; my estimate is on the order of 100–200 ms (output latency plus
   acoustic tail) — measure on the NX1. The VAD must not re-trigger on it; the
   guard window belongs to the playback stop, not to a wall-clock state entry.
4. **Separate the speech queue from the session state.** M3 delivers speech with
   no turn. Rule needed: in IDLE → speak (enter RESPONDING); in CAPTURING,
   TRANSCRIBING or ROUTING → queue; in RESPONDING → queue or replace. That is a
   queue policy, not more states.

Also split connection state out (§2 S4). It should have exactly one edge into
the session: on transport loss, any session state → IDLE and speech aborted.

---

## 6. Security posture (ADR-5) — sound-with-caveats

**Current and planned links**

| Link | Transport | Auth | Encryption | Off-LAN reach |
| --- | --- | --- | --- | --- |
| Voice gateway | `ws://host:8765/ws` | none | none | none (LAN or Tailscale) |
| Paseo direct | `ws://host/ws` | bearer in `Sec-WebSocket-Protocol` (`xagent: PaseoDaemonClient.kt:377–381`) | none (relies on Tailscale) | Tailscale |
| Paseo relay | `wss://<relay>/ws?serverId=…` | pairing via daemon public key | X25519 + NaCl box in xagent; relay sees ciphertext | relay |

- Gateway: `websockets.serve(handle, "0.0.0.0", PORT, max_size=None)`
  (`server.py:245`); any path accepted; `hello` is optional — nothing checks a
  handshake before `ptt_start` or `tts_request` (`:207–231`). It is an open
  STT+TTS service on all interfaces. protocol.md already states the gate
  ("gateway must refuse unauthenticated streams before it leaves the LAN",
  `protocol.md:3–5`).
- App: global `android:usesCleartextTraffic="true"` (`AndroidManifest.xml:13`);
  URL in plain prefs with no secret in it (`MainActivity.kt:118–119`); LAN IP
  hardcoded (`AliceRuntime.kt:26`).

**Is the deferral structurally sound?** For the app, yes. No secret is stored
yet, the handshake is the natural auth point (`hello{auth}` or a header on the
upgrade request; `process_request` in `websockets.serve`), and cleartext can be
narrowed to LAN and the Tailscale range with a `networkSecurityConfig`. None of
this is disproportionate later. Five corrections:

**(a) Keystore arrives at M3, not M6.** The port brings the daemon bearer
password. xagent sends it in a WebSocket subprotocol header (table) and stores
it in plain `SharedPreferences("daemon")` (`xagent: LauncherScreen.kt:181`,
`:246`). The plan lists "credentials in Keystore" under §6 and risk R7 only.
From M3 on, a credential that can create, drive and archive agent sessions sits
in plaintext on a rooted device. Build a `SecretStore` interface in the M3 port
(Keystore-backed; a plain debug impl for the LAN). Cheap once, expensive as a
retrofit.

**(b) The security unit is the pair of links.** E2EE on the relay protects the
RPC leg only. The same content crosses the voice leg in clear: "tell X to …" is
spoken into the gateway, and the agent's result goes back up as `tts_request`
text. §6's acceptance test "relay E2EE confirmed by relay-side capture
(ciphertext only)" (`plan.md:249`) would pass while that content is readable on
the other socket. This is F1 restated as a security requirement.

**(c) Root-equivalent app rule.** The app holds a Magisk root grant — it execs
`su` (`SideKeyWatcher.kt:46`). Anything it loads at runtime runs where that
grant is reachable. M2/M4 add ONNX models (`app/build.gradle.kts:45`): bundle
them in the APK; no runtime fetch over an unauthenticated channel. Add it to
ADR-5 as a corollary now — one sentence.

**(d) Port the `protected` relay mode, not xagent's crypto.** Relay E2EE has two
modes: `legacy` (X25519 + NaCl box, random nonces, no replay protection) and
`protected` (Noise_NK_25519_ChaChaPoly_SHA256 with counters). Updated peers
negotiate `protected`; an old peer falls back to `legacy` only while the daemon
permits it, and a daemon can require `protected` (`paseo:
docs/relay-endpoint-security.md:5`, `:9–14`;
`packages/server/src/server/websocket/secure-relay-ingress.ts:78`). xagent's
`E2eeCrypto.kt` is the legacy construction (`crypto_box_beforenm` — `:16`) and
its `e2ee_hello` carries no `protected` field (`PaseoDaemonClient.kt:399`).
Ported as-is, Alice would depend on the daemon never enforcing `protected`. Port
`protected` with the Noise fixtures; treat `E2eeCrypto.kt` as reference, not
source.

**(e) "Daemon bearer credentials" presuppose a configured password.** With no
password hash configured, the daemon admits any client as owner (`paseo:
packages/server/src/server/session-admission-auth.ts:17–19`). Over the relay the
only gate is then possession of the pairing.

---

## 7. Where the architecture makes a milestone harder than the plan assumes

1. **M3/M5 — voice has no relay path.** M3's exit "all five intents work over
   relay" and §6's 4G-only session cannot pass as designed (§1 F1). The only
   relay-compatible carrier, a daemon plugin, is unproven.
2. **M2 — barge-in stalls behind TTS.** The global inference lock plus
   uncancellable, untracked TTS tasks mean a new utterance waits for the
   interrupted one's synthesis (§4).
3. **M2 — Opus is an app and protocol change, not a gateway item.** It needs
   real negotiation (§3 G1) and a client codec decision: MediaCodec's
   `audio/opus` encoder is optional in Android (I have not probed the NX1);
   libopus via JNI needs the NDK, which is in neither devshell
   (`flake.nix:12–19`; `tools/setup-sdk.sh:34–35`). On the gateway side PyAV
   (`av==19.0.2`) is already locked; whether its wheel carries libopus is
   unverified.
4. **M4/M5 — "always-on" is in no milestone.** M4 is costed at one week for
   openWakeWord and a power profile (`plan.md:227–229`). No milestone lists
   boot start, auto-connect, or supervision (§2). §6.5 requires "device reboot →
   fully armed within 60 s, no touch" (`plan.md:247`); today nothing starts at
   boot and nothing reconnects. Separately, Android 14+ documents that a
   `microphone`-type foreground service cannot be started from a boot-completed
   receiver without an exemption; I have not verified NX1 behaviour. If it
   applies, the service start mechanism is a design question, not a task.
5. **M2/M5 — no harness for concurrency properties.** Barge-in timing, soak and
   resume have no automated tests and no fake gateway to test against (§4).

Cross-cutting: the M3 port source is a 999-line class with plaintext credential
storage and the legacy relay mode (§2 S5, §6(a), §6(d)).

---

## Top 5 architectural risks, M2→M6

| Rank | Risk | Milestones | Why it ranks here | Cheapest point to fix |
| --- | --- | --- | --- | --- |
| 1 | Voice has no protected off-LAN path; "relay first" is false for the gateway | M3, M5 | M3 exit and §6.4 cannot pass as designed; M5 either ships cleartext audio or depends on Tailscale | Now — a time-boxed spike of the plugin carrier (F1 B2), else a plan edit for A |
| 2 | Session logic unserialised; capture has one gated sink | M2, M4, M5 | Barge-in correctness is a race across event sources and cannot be unit-tested inside an Android `object` | M2 start — S1 + S2 (my estimate: 2–3 days with JVM tests) |
| 3 | "Always-on" is unscoped; reboot-to-armed has no start path | M4, M5, §6.5 | Product-defining for a docked companion | Now — a half-day device probe (process kill, reboot) before M4 is sized |
| 4 | Protocol v0: no version, conflated ids, no abort, no session token | M2 | Breaking changes are cheapest with one server and one client | Before M2 code — cut v1, carrier-independent |
| 5 | The M3 port imports three hazards: legacy relay mode, plaintext credentials, a 999-line class | M3 | Each is cheap to avoid in the port and expensive to retrofit | In the M3 port — §6(a), §6(d), §2 S5 |

Next tier, below the top 5: the global inference lock (fix inside M2); the Opus
codec decision (§7.3); no automated tests for concurrency behaviour (§7.5);
telephony and mic exclusivity are unmodelled on a phone that must keep VoLTE
working (unverified on the NX1). ADR-2's Paseo option is not a risk once F2 is
recorded; D1.5 only affects partial transcripts.

---

## What I would NOT change

- **Service-first with one process-wide owner.** No DI framework, no modular
  Gradle refactor. The problem in §2 is responsibility, not the singleton.
- **`AliceService` as a thin foreground shell** (53 lines).
- **One voice channel with JSON-text + binary-PCM framing.** No base64, no
  RTP/WebRTC stack for v1. The 8-byte header survives Opus, and the split maps
  onto plugin frames.
- **The cascade as the v1 backend** (faster-whisper + Kokoro behind the
  gateway). F2 is the evidence.
- **`AudioEngine` as the only place that touches `AudioRecord`/`AudioTrack`,
  built full-duplex from day one.** This is the reason M2 barge-in is an
  API addition rather than an audio rework.
- **16 kHz / 20 ms uplink, PCM downlink on LAN, Opus before the 4G trial**
  (ADR-4 timing).
- **`SideKeyWatcher`'s design**: raw `event0` via `su`, duration threshold, two
  callbacks. ADR-6 is accepted and the class is isolated behind them.
- **Gateway: Python + asyncio + executor, shared `Engines` loaded once, one
  endpoint, flake devshell, pinned lock file.**
- **Deterministic grammar for M3.** No LLM router.
- **The state set in `VoiceSessionState`.** Only the mechanics change.
- **Adapted copy of the Paseo connection rather than a shared Gradle module**
  (ADR-3).
- **The plan's discipline**: protocol doc before the next milestone; latency
  instrumentation in the first working build (`Latency`, `stt_ms`, `tts_ms`).

---

## Decisions to record before M3

1. **ADR-7 — voice transport off the LAN.** Tailscale carries the gateway (A),
   or the gateway becomes a daemon plugin (B2, after a spike).
2. **ADR-2 closure.** Record F2 as D1.4's output: the cascade is the v1
   backend. D1.5 is scoped to the partial-transcript design.
3. **ADR-8 — orchestration in the app**, with optimistic acks and a speech-queue
   policy.
4. **Protocol v1, carrier-independent**: version + honoured negotiation,
   turn/stream ids, `tts_abort`, `endpoint`, session token + resume, documented
   `tts_request`.
5. **ADR-5 amendment**: Keystore with M3; `protected` relay mode; root-equivalent
   app rule; daemon password configured.
6. **Plan edits**: endpoint latency segment; M3/M5 exit criteria naming the
   voice transport; "always-on" scoped into a milestone.

---

## Appendix — incidental observations (not architectural, noticed while reading, unverified at runtime)

- `run_final` reads `self.buf` after the lock wait (`server.py:124–128`) — the
  stage-boundary point in §4.
- A `final` with empty text leaves the app in RESPONDING
  (`AliceRuntime.kt:96–102`) — the state-model point in §5.
- `SideKeyWatcher.start()` sets `running = true` after starting a reader thread
  whose loop condition is `while (running)` (`SideKeyWatcher.kt:50–57`); the
  reader can exit before the flag is set.
- After `runAecTest` the engine is left stopped while `connected` stays true, so
  PTT is dead until reconnect (`AliceRuntime.kt:254`, `:269–272`).
