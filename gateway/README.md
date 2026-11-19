# Voice gateway

Server-side speech pipeline for Alice (plan M1/M2). One bidirectional WebSocket
per voice session — protocol contract in [`../docs/plan.md`](../docs/plan.md) §4.

- **Transport**: framed 20 ms audio (client→server), partial/final transcripts,
  agent events, sequence-numbered TTS chunks (server→client).
- **VAD**: server-side Silero endpointing; server is the segmentation source of truth.
- **Barge-in**: client VAD gates mic during TTS; explicit barge-in signal.
- **Backends** (ADR-2, decided by D1.4/D1.5 numbers): Paseo speech pipeline, z.ai
  realtime speech model, or faster-whisper + Kokoro cascade (default baseline).
  Backends are swappable behind the one protocol.

Status: devshell scaffolded. Implementation starts at M1 — before building from
scratch, audit the owner's existing projects for reusable pieces:
`~/projects/dictation-transcription`, `~/projects/nemotron-voice-input`,
`~/projects/talk-journal`.
