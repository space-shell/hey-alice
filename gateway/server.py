#!/usr/bin/env python3
"""hey-alice voice gateway.

One channel per voice session (docs/protocol.md v1): client streams 16 kHz
mono s16le PCM in 20 ms frames; faster-whisper produces streaming partials +
final; Kokoro speaks the reply back as stream-numbered PCM chunks (24 kHz).

M1/M2 semantics: echo responder ("You said: <text>"). Intent routing is M3
(ADR-8: in the app).

Concurrency model (review §4 fixes, tracker C1):
- two inference locks (stt_lock / tts_lock) — TTS no longer waits behind STT
  or vice versa;
- per-connection writer task: ALL sends go through one queue, so partial/final/
  TTS tasks never call ws.send concurrently; aborted streams' queued frames are
  dropped by the writer;
- TTS tasks are tracked per stream and cancellable: barge-in (ptt_start) and
  tts_abort{stream} stop synthesis; tts_aborted{stream, offset} is replied.

Run inside the gateway devshell (flake.nix → python312 + espeak-ng):
    nix develop -c python server.py

Env knobs: STT_MODEL (default tiny.en), CT2_COMPUTE (int8), CT2_DEVICE (cpu),
KOKORO_VOICE (af_heart), PORT (8765), ECHO_PREFIX ("You said: ").
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import struct
import time
import uuid

import numpy as np
import websockets

PROTOCOL_VERSION = 1

SR_IN = 16_000
SR_OUT = 24_000
FRAME_BYTES = 640          # 20 ms @ 16 kHz mono s16le
TTS_CHUNK_BYTES = 960      # 20 ms @ 24 kHz mono s16le
PARTIAL_INTERVAL = 0.7     # s between partial re-transcriptions
PARTIAL_MIN_AUDIO = 0.8    # s of audio before partials start
OUT_QUEUE_MAX = 4096       # per-connection writer queue depth

STT_MODEL = os.environ.get("STT_MODEL", "tiny.en")
CT2_COMPUTE = os.environ.get("CT2_COMPUTE", "int8")
CT2_DEVICE = os.environ.get("CT2_DEVICE", "cpu")
KOKORO_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
PORT = int(os.environ.get("PORT", "8765"))
ECHO_PREFIX = os.environ.get("ECHO_PREFIX", "You said: ")

def log(msg: str) -> None:
    print(f"[gateway {time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Engines:
    """Shared, lazily-warmed STT/TTS. Blocking calls go through the executor.

    Separate locks: STT and TTS inference are independent hardware/software
    pipelines; sharing one lock made a barge-in utterance wait behind the
    interrupted utterance's synthesis (review §4)."""

    def __init__(self) -> None:
        self.stt = None
        self.tts = None
        self.stt_lock = asyncio.Lock()
        self.tts_lock = asyncio.Lock()

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
        """Yield int16 bytes for each Kokoro result chunk."""
        for result in self.tts(text, voice=KOKORO_VOICE, speed=1.0):
            audio = result.audio
            if audio is None:
                continue
            arr = (np.asarray(audio, dtype=np.float32) * 32767.0).astype("<i2")
            yield arr.tobytes()


ENGINES = Engines()

# session tokens → counters, for resume within this process lifetime
SESSION_TOKENS: dict[str, dict[str, int]] = {}


