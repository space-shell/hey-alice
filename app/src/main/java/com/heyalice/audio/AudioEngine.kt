package com.heyalice.audio

/**
 * Full-duplex audio path: AudioRecord -> 20 ms frames out; frames -> AudioTrack in.
 *
 * Format: 16 kHz, mono, 16-bit PCM, 20 ms frames (640 bytes) per plan §4.
 * D1.3 decides the source (VOICE_COMMUNICATION vs UNPROCESSED vs MIC) based on
 * measured AEC quality on the NX1 — barge-in viability depends on that verdict.
 * Fallback if AEC is unusable: TTS ducking (half-duplex), barge-in via PTT.
 */
class AudioEngine {
    // TODO(D1.3): AcousticEchoCanceler.isAvailable() probe + suppression measurement
    // TODO(M1): AudioRecord + AudioTrack wiring, PTT capture path
    // TODO(M2): barge-in gating driven by com.heyalice.vad.Vad
    // TODO(M5): Opus encode for 4G transport (ADR-4); PCM on WiFi
    fun start(): Unit = TODO("M1")
    fun stop(): Unit = TODO("M1")
}
