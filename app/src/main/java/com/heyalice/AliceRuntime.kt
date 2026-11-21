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
import java.io.File

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

    // AEC-test clip collection (D1.3): when set, TTS chunks are captured here.
    @Volatile private var clipCollector: ByteArray? = null
    private val clipBuffer = java.util.concurrent.ConcurrentLinkedQueue<ByteArray>()

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
                val collector = clipCollector
                if (collector != null) {
                    if (tFirst != null && clipBuffer.isEmpty()) clipBuffer.add(pcm)
                    else clipBuffer.add(pcm)
                    if (tFirst != null && ttsFirstAt == 0L) ttsFirstAt = tFirst
                } else {
                    engine.enqueueTts(pcm)
                    if (tFirst != null && ttsFirstAt == 0L) {
                        ttsFirstAt = tFirst
                        latency.value = latency.value?.copy(
                            ttsFirstMs = tFirst - tRelease)
                    }
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

    /**
     * Three capture passes (VOICE_COMMUNICATION / MIC / UNPROCESSED) with a
     * fixed TTS clip played through the normal playback path at t=2 s.
     * WAVs land in getExternalFilesDir("aec"); pull via root cat.
     */
    @SuppressLint("MissingPermission")
    fun runAecTest() {
        if (!connected) { aecStatus.value = "connect the gateway first"; return }
        scope.launch {
            try {
                aecStatus.value = "synthesising test clip…"
                val clip = fetchClip() ?: run {
                    aecStatus.value = "clip fetch failed"; return@launch }
                val dir = File(appContext.getExternalFilesDir(null), "aec").apply {
                    mkdirs() }
                val sources = listOf(
                    "VOICE_COMMUNICATION" to MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                    "MIC" to MediaRecorder.AudioSource.MIC,
                    "UNPROCESSED" to MediaRecorder.AudioSource.UNPROCESSED)
                val results = mutableListOf<String>()
                for ((name, src) in sources) {
                    aecStatus.value = "pass $name …"
                    val info = capturePass(name, src, clip, dir)
                    results.add("$name: aecAvail=${info.aecAvailable} " +
                        "attached=${info.aecAttached} enabled=${info.aecEnabled} " +
                        "nsAvail=${info.nsAvailable} attached=${info.nsAttached}")
                }
                aecStatus.value = results.joinToString("\n") +
                    "\nfiles: ${dir.absolutePath}"
                Log.i(TAG, "AEC test done: $results")
            } catch (e: Exception) {
                aecStatus.value = "AEC test failed: ${e.message}"
                Log.e(TAG, "AEC test failed", e)
            }
        }
    }

    private fun fetchClip(): ByteArray? {
        clipBuffer.clear()
        val done = java.util.concurrent.Semaphore(0)
        // reuse the TTS chunk path: redirect chunks into clipBuffer
        clipCollector = ByteArray(0)
        client?.sendTtsRequest("The quick brown fox jumps over the lazy dog. " +
            "The rain in Spain falls mainly on the plain.")
        // drain: watch clipBuffer growth until the tts_end arrives — poll size
        var lastSize = -1; var stable = 0
        val t0 = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - t0 < 30_000) {
            Thread.sleep(300)
            val s = clipBuffer.sumOf { it.size }
            if (s == lastSize) stable++ else stable = 0
            lastSize = s
            if (s > 0 && stable >= 10) break  // 3 s no-growth
        }
        clipCollector = null
        if (clipBuffer.isEmpty()) return null
        val total = clipBuffer.sumOf { it.size }
        val out = ByteArray(total)
        var o = 0
        while (clipBuffer.isNotEmpty()) {
            val b = clipBuffer.poll()!!
            System.arraycopy(b, 0, out, o, b.size); o += b.size
        }
        return out
    }

    private fun capturePass(
        name: String, source: Int, clip: ByteArray, dir: File,
    ): AudioEngine.EffectsInfo {
        engine.stopCapture(); engine.stopPlayback()
        val collected = ArrayList<ByteArray>()
        val info = engine.startCapture(source, object : AudioEngine.FrameSink {
            override fun onFrame(pcm: ByteArray) { collected.add(pcm) }
        })
        engine.startPlayback(volume = 0.8f)
        engine.startFrameFlow()
        try {
            // 2 s baseline, then play the clip; clip ≈ 6 s; 10 s total window
            Thread.sleep(2_000)
            engine.enqueueTts(clip)
            engine.flushAndNotifyDrain()
            val t0 = SystemClock.elapsedRealtime()
            while (SystemClock.elapsedRealtime() - t0 < 8_000 &&
                collected.size < 10 * 50) Thread.sleep(100)
        } finally {
            engine.stopFrameFlow()
            engine.stopCapture()
            engine.stopPlayback()
        }
        val data = ByteArray(collected.size * engine.frameBytes)
        collected.forEachIndexed { i, f ->
            System.arraycopy(f, 0, data, i * engine.frameBytes, engine.frameBytes) }
        val f = File(dir, "pass_${name}.wav")
        engine.writeWav(f.outputStream(), data, 16_000)
        Log.i(TAG, "AEC pass $name -> ${f.absolutePath} (${data.size} B)")
        return info
    }
}