class Session:
    def __init__(self, ws, peer) -> None:
        self.ws = ws
        self.peer = peer
        self.pv = 0                      # negotiated protocol version (0 = v0)
        self.buf = bytearray()
        self.capturing = False
        self.partial_task: asyncio.Task | None = None
        self.final_task: asyncio.Task | None = None
        self.turn = 0                    # utterance counter (v0: "seq")
        self.stream = 0                  # tts stream counter
        self.tts_tasks: dict[int, asyncio.Task] = {}
        self.tts_offset: dict[int, int] = {}
        self.aborted: set[int] = set()
        self.token = uuid.uuid4().hex[:12]
        self.out: asyncio.Queue = asyncio.Queue(maxsize=OUT_QUEUE_MAX)
        self.writer_task: asyncio.Task | None = None
        self.closed = False

    # ---- writer: the ONLY task that touches ws.send ---------------------

    async def writer(self) -> None:
        while True:
            item = await self.out.get()
            if item is None:          # shutdown sentinel
                return
            kind = item[0]
            if kind == "bin":
                _, stream, data = item
                if stream in self.aborted:
                    continue          # drop queued frames of aborted streams
            else:
                data = item[1]
            try:
                await self.ws.send(data)
            except websockets.ConnectionClosed:
                return                # client gone mid-drain (normal close)

    async def put_json(self, **msg) -> None:
        if not self.closed:
            await self.out.put(("json", json.dumps(msg)))

    async def put_binary(self, stream: int, data: bytes) -> None:
        if not self.closed:
            await self.out.put(("bin", stream, data))

    # ---- id/field helpers -----------------------------------------------

    def seq_field(self) -> str:
        """v0 sessions speak 'seq'; v1 sessions speak 'turn'/'stream'."""
        return "seq" if self.pv == 0 else "turn"

    @staticmethod
    def pcm_to_f32(buf: bytes) -> np.ndarray:
        return np.frombuffer(buf, dtype="<i2").astype(np.float32) / 32768.0

    # ---- STT ------------------------------------------------------------

    async def run_final(self, audio: bytes) -> None:
        """Transcribe the SNAPSHOT taken at ptt_end (never re-read self.buf —
        a new ptt_start resets it mid-transcription otherwise, review F1)."""
        loop = asyncio.get_running_loop()
        self.turn += 1
        seq = self.turn
        SESSION_TOKENS[self.token] = {"turn": self.turn, "stream": self.stream}
        if len(audio) < FRAME_BYTES:
            await self.put_json(type="final",
                                **{self.seq_field(): seq},
                                text="", stt_ms=0)
            log(f"utt#{seq} final: empty capture ({len(audio)} B), skipped STT")
            return
        t0 = time.perf_counter()
        async with ENGINES.stt_lock:
            text = await loop.run_in_executor(
                None, ENGINES.transcribe_blocking, self.pcm_to_f32(audio))
        stt_ms = int((time.perf_counter() - t0) * 1000)
        log(f"utt#{seq} final ({len(audio) / 2 / SR_IN:.2f}s audio): "
            f"{text!r} stt_ms={stt_ms}")
        await self.put_json(type="final",
                            **{self.seq_field(): seq},
                            text=text, stt_ms=stt_ms)
        if text:
            self.stream += 1
            await self.stream_tts(ECHO_PREFIX + text, self.turn, self.stream)

    async def run_partial(self) -> None:
        loop = asyncio.get_running_loop()
        while self.capturing and len(self.buf) >= int(PARTIAL_MIN_AUDIO * SR_IN) * 2:
            await asyncio.sleep(PARTIAL_INTERVAL - 0.05)
            snapshot = bytes(self.buf)          # snapshot for this pass
            if not self.capturing or len(snapshot) < int(PARTIAL_MIN_AUDIO * SR_IN) * 2:
                continue
            async with ENGINES.stt_lock:
                if not self.capturing:  # re-check under the lock
                    return
                t0 = time.perf_counter()
                text = await loop.run_in_executor(
                    None, ENGINES.transcribe_blocking, self.pcm_to_f32(snapshot))
            log(f"partial ({(time.perf_counter() - t0) * 1000:.0f} ms): {text!r}")
            await self.put_json(type="partial", committed=text, tentative="")

    # ---- TTS ------------------------------------------------------------

    async def stream_tts(self, text: str, turn: int, stream: int) -> None:
        """Clause-split streaming: synthesise the first clause alone so the
        first audio chunk lands ASAP, then the rest streams clause by clause.
        Cancellation (barge-in / tts_abort) is honoured between chunks; the
        aborting side sends tts_aborted."""
        loop = asyncio.get_running_loop()
        clauses = [c for c in re.split(r"(?<=[.,;:!?])\s+", text) if c.strip()]
        t0 = time.perf_counter()
        offset = 0
        self.tts_offset[stream] = 0
        first = True
        try:
            async with ENGINES.tts_lock:
                for clause in clauses:
                    gen = ENGINES.synthesize_blocking(clause)
                    while True:
                        chunk = await loop.run_in_executor(None, lambda: next(gen, None))
                        if chunk is None:
                            break
                        if stream in self.aborted:
                            return
                        if first:
                            msg = {"type": "tts_start", "sr": SR_OUT,
                                   "turn": turn, "stream": stream}
                            if self.pv == 0:
                                msg["seq"] = turn
                            await self.put_json(**msg)
                            log(f"utt#{turn} tts first chunk "
                                f"{(time.perf_counter() - t0) * 1000:.0f} ms "
                                f"(clause {clause!r})")
                            first = False
                        for i in range(0, len(chunk), TTS_CHUNK_BYTES):
                            piece = chunk[i:i + TTS_CHUNK_BYTES]
                            header = struct.pack("<II", stream, offset)
                            await self.put_binary(stream, header + piece)
                            offset += len(piece)
                            self.tts_offset[stream] = offset
                            await asyncio.sleep(0)  # yield to reader/writer
        except asyncio.CancelledError:
            log(f"stream#{stream} cancelled at offset {offset}")
            raise
        finally:
            self.tts_tasks.pop(stream, None)
            self.tts_offset.pop(stream, None)
        tts_ms = int((time.perf_counter() - t0) * 1000)
        msg = {"type": "tts_end", "tts_ms": tts_ms, "turn": turn, "stream": stream}
        if self.pv == 0:
            msg["seq"] = turn
        await self.put_json(**msg)
        log(f"utt#{turn} tts_end tts_ms={tts_ms}")

    # ---- control ----------------------------------------------------------

    def cancel_tts(self, stream: int | None = None) -> list[tuple[int, int]]:
        """Cancel tracked TTS tasks (all, or one stream). Returns
        [(stream, offset_reached)] for the cancelled streams."""
        cancelled = []
        targets = list(self.tts_tasks.items()) if stream is None else [
            (stream, t) for s, t in self.tts_tasks.items() if s == stream]
        for s, task in targets:
            offset = self.tts_offset.get(s, 0)
            self.aborted.add(s)
            if task and not task.done():
                task.cancel()
            self.tts_tasks.pop(s, None)
            cancelled.append((s, offset))
        return cancelled

    def cancel_partial(self) -> None:
        if self.partial_task and not self.partial_task.done():
            self.partial_task.cancel()
            self.partial_task = None

    def cancel_all(self) -> None:
        self.cancel_partial()
        self.cancel_tts()
        if self.final_task and not self.final_task.done():
            self.final_task.cancel()
            self.final_task = None


