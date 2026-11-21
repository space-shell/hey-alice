#!/usr/bin/env python3
"""hey-alice M1 voice gateway.

One WebSocket endpoint (docs/protocol.md): client streams 16 kHz mono s16le
PCM in 20 ms frames; faster-whisper produces streaming partials + final;
Kokoro speaks the reply back as sequence-numbered PCM chunks (24 kHz).

M1 semantics: echo responder ("You said: <text>"). Intent routing is M3.

Run inside the gateway devshell (flake.nix → python312 + espeak-ng):
    nix develop -c python server.py

Env knobs: STT_MODEL (default tiny.en), CT2_COMPUTE (int8), CT2_DEVICE (cpu),
KOKORO_VOICE (af_heart), PORT (8765).
"""

from __future__ import annotations

import asyncio
import json
import os
import struct
import sys
import time

import numpy as np
import websockets

SR_IN = 16_000
SR_OUT = 24_000
FRAME_BYTES = 640          # 20 ms @ 16 kHz mono s16le
TTS_CHUNK_BYTES = 960      # 20 ms @ 24 kHz mono s16le
PARTIAL_INTERVAL = 0.7     # s between partial re-transcriptions
PARTIAL_MIN_AUDIO = 0.8    # s of audio before partials start

STT_MODEL = os.environ.get("STT_MODEL", "tiny.en")
CT2_COMPUTE = os.environ.get("CT2_COMPUTE", "int8")
CT2_DEVICE = os.environ.get("CT2_DEVICE", "cpu")
KOKORO_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
PORT = int(os.environ.get("PORT", "8765"))
ECHO_PREFIX = os.environ.get("ECHO_PREFIX", "You said: ")

