package com.heyalice.vad

/**
 * On-device VAD (Silero ONNX): barge-in gating while TTS plays, plus
 * client-side endpointing assist. The server re-verifies endpoints —
 * the server is the single source of truth for segmentation (plan §4).
 */
class Vad {
    // TODO(M2): Silero ONNX runtime; emits speech_start / speech_end events
    fun start(): Unit = TODO("M2")
}
