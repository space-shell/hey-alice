package com.heyalice.voice

/**
 * Voice session state machine (plan §4):
 *
 * IDLE -wake/PTT-> CAPTURING -endpoint-> TRANSCRIBING -> ROUTING -> RESPONDING -> IDLE
 *                     (no-speech 5s -> IDLE)      (Paseo RPC)  (TTS streams;
 *                                                              agent events async)
 * RESPONDING -voice barge-in-> INTERRUPTED -> CAPTURING
 * any state -error-> spoken error -> IDLE
 */
enum class VoiceSessionState {
    IDLE,
    CAPTURING,
    TRANSCRIBING,
    ROUTING,
    RESPONDING,
    INTERRUPTED,
}
