package com.heyalice.debug

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import com.heyalice.audio.AudioEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * D1.3 AEC test harness (plan D1.3), extracted from AliceRuntime (tracker C7).
 *
 * Three capture passes (VOICE_COMMUNICATION / MIC / UNPROCESSED) with a fixed
 * TTS clip played through the NORMAL playback path at t=2 s. WAVs land in
 * getExternalFilesDir("aec"); pull via root cat.
 *
 * [requestClip] reuses the gateway tts_request path so the test clip is
 * identical to production audio; chunks are routed back via [acceptChunk]
 * while [isCollecting] is true.
 *
 * [onRestore] runs after the last pass — the runtime restarts its normal
 * audio path there (tracker F4: previously the engine stayed stopped and
 * PTT was dead until reconnect).
 */
class AecProbe(
    private val engine: AudioEngine,
    private val appContext: Context,
    private val requestClip: (String) -> Unit,
    private val setStatus: (String?) -> Unit,
    private val onRestore: () -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val clipBuffer = ConcurrentLinkedQueue<ByteArray>()

    @Volatile private var collecting = false
    val isCollecting: Boolean get() = collecting

    fun acceptChunk(pcm: ByteArray) {
        clipBuffer.add(pcm)
    }

    fun run() {
        scope.launch {
            try {
                setStatus("synthesising test clip…")
                val clip = fetchClip() ?: run {
                    setStatus("clip fetch failed"); return@launch }
                val dir = File(appContext.getExternalFilesDir(null), "aec").apply {
                    mkdirs() }
                val sources = listOf(
                    "VOICE_COMMUNICATION" to MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                    "MIC" to MediaRecorder.AudioSource.MIC,
                    "UNPROCESSED" to MediaRecorder.AudioSource.UNPROCESSED)
                val results = mutableListOf<String>()
                for ((name, src) in sources) {
                    setStatus("pass $name …")
                    val info = capturePass(name, src, clip, dir)
                    results.add("$name: aecAvail=${info.aecAvailable} " +
                        "attached=${info.aecAttached} enabled=${info.aecEnabled} " +
                        "nsAvail=${info.nsAvailable} attached=${info.nsAttached}")
                }
                setStatus(results.joinToString("\n") +
                    "\nfiles: ${dir.absolutePath}")
                Log.i(TAG, "AEC test done: $results")
            } catch (e: Exception) {
                setStatus("AEC test failed: ${e.message}")
                Log.e(TAG, "AEC test failed", e)
            } finally {
                onRestore()
            }
        }
    }

    private fun fetchClip(): ByteArray? {
        clipBuffer.clear()
        collecting = true
        requestClip("The quick brown fox jumps over the lazy dog. " +
            "The rain in Spain falls mainly on the plain.")
        // drain: watch clipBuffer growth until growth stalls (tts_end arrives)
        var lastSize = -1; var stable = 0
        val t0 = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - t0 < 30_000) {
            Thread.sleep(300)
            val s = clipBuffer.sumOf { it.size }
            if (s == lastSize) stable++ else stable = 0
            lastSize = s
            if (s > 0 && stable >= 10) break  // 3 s no-growth
        }
        collecting = false
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

    @SuppressLint("MissingPermission") // service started after permission grant
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
        val f = File(dir, "pass_$name.wav")
        engine.writeWav(f.outputStream(), data, 16_000)
        Log.i(TAG, "AEC pass $name -> ${f.absolutePath} (${data.size} B)")
        return info
    }

    companion object {
        private const val TAG = "AliceAecProbe"
    }
}
