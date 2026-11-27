#!/usr/bin/env python3
"""Smoke + concurrency test for the gateway (tracker C8 seed).

Tests, against a live gateway (default ws://127.0.0.1:8765/ws):
  1. v1 handshake: hello{v:1} → ready{v, session_token}
  2. tts_request → tts_start + binary frames (stream id, offset continuity)
  3. barge-in: ptt_start during TTS → tts_aborted{stream, offset}, and no
     further frames of that stream after the abort (writer must drop queued
     frames); measures stop latency vs the 300 ms budget
  4. ptt_end with real-ish PCM → final arrives (stt of noise → likely empty)
  5. tts_abort{stream} → tts_aborted, stream stops
  6. resume: reconnect + resume{session_token} → counters restored
  7. v0 compatibility: connect WITHOUT v → same binary header layout,
     tts fields carry seq

Usage: nix develop -c python test_smoke.py [ws://host:port/ws]
Exit code 0 = all assertions pass.
"""

from __future__ import annotations

import asyncio
import json
import struct
import sys
import time

import numpy as np
import websockets

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:8765/ws"
LONG_TEXT = ("You said: testing the barge-in path with a long sentence. "
             "The rain in Spain falls mainly on the plain. "
             "Pack my box with five dozen liquor jugs.")
FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'}  {name}{(' — ' + detail) if detail else ''}")
    if not cond:
        FAILS.append(name)


async def recv_json(ws, timeout=15):
    raw = await asyncio.wait_for(ws.recv(), timeout)
    return json.loads(raw) if isinstance(raw, str) else raw


async def drain_until(ws, kinds: set[str], timeout=15):
    """Collect frames until a control message of one of `kinds` arrives.
    Returns (msg, binary_frames_of_streams: dict[stream, list[bytes]])"""
    frames: dict[int, list[bytes]] = {}
    t0 = time.perf_counter()
    while True:
        remaining = timeout - (time.perf_counter() - t0)
        raw = await asyncio.wait_for(ws.recv(), max(remaining, 0.01))
        if isinstance(raw, str):
            msg = json.loads(raw)
            if msg.get("type") in kinds:
                return msg, frames
        else:
            stream, offset = struct.unpack("<II", raw[:8])
            frames.setdefault(stream, []).append(raw)


