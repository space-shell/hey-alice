package com.heyalice

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import com.heyalice.audio.AudioEngine
import com.heyalice.net.GatewayClient
import com.heyalice.ptt.SideKeyWatcher
import com.heyalice.voice.VoiceSessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Process-wide runtime owned by [AliceService]: full-duplex audio + PTT
 * side key + gateway client, wired per plan §4 / docs/protocol.md.
 * UI observes the flows; nothing here touches the UI directly.
 */
object AliceRuntime {
    private const val TAG = "AliceRuntime"
    const val DEFAULT_URL = "ws://192.168.1.110:8765/ws"

    // ---- observable state ------------------------------------------------

    data class Latency(
        val releaseMs: Long,      // PTT release -> final transcript received
        val ttsFirstMs: Long,     // release -> first TTS chunk received
        val playMs: Long,         // release -> first byte written to AudioTrack
        val sttServerMs: Int,     // server-side ptt_end -> final
        val ttsServerMs: Int,     // server-side final -> last TTS chunk
    )

    val connection = MutableStateFlow("disconnected")
    val state = MutableStateFlow(VoiceSessionState.IDLE)
    val partial = MutableStateFlow("")
    val finalText = MutableStateFlow("")
    val latency = MutableStateFlow<Latency?>(null)
    val suError = MutableStateFlow<String?>(null)
    val aecStatus = MutableStateFlow<String?>(null)
    val gatewayInfo = MutableStateFlow("")

    // ---- internals ---------------------------------------------------------

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var appContext: Context
    private val engine = AudioEngine()
    private var client: GatewayClient? = null
    private var watcher: SideKeyWatcher? = null
    private var connected = false

    @Volatile private var tRelease = 0L
    @Volatile private var ttsFirstAt = 0L

    // AEC-test clip collection (D1.3): when the probe is collecting, TTS chunks
    // route into it instead of the playback engine (tracker C7/F4).
    private var aecProbe: com.heyalice.debug.AecProbe? = null
    @Volatile private var lastTtsSr = 24_000

    @SuppressLint("MissingPermission")
    fun start(ctx: Context) {
        appContext = ctx.applicationContext
        if (watcher != null) return
        watcher = SideKeyWatcher(
            onPttStart = ::pttStart,
            onPttEnd = { pttEnd() },
            onError = { suError.value = it; Log.w(TAG, it) },
        ).also { it.start() }
        engine.onFirstPlayback = {
            if (state.value == VoiceSessionState.RESPONDING && tRelease != 0L) {
                latency.value = latency.value?.copy(
                    playMs = SystemClock.elapsedRealtime() - tRelease)
            }
        }
        engine.onDrained = { if (state.value == VoiceSessionState.RESPONDING) toIdle() }
    }

    // ---- gateway ------------------------------------------------------------

    fun connectGateway(url: String) {
        if (connected) disconnect()
        connection.value = "connecting $url"
        client = GatewayClient(object : GatewayClient.Listener {
            override fun onReady(sttModel: String, ttsVoice: String, ttsSr: Int) {
                connected = true
                lastTtsSr = ttsSr
                gatewayInfo.value = "$sttModel / $ttsVoice / ${ttsSr}Hz"
                connection.value = "connected"
                scope.launch { startAudio(ttsSr) }
            }

            override fun onPartial(text: String) { partial.value = text }

            override fun onFinal(text: String, seq: Int, sttMs: Int, tFinal: Long) {
                finalText.value = text
                state.value = VoiceSessionState.RESPONDING
                val rel = if (tRelease != 0L) tFinal - tRelease else -1
                latency.value = Latency(rel, -1, -1, sttMs, -1)
                Log.i(TAG, "final in ${rel}ms (server $sttMs): $text")
            }

            override fun onTtsChunk(seq: Int, offset: Int, pcm: ByteArray, tFirst: Long?) {
                val probe = aecProbe
                if (probe != null && probe.isCollecting) {
                    probe.acceptChunk(pcm)
                    return
                }
                engine.enqueueTts(pcm)
                if (tFirst != null && ttsFirstAt == 0L) {
                    ttsFirstAt = tFirst
                    latency.value = latency.value?.copy(
                        ttsFirstMs = tFirst - tRelease)
                }
            }

            override fun onTtsEnd(seq: Int, ttsMs: Int) {
                latency.value = latency.value?.copy(ttsServerMs = ttsMs)
                engine.flushAndNotifyDrain()
            }

            override fun onError(msg: String) {
                connection.value = "error: $msg"
            }

            override fun onClosed() {
                connected = false
                // keep a just-logged failure visible: onClosed must not clobber
                // the error the user needs to see (found 2026-11-27 — every
                // failed connect looked like a dead button)
                if (!connection.value.startsWith("error"))
                    connection.value = "disconnected"
                toIdle()
            }
        }).also { it.connect(url) }
    }

    fun disconnect() {
        client?.close(); client = null
        connected = false
        engine.stopPlayback(); engine.stopCapture()
        connection.value = "disconnected"
    }

    // ---- audio ------------------------------------------------------------

    @SuppressLint("MissingPermission") // service started after permission grant
    private fun startAudio(ttsSr: Int) {
        engine.startPlayback()
        engine.startCapture(MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            object : AudioEngine.FrameSink {
                override fun onFrame(pcm: ByteArray) {
                    if (connected) client?.sendPcm(pcm)
                }
            })
        Log.i(TAG, "audio up: ${engine.lastEffectsInfo}")
    }

    // ---- PTT (ADR-6) -----------------------------------------------------

    private fun pttStart() {
        if (!connected) { Log.w(TAG, "PTT ignored (not connected)"); return }
        state.value = VoiceSessionState.CAPTURING
        partial.value = ""; finalText.value = ""
        latency.value = null; ttsFirstAt = 0
        engine.startFrameFlow()
        client?.sendPttStart()
    }

    private fun pttEnd() {
        if (state.value != VoiceSessionState.CAPTURING) return
        tRelease = SystemClock.elapsedRealtime()
        state.value = VoiceSessionState.TRANSCRIBING
        engine.stopFrameFlow()
        client?.sendPttEnd()
    }

    private fun toIdle() { state.value = VoiceSessionState.IDLE }

    // ---- D1.3 AEC test -------------------------------------------------------

    /** Harness lives in debug/AecProbe.kt (tracker C7); onRestore restarts the
     *  normal audio path after the passes (tracker F4 — the engine used to be
     *  left stopped, killing PTT until reconnect). */
    fun runAecTest() {
        if (!connected) { aecStatus.value = "connect the gateway first"; return }
        val probe = aecProbe ?: com.heyalice.debug.AecProbe(
            engine = engine,
            appContext = appContext,
            requestClip = { text -> client?.sendTtsRequest(text) },
            setStatus = { aecStatus.value = it },
            onRestore = { if (connected) startAudio(lastTtsSr) },
        ).also { aecProbe = it }
        probe.run()
    }
}