SESSION: Session | None = None   # single active session for log/ref clarity


async def handle(ws) -> None:
    global SESSION
    session = Session(ws, getattr(ws, "remote_address", ("?", 0)))
    SESSION = session
    session.writer_task = asyncio.create_task(session.writer())
    log(f"connect from {session.peer} (token {session.token})")
    try:
        async for message in ws:
            if isinstance(message, (bytes, bytearray)):
                if session.capturing:
                    session.buf.extend(message)
                continue

            msg = json.loads(message)
            mtype = msg.get("type")

            if mtype == "hello":
                v = int(msg.get("v", 0))
                if v > PROTOCOL_VERSION:
                    await session.put_json(type="error",
                        msg=f"protocol v{v} unsupported (server speaks v{PROTOCOL_VERSION})")
                    break
                session.pv = v
                await session.put_json(type="ready", v=PROTOCOL_VERSION,
                    stt_model=STT_MODEL, tts_voice=KOKORO_VOICE, sr=SR_OUT,
                    session_token=session.token)
                log(f"hello: client protocol v{v} → serving v{PROTOCOL_VERSION}")

            elif mtype == "resume":
                token = msg.get("session_token", "")
                saved = SESSION_TOKENS.get(token)
                if saved:
                    session.turn = saved["turn"]
                    session.stream = saved["stream"]
                    session.token = token
                    await session.put_json(type="resumed",
                        turn=session.turn, stream=session.stream)
                    log(f"resume: counters restored (turn {session.turn})")
                else:
                    await session.put_json(type="error", msg="unknown token — fresh session")

            elif mtype == "ptt_start":
                # barge-in: cancel in-flight TTS + partial, reply tts_aborted
                for s, offset in session.cancel_tts():
                    await session.put_json(type="tts_aborted", stream=s, offset=offset,
                                           **({session.seq_field(): s}))
                session.cancel_partial()
                session.buf = bytearray()
                session.capturing = True
                session.partial_task = asyncio.create_task(session.run_partial())

            elif mtype == "ptt_end":
                if not session.capturing:
                    continue
                session.capturing = False
                session.cancel_partial()
                audio = bytes(session.buf)      # snapshot NOW (F1 fix)
                session.buf = bytearray()
                session.final_task = asyncio.create_task(session.run_final(audio))

            elif mtype == "cancel":
                session.capturing = False
                session.cancel_all()

            elif mtype == "tts_abort":
                s = int(msg.get("stream", -1))
                for cs, offset in session.cancel_tts(s):
                    await session.put_json(type="tts_aborted", stream=cs, offset=offset,
                                           **({session.seq_field(): cs}))
                    log(f"tts_abort: stream#{cs} aborted at offset {offset}")

            elif mtype == "tts_request":
                session.turn += 1
                turn = session.turn
                session.stream += 1
                stream = session.stream
                text = msg.get("text", "")
                log(f"tts_request: turn#{turn} stream#{stream}: {text!r}")
                task = asyncio.create_task(session.stream_tts(text, turn, stream))
                session.tts_tasks[stream] = task

            else:
                await session.put_json(type="error", msg=f"unknown type {mtype!r}")

    except websockets.ConnectionClosed:
        pass
    finally:
        session.closed = True
        session.cancel_all()
        SESSION_TOKENS[session.token] = {"turn": session.turn, "stream": session.stream}
        await session.out.put(None)          # writer shutdown sentinel
        if session.writer_task:
            try:
                await asyncio.wait_for(session.writer_task, 2)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                session.writer_task.cancel()
        log(f"disconnect {session.peer}")


async def main() -> None:
    await ENGINES.load()
    async with websockets.serve(handle, "0.0.0.0", PORT, max_size=None):
        log(f"listening on :{PORT} (protocol v{PROTOCOL_VERSION}; "
            f"ws://<host>:{PORT}/ws — any path accepted)")
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        import sys
        sys.exit(0)
