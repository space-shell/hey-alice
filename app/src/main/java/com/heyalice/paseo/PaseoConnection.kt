package com.heyalice.paseo

/**
 * Paseo daemon connection: direct WebSocket + relay (E2EE), adapted from the
 * xagent launcher's connection architecture (plan ADR-3). Single connection
 * profile in v1; multi-daemon remerge is launcher-specific and deferred.
 *
 * TODO(M3): port + trim from space-shell/xagent (branch bluefox-nx1-voice-companion-plan):
 *   - direct WS transport with bearer password auth
 *   - relay transport: X25519 key agreement + E2EE framing (relay sees ciphertext only)
 *   - reconnect with backoff; session resumption
 *   - agent state model: Idle / Queued / Running / AwaitingInput / Done / Error
 *   - prompt send, status subscribe, session create/archive
 *
 * Intents (plan M3, deterministic grammar — no LLM router in v1):
 *   "note: ..."              -> ephemeral session alice-note-<ts>, agent files to
 *                               memos via memos MCP, archive on completion, "Noted."
 *   "status / what's X doing"-> status subscribe -> spoken summary
 *   "tell/ask X to ..."      -> prompt send -> spoken ack
 *   "new session on Y"       -> create with wizard-free defaults
 *   "archive X"              -> optimistic archive
 */
class PaseoConnection {
    fun connect(): Unit = TODO("M3")
}