def log(msg: str) -> None:
    print(f"[gateway {time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Engines:
    """Shared, lazily-warmed STT/TTS. Blocking calls go through the executor."""

    def __init__(self) -> None:
        self.stt = None
        self.tts = None
        self.infer_lock = asyncio.Lock()

    async def load(self) -> None:
        loop = asyncio.get_running_loop()

        def _load_stt():
            from faster_whisper import WhisperModel
            t0 = time.perf_counter()
            m = WhisperModel(STT_MODEL, device=CT2_DEVICE, compute_type=CT2_COMPUTE)
            # warm graph: transcribe 0.5 s of silence
            m.transcribe(np.zeros(SR_IN // 2, dtype=np.float32), language="en",
                         beam_size=1, condition_on_previous_text=False)
            log(f"stt ready: {STT_MODEL}/{CT2_DEVICE}/{CT2_COMPUTE} "
                f"({time.perf_counter() - t0:.1f}s incl. warmup)")
            return m

        def _load_tts():
            from kokoro import KPipeline
            t0 = time.perf_counter()
            p = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
            next(iter(p("ready.", voice=KOKORO_VOICE, speed=1.0)))  # warm load
            log(f"tts ready: kokoro voice={KOKORO_VOICE} "
                f"({time.perf_counter() - t0:.1f}s incl. warmup)")
            return p

        self.stt = await loop.run_in_executor(None, _load_stt)
        self.tts = await loop.run_in_executor(None, _load_tts)

    def transcribe_blocking(self, pcm_f32: np.ndarray) -> str:
        segments, _info = self.stt.transcribe(
            pcm_f32, language="en", beam_size=1,
            condition_on_previous_text=False, vad_filter=False)
        return "".join(s.text for s in segments).strip()

    def synthesize_blocking(self, text: str):
        """Yield (chunk_index, int16 bytes) for each Kokoro result chunk."""
        for result in self.tts(text, voice=KOKORO_VOICE, speed=1.0):
            audio = result.audio
            if audio is None:
                continue
            arr = (np.asarray(audio, dtype=np.float32) * 32767.0).astype("<i2")
            yield arr.tobytes()


ENGINES = Engines()


class Session:
    def __init__(self, ws) -> None:
        self.ws = ws
        self.buf = bytearray()
        self.capturing = False
        self.partial_task: asyncio.Task | None = None
        self.utt_seq = 0
        self.tts_task: asyncio.Task | None = None

    # ---- helpers -------------------------------------------------------

    async def send_json(self, **msg) -> None:
        await self.ws.send(json.dumps(msg))

    @staticmethod
    def pcm_to_f32(buf: bytearray) -> np.ndarray:
        return np.frombuffer(bytes(buf), dtype="<i2").astype(np.float32) / 32768.0

    # ---- STT ------------------------------------------------------------

    async def run_final(self) -> None:
        loop = asyncio.get_running_loop()
        self.utt_seq += 1
        seq = self.utt_seq
        audio = bytes(self.buf)
        t0 = time.perf_counter()
        async with ENGINES.infer_lock:
            text = await loop.run_in_executor(
                None, ENGINES.transcribe_blocking, self.pcm_to_f32(self.buf))
        stt_ms = int((time.perf_counter() - t0) * 1000)
        log(f"utt#{seq} final ({len(audio) / 2 / SR_IN:.2f}s audio): "
            f"{text!r} stt_ms={stt_ms}")
        await self.send_json(type="final", text=text, seq=seq, stt_ms=stt_ms)
        if text:
            await self.stream_tts(ECHO_PREFIX + text, seq)

    async def run_partial(self) -> None:
        loop = asyncio.get_running_loop()
        while self.capturing and len(self.buf) >= int(PARTIAL_MIN_AUDIO * SR_IN) * 2:
            await asyncio.sleep(PARTIAL_INTERVAL - 0.05)
            if not self.capturing or len(self.buf) < int(PARTIAL_MIN_AUDIO * SR_IN) * 2:
                continue
            async with ENGINES.infer_lock:
                if not self.capturing:  # re-check under the lock
                    return
                t0 = time.perf_counter()
                text = await loop.run_in_executor(
                    None, ENGINES.transcribe_blocking, self.pcm_to_f32(self.buf))
            log(f"partial ({(time.perf_counter() - t0) * 1000:.0f} ms): {text!r}")
            await self.send_json(type="partial", committed=text, tentative="")

    # ---- TTS ------------------------------------------------------------

    async def stream_tts(self, text: str, seq: int) -> None:
        """Clause-split streaming: synthesise the first clause alone so the
        first audio chunk lands ASAP (measured: 0.75 s for 'You said:'), then
        the rest streams clause by clause behind it."""
        loop = asyncio.get_running_loop()
        import re
        clauses = [c for c in re.split(r"(?<=[.,;:!?])\s+", text) if c.strip()]
        t0 = time.perf_counter()
        first = True
        offset = 0
        async with ENGINES.infer_lock:
            for clause in clauses:
                gen = ENGINES.synthesize_blocking(clause)
                while True:
                    chunk = await loop.run_in_executor(None, lambda: next(gen, None))
                    if chunk is None:
                        break
                    if first:
                        await self.send_json(type="tts_start", seq=seq, sr=SR_OUT)
                        log(f"utt#{seq} tts first chunk "
                            f"{(time.perf_counter() - t0) * 1000:.0f} ms "
                            f"(clause {clause!r})")
                        first = False
                    for i in range(0, len(chunk), TTS_CHUNK_BYTES):
                        piece = chunk[i:i + TTS_CHUNK_BYTES]
                        await self.ws.send(struct.pack("<II", seq, offset) + piece)
                        offset += len(piece)
                        await asyncio.sleep(0)  # yield to reader
        tts_ms = int((time.perf_counter() - t0) * 1000)
        await self.send_json(type="tts_end", seq=seq, tts_ms=tts_ms)
        log(f"utt#{seq} tts_end tts_ms={tts_ms}")

    # ---- control ---------------------------------------------------------

    def cancel_inflight(self) -> None:
        if self.partial_task and not self.partial_task.done():
            self.partial_task.cancel()
            self.partial_task = None


async def handle(ws) -> None:
    session = Session(ws)
    peer = getattr(ws, "remote_address", ("?", 0))
    log(f"connect from {peer}")
    try:
        async for message in ws:
            if isinstance(message, (bytes, bytearray)):
                if session.capturing:
                    session.buf.extend(message)
                continue

            msg = json.loads(message)
            mtype = msg.get("type")

            if mtype == "hello":
                await session.send_json(type="ready", stt_model=STT_MODEL,
                                        tts_voice=KOKORO_VOICE, sr=SR_OUT)

            elif mtype == "ptt_start":
                session.buf = bytearray()
                session.capturing = True
                session.cancel_inflight()
                session.partial_task = asyncio.create_task(session.run_partial())

            elif mtype == "ptt_end":
                session.capturing = False
                session.cancel_inflight()
                asyncio.create_task(session.run_final())

            elif mtype == "cancel":
                session.capturing = False
                session.cancel_inflight()
                session.buf = bytearray()

            elif mtype == "tts_request":
                session.utt_seq += 1
                seq = session.utt_seq
                log(f"tts_request seq={seq}: {msg.get('text', '')!r}")
                asyncio.create_task(session.stream_tts(msg.get("text", ""), seq))

            else:
                await session.send_json(type="error", msg=f"unknown type {mtype!r}")

    except websockets.ConnectionClosed:
        pass
    finally:
        session.cancel_inflight()
        log(f"disconnect {peer}")


async def main() -> None:
    await ENGINES.load()
    async with websockets.serve(handle, "0.0.0.0", PORT, max_size=None):
        log(f"listening on :{PORT} (ws://<host>:{PORT}/ws — any path accepted)")
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