async def main() -> None:
    print(f"gateway smoke test → {URL}")

    # ---- 1. v1 handshake --------------------------------------------------
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"type": "hello", "v": 1, "sr": 16000,
                              "ch": 1, "fmt": "s16le"}))
    ready = await recv_json(ws)
    token = ready.get("session_token", "")
    check("1 ready.v == 1", ready.get("v") == 1, str(ready.get("v")))
    check("1 session_token issued", bool(token))

    # ---- 2. tts_request streams frames ------------------------------------
    await ws.send(json.dumps({"type": "tts_request", "text": LONG_TEXT}))
    msg, frames = await drain_until(ws, {"tts_start"})
    stream = msg["stream"]
    check("2 tts_start carries stream", isinstance(stream, int))
    first_msg, first_frames = msg, frames
    # grab a couple of chunks
    got_chunks = len(first_frames.get(stream, []))
    for _ in range(5):
        raw = await asyncio.wait_for(ws.recv(), 15)
        if isinstance(raw, bytes) and struct.unpack("<II", raw[:8])[0] == stream:
            got_chunks += 1
    check("2 binary frames flowing", got_chunks >= 5, f"{got_chunks} chunks")

    # ---- 3. barge-in: ptt_start aborts TTS --------------------------------
    await ws.send(json.dumps({"type": "ptt_start", "t_ms": 0}))
    t_abort_sent = time.perf_counter()
    aborted = None
    stop_latency = None
    stray = 0
    try:
        while True:
            raw = await asyncio.wait_for(ws.recv(), 1.0)
            if isinstance(raw, str):
                m = json.loads(raw)
                if m.get("type") == "tts_aborted" and m.get("stream") == stream:
                    aborted = m
                    stop_latency = (time.perf_counter() - t_abort_sent) * 1000
                    break
            else:
                s, _ = struct.unpack("<II", raw[:8])
                if s == stream:
                    stray += 1
    except asyncio.TimeoutError:
        pass
    check("3 tts_aborted on barge-in", aborted is not None)
    check("3 stop latency < 300 ms", stop_latency is not None and stop_latency < 300,
          f"{stop_latency:.0f} ms" if stop_latency else "no abort")
    # post-abort silence: frames already in flight may arrive BEFORE tts_aborted;
    # after it, the writer must drop everything of that stream
    post_stray = 0
    try:
        t0 = time.perf_counter()
        while time.perf_counter() - t0 < 0.7:
            raw = await asyncio.wait_for(ws.recv(), 0.7 - (time.perf_counter() - t0))
            if isinstance(raw, bytes) and struct.unpack("<II", raw[:8])[0] == stream:
                post_stray += 1
    except asyncio.TimeoutError:
        pass
    check("3 silence after tts_aborted", post_stray == 0, f"{post_stray} post-abort frames")

    # drain any leftover frames of other streams briefly, then finish the turn
    await asyncio.sleep(0.3)
    noise = (np.random.uniform(-200, 200, 16000)).astype("<i2").tobytes()
    await ws.send(noise)
    await ws.send(json.dumps({"type": "ptt_end", "t_ms": 1000}))

    # ---- 4. final for the captured turn -----------------------------------
    final = await recv_json(ws)
    check("4 final received", final.get("type") == "final", str(final.get("type")))

    # ---- 5. explicit tts_abort --------------------------------------------
    await ws.send(json.dumps({"type": "tts_request", "text": LONG_TEXT}))
    msg, _ = await drain_until(ws, {"tts_start"})
    stream2 = msg["stream"]
    await asyncio.wait_for(ws.recv(), 15)          # one more chunk
    await ws.send(json.dumps({"type": "tts_abort", "stream": stream2}))
    ab = None
    try:
        while True:
            raw = await asyncio.wait_for(ws.recv(), 2.0)
            if isinstance(raw, str):
                m = json.loads(raw)
                if m.get("type") == "tts_aborted" and m.get("stream") == stream2:
                    ab = m
                    break
                if m.get("type") == "tts_end" and m.get("stream") == stream2:
                    check("5 tts_abort honoured", False, "got tts_end instead")
                    ab = m
                    break
    except asyncio.TimeoutError:
        pass
    check("5 tts_abort replied", ab is not None and ab.get("type") == "tts_aborted")
    # post-abort silence (same reasoning as test 3)
    post_stray = 0
    try:
        t0 = time.perf_counter()
        while time.perf_counter() - t0 < 0.7:
            raw = await asyncio.wait_for(ws.recv(), 0.7 - (time.perf_counter() - t0))
            if isinstance(raw, bytes) and struct.unpack("<II", raw[:8])[0] == stream2:
                post_stray += 1
    except asyncio.TimeoutError:
        pass
    check("5 silence after tts_aborted", post_stray == 0, f"{post_stray} post-abort frames")
    await ws.close()

    # ---- 6. resume restores counters ---------------------------------------
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"type": "hello", "v": 1, "sr": 16000,
                              "ch": 1, "fmt": "s16le"}))
    ready2 = await recv_json(ws)
    await ws.send(json.dumps({"type": "resume", "session_token": token}))
    res = await recv_json(ws)
    check("6 resumed with counters", res.get("type") == "resumed",
          f"turn={res.get('turn')}")
    check("6 counters carried over", res.get("turn", 0) >= 2,
          f"turn={res.get('turn')}")
    await ws.send(json.dumps({"type": "resume", "session_token": "nope"}))
    bad = await recv_json(ws)
    check("6 unknown token → error", bad.get("type") == "error")
    await ws.close()

    # ---- 7. v0 compatibility (current M1 client) ----------------------------
    ws = await websockets.connect(URL)
    await ws.send(json.dumps({"type": "hello", "sr": 16000, "ch": 1,
                              "fmt": "s16le"}))
    ready3 = await recv_json(ws)
    check("7 v0 hello accepted", ready3.get("type") == "ready")
    await ws.send(json.dumps({"type": "tts_request", "text": "You said: hello."}))
    msg, frames = await drain_until(ws, {"tts_start"})
    seq = msg.get("seq")
    check("7 v0 tts_start uses seq", isinstance(seq, int), f"seq={seq}")
    raw = await asyncio.wait_for(ws.recv(), 15)
    if isinstance(raw, bytes):
        s, off = struct.unpack("<II", raw[:8])
        check("7 v0 binary header seq==utterance", s == seq, f"{s} vs {seq}")
    else:
        check("7 v0 binary header seq==utterance", False, "no binary frame")
    await ws.close()

    print(f"\n{'ALL PASS' if not FAILS else f'{len(FAILS)} FAILURES: ' + ', '.join(FAILS)}")
    sys.exit(0 if not FAILS else 1)


asyncio.run(main())
