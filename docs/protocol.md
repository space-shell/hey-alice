# Voice session protocol v1 (M2)

One bidirectional channel per voice session (plan §4). **v1 is defined at the
message level, deliberately independent of the carrier**: today the carrier is
one plain `ws://` WebSocket; from M3 the same messages may ride a daemon-plugin
binary frame channel (ADR-7 context). Only §Framing is carrier-specific.

- Endpoint (WS carrier): `ws://<gateway-host>:8765/ws` (any path accepted)
- Text frames are JSON control messages; binary frames are raw PCM.
- **Versioning**: the client sends its protocol version in `hello.v`; the server
  replies `ready.v` with the highest version it will speak. If the client's
  major version exceeds the server's, the server sends `error` and closes.
  A v0 client (M1 build, no `v` field) is served in v0 compatibility mode:
  v1 field names `turn`/`stream` degrade to v0's single `seq` (server keeps
  `stream == turn` for those sessions; the binary header layout is unchanged).
  All v1-only messages (`resume`, `tts_abort`) are simply never sent by v0 clients.

## Framing (WS carrier)

- Uplink audio: **PCM 16 kHz mono s16le, 20 ms = 640 bytes** (ADR-4).
- Downlink audio: **8-byte header + PCM payload** (native TTS rate, mono s16le —
  24 kHz for Kokoro, chunked ≥ 20 ms):

```
u32 stream — TTS stream id (see ids below)
u32 offset — byte offset of this payload within the stream
```

The client detects drops via `offset` continuity. On `tts_abort`, the server
stops synthesising AND stops queueing frames of that stream; frames already in
flight may still arrive and are discarded by the client after `tts_aborted`.

## Ids

- **turn** — one captured utterance (ptt_start → ptt_end), monotonically
  increasing per session. v0 called this `seq` on `final`.
- **stream** — one TTS stream. v1 allocates one stream per turn today (echo
  gateway), so `stream == turn` in practice, but clients must treat them as
  independent: barge-in aborts a stream, never a turn.

## Uplink (client → server)

| Message | Fields | Meaning |
| --- | --- | --- |
| `hello` | `v`, `sr`, `ch`, `fmt`, `t_ms` | handshake on connect; server replies `ready` or `error` + close |
| `resume` | `session_token` | reconnect: server restores turn/stream counters if it recognises the token (this process lifetime), replies `resumed`; otherwise replies `error{msg:"unknown token"}` and the session continues fresh. v1 does NOT replay missed audio/TTS — offset continuity still exposes gaps |
| `ptt_start` | `t_ms` | capture began (PTT hold crossed 500 ms). **Barge-in semantics: cancels all in-flight TTS streams** (each cancelled stream gets `tts_aborted`) |
| `ptt_end` | `t_ms` | capture ended → server finalizes STT |
| `cancel` | — | drop the in-flight utterance and all in-flight TTS |
| `tts_request` | `text`, `t_ms` | server-side synthesis of arbitrary text (used by the D1.3 AEC probe; M3 acks will use it) — allocates a new turn + stream |
| `tts_abort` | `stream` | stop synthesising/streaming that stream; server replies `tts_aborted{stream, offset}` with the byte offset reached |

`t_ms` = client monotonic clock (SystemClock.elapsedRealtime) — used for
client-side segment timing, never trusted as absolute time by the server.

## Downlink (server → client)

| Message | Fields | Meaning |
| --- | --- | --- |
| `ready` | `v`, `stt_model`, `tts_voice`, `sr`, `session_token` | gateway ready; `sr` = TTS sample rate (24000); token for `resume` |
| `resumed` | `turn`, `stream` | counters restored after `resume` |
| `endpoint` | `t_ms` | server VAD detected end-of-speech during capture (**defined in v1; emitted once server-side Silero lands — M2**) |
| `partial` | `committed`, `tentative` | streaming partial (committed is append-only; tentative may be revised) — emitted while capturing |
| `final` | `turn`, `text`, `stt_ms` | final transcript; `stt_ms` = server-side ptt_end→final latency |
| `tts_start` | `turn`, `stream`, `sr` | first audio chunk for `stream` follows immediately |
| `tts_end` | `turn`, `stream`, `tts_ms` | TTS stream complete; `tts_ms` = final→last-chunk |
| `tts_aborted` | `stream`, `offset` | stream cancelled (barge-in or `tts_abort`); `offset` = last byte synthesised/sent |
| `error` | `msg` | spoken-error path per state machine |

v0 compatibility mapping: `final.seq` ↔ `final.turn`; `tts_*.seq` ↔
`tts_*.turn` (server emits v0 names to v0 sessions; `session_token` appears in
v0 `ready` too — unknown fields are ignored by v0 clients).

## Auth (planned, M3 per ADR-5)

`hello` gains `auth{token}` or the token rides the WS upgrade request; the
gateway refuses unauthenticated streams before it leaves the LAN. Reserved now,
implemented with the M3 SecretStore work (tracker E1/E4).

## Semantics

- M1/M2 gateway is an **echo responder**: `final` text → TTS speaks
  `You said: <text>` (ECHO_PREFIX). Intent routing is M3 (ADR-8: in the app).
- Barge-in: `ptt_start` while TTS is playing cancels the streams; the target is
  TTS silence < 300 ms after the 500 ms hold threshold (plan §4 budget).

## Latency instrumentation

Client logs (all `elapsedRealtime` deltas, displayed on-screen + logcat):
`t_release` (PTT up) → `t_final` (final recv) → `t_tts_first` (first TTS
binary frame recv) → `t_play` (first byte written to AudioTrack).
Server logs `stt_ms`, `tts_ms` per utterance. Budget: plan §4 (release→final
< 500 ms; release→first spoken ack < 1.5 s LAN; barge-in stop < 300 ms).
