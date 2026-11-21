#!/usr/bin/env python3
"""Standalone gateway test client (no phone needed).

Modes:
  --tts-wav TEXT --out F.wav   one-shot: synthesize TEXT via tts_request, save PCM
  --wav F.wav [--realtime]     full loop: stream 16 kHz mono s16le WAV as PTT,
                               print partials/final, save spoken reply + timings

Runs in the gateway devshell. The WAV fed in must be 16 kHz mono s16le (the
same format the app sends); the WAVs saved out are 24 kHz mono s16le.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import struct
import sys
import time
import wave

import websockets

SR_IN = 16_000
FRAME_BYTES = 640  # 20 ms


def read_wav(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        assert w.getframerate() == SR_IN and w.getnchannels() == 1 \
            and w.getsampwidth() == 2, \
            f"need 16 kHz mono s16le, got {w.getframerate()}Hz " \
            f"{w.getnchannels()}ch {w.getsampwidth() * 8}bit"
        return w.readframes(w.getnframes())


def write_wav(path: str, pcm: bytes, sr: int) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)


async def collect_tts(ws, expected_seq: int, out_path: str, t0: float,
                      until_tts_end: bool = True) -> float:
    """Receive tts_start/chunks/tts_end for expected_seq; save WAV; return
    seconds from t0 to first chunk."""
    pcm = bytearray()
    sr = 24_000
    first_chunk_at = None
    async for raw in ws:
        if isinstance(raw, (bytes, bytearray)):
            seq, offset = struct.unpack_from("<II", raw, 0)
            assert seq == expected_seq, f"chunk seq {seq} != {expected_seq}"
            assert offset == len(pcm), f"offset gap {offset} != {len(pcm)}"
            pcm.extend(raw[8:])
            if first_chunk_at is None:
                first_chunk_at = time.perf_counter() - t0
        else:
            msg = json.loads(raw)
            if msg.get("type") == "tts_start" and msg.get("seq") == expected_seq:
                sr = msg.get("sr", 24_000)
            elif msg.get("type") == "tts_end" and msg.get("seq") == expected_seq:
                if until_tts_end:
                    break
            elif msg.get("type") == "error":
                print(f"server error: {msg.get('msg')}", file=sys.stderr)
                break
    write_wav(out_path, bytes(pcm), sr)
    assert first_chunk_at is not None, "no TTS audio received"
    return first_chunk_at


async def tts_wav_mode(args) -> None:
    async with websockets.connect(args.url, max_size=None) as ws:
        await ws.send(json.dumps({"type": "hello", "sr": SR_IN, "ch": 1,
                                  "fmt": "s16le", "t_ms": 0}))
        await ws.recv()  # ready
        t0 = time.perf_counter()
        await ws.send(json.dumps({"type": "tts_request", "text": args.tts_wav}))
        first = await collect_tts(ws, 1, args.out, t0)
        print(f"tts first chunk {first * 1000:.0f} ms -> {args.out}")


async def loop_mode(args) -> None:
    pcm = read_wav(args.wav)
    n_frames = len(pcm) // FRAME_BYTES
    async with websockets.connect(args.url, max_size=None) as ws:
        await ws.send(json.dumps({"type": "hello", "sr": SR_IN, "ch": 1,
                                  "fmt": "s16le", "t_ms": 0}))
        ready = json.loads(await ws.recv())
        print(f"ready: {ready}")

        t_start = time.perf_counter()
        await ws.send(json.dumps({"type": "ptt_start", "t_ms": 0}))
        for i in range(n_frames):
            await ws.send(pcm[i * FRAME_BYTES:(i + 1) * FRAME_BYTES])
            if args.realtime:
                await asyncio.sleep(0.02)
        await ws.send(json.dumps({"type": "ptt_end", "t_ms": 0}))
        t_release = time.perf_counter() - t_start
        print(f"streamed {n_frames} frames ({n_frames * 0.02:.2f}s audio) "
              f"in {t_release:.2f}s")

        reply = bytearray()
        final = None
        seq = None
        sr = 24_000
        t_final = t_first = None
        rel0 = time.perf_counter()
        async for raw in ws:
            if isinstance(raw, (bytes, bytearray)):
                _seq, offset = struct.unpack_from("<II", raw, 0)
                assert offset == len(reply)
                reply.extend(raw[8:])
                if t_first is None:
                    t_first = time.perf_counter() - rel0
            else:
                msg = json.loads(raw)
                mtype = msg.get("type")
                if mtype == "partial":
                    print(f"  partial: {msg.get('committed')!r}")
                elif mtype == "final":
                    final = msg
                    seq = msg["seq"]
                    t_final = time.perf_counter() - rel0
                    print(f"  FINAL ({msg['stt_ms']} ms server): "
                          f"{msg['text']!r} @ +{t_final * 1000:.0f} ms client")
                elif mtype == "tts_start":
                    sr = msg.get("sr", 24_000)
                elif mtype == "tts_end":
                    break
                elif mtype == "error":
                    print(f"server error: {msg.get('msg')}", file=sys.stderr)
                    break

        assert final is not None, "no final received"
        write_wav(args.out, bytes(reply), sr)
        total = time.perf_counter() - rel0
        print(f"reply WAV {len(reply)} B @ {sr} Hz -> {args.out}")
        print(f"LATENCY release->final {t_final * 1000:.0f} ms (budget 500) | "
              f"release->first-chunk {t_first * 1000:.0f} ms | "
              f"total {total * 1000:.0f} ms")


async def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="ws://127.0.0.1:8765/ws")
    p.add_argument("--wav", help="16 kHz mono s16le WAV to stream as PTT")
    p.add_argument("--tts-wav", help="synthesize this text, save PCM, exit")
    p.add_argument("--out", default="reply.wav")
    p.add_argument("--realtime", action="store_true",
                   help="pace frames at 20 ms (default: blast)")
    args = p.parse_args()
    if args.tts_wav:
        await tts_wav_mode(args)
    elif args.wav:
        await loop_mode(args)
    else:
        p.error("need --wav or --tts-wav")


if __name__ == "__main__":
    asyncio.run(main())
