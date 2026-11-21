# Voice session protocol v0 (M1)

One bidirectional WebSocket per voice session (plan §4). Transport: plain
`ws://` on LAN for M1; auth + relay/Tailscale paths come with M3 (ADR-5 —
gateway must refuse unauthenticated streams before it leaves the LAN).

- Endpoint: `ws://<gateway-host>:8765/ws`
- Text frames are JSON control messages; binary frames are raw PCM.

## Uplink (client → server)

Audio: binary frames of **PCM 16 kHz mono s16le, 20 ms = 640 bytes** (ADR-4).

| Message | Fields | Meaning |
| --- | --- | --- |
| `hello` | `sr`, `ch`, `fmt`, `t_ms` | handshake on connect; server replies `ready` or closes with reason |
| `ptt_start` | `t_ms` | capture began (PTT hold crossed 500 ms) |
| `ptt_end` | `t_ms` | capture ended → server finalizes STT |
| `cancel` | — | drop the in-flight utterance, no final/TTS |

`t_ms` = client monotonic clock (SystemClock.elapsedRealtime) — used for
client-side segment timing, never trusted as absolute time by the server.

## Downlink (server → client)

| Message | Fields | Meaning |
| --- | --- | --- |
| `ready` | `stt_model`, `tts_voice`, `sr` | gateway ready; `sr` = TTS sample rate (24000) |
| `partial` | `committed`, `tentative` | streaming partial (committed text is append-only; tentative may be revised) — M1: emitted while capturing |
| `final` | `text`, `seq`, `stt_ms` | final transcript; `seq` links to the TTS utterance; `stt_ms` = server-side ptt_end→final latency |
| `tts_start` | `seq`, `sr` | first audio chunk for `seq` follows immediately |
| `tts_end` | `seq`, `tts_ms` | TTS stream complete; `tts_ms` = final→last-chunk |
| `error` | `msg` | spoken-error path per state machine |

TTS audio: binary frames = **8-byte header + PCM payload** (native TTS rate,
mono s16le — 24 kHz for Kokoro, chunked ≥ 20 ms):

```
u32 seq    — TTS utterance number (matches final.seq)
u32 offset — byte offset of this payload within the utterance
```

Client detects drops/gaps via `offset` continuity.

## M1 semantics

The M1 gateway is an **echo responder**: `final` text → TTS speaks
`You said: <text>`. Intent routing is M3. Barge-in, VAD events, server-side
endpointing and Opus are M2/M5 extensions; message names above stay stable.

## Latency instrumentation

Client logs (all `elapsedRealtime` deltas, displayed on-screen + logcat):
`t_release` (PTT up) → `t_final` (final recv) → `t_tts_first` (first TTS
binary frame recv) → `t_play` (first byte written to AudioTrack).
Server logs `stt_ms`, `tts_ms` per utterance. Budget: plan §4 (release→final
< 500 ms; release→first spoken ack < 1.5 s LAN).
