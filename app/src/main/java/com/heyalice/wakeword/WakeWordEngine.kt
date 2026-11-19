package com.heyalice.wakeword

/**
 * Always-on "Hey Alice" detector.
 *
 * Engine candidates (plan D1.6): openWakeWord (ONNX, custom phrase via synthetic
 * TTS — preferred), microWakeWord, Porcupine (license constraints).
 * Targets: <1 false accept per 24 h docked; <5% miss rate at 3 m.
 */
class WakeWordEngine {
    // TODO(D1.6): train "Hey Alice", measure CPU load on A55 cores + battery cost
    // TODO(M4): arm/disarm from docked power profile; chime ack on detection
    fun arm(): Unit = TODO("M4")
    fun disarm(): Unit = TODO("M4")
}
