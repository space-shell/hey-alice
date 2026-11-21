package com.heyalice.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import android.os.SystemClock
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Full-duplex audio path (plan §4): AudioRecord 16 kHz mono s16 → 20 ms frame
 * callback out; TTS PCM bytes in → AudioTrack 24 kHz mono s16 out.
 *
 * D1.3: capture source is configurable so VOICE_COMMUNICATION / MIC /
 * UNPROCESSED can be compared; AEC/NS availability probed and reported.
 * Uplink format is fixed by ADR-4 (16 kHz PCM on WiFi; Opus is M5).
 */
class AudioEngine(
    private val sampleRate: Int = 16_000,
    private val ttsSampleRate: Int = 24_000,
) {
    interface FrameSink { fun onFrame(pcm: ByteArray) }

    /** 20 ms mono s16le uplink frame (640 B at 16 kHz). */
    val frameBytes = sampleRate / 50 * 2

    data class EffectsInfo(
        val source: String,
        val aecAvailable: Boolean,
        val aecAttached: Boolean,
        val aecEnabled: Boolean,
        val nsAvailable: Boolean,
        val nsAttached: Boolean,
    )

    @Volatile var lastEffectsInfo: EffectsInfo? = null
        private set
    @Volatile var firstWriteAt: Long = 0
    var onFirstPlayback: (() -> Unit)? = null
    var onDrained: (() -> Unit)? = null

    // ---- capture -----------------------------------------------------------

    private var record: AudioRecord? = null
    private var readerThread: Thread? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    @Volatile private var sink: FrameSink? = null
    private val flowOpen = AtomicBoolean(false)

    /** Begin recording [source]; frames flow to [sink] only between
     *  [startFrameFlow]/[stopFrameFlow]. Returns the effects probe. */
    @SuppressLint("MissingPermission") // caller checks RECORD_AUDIO
    fun startCapture(source: Int, sink: FrameSink): EffectsInfo {
        stopCapture()
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord.Builder()
            .setAudioSource(source)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build())
            .setBufferSizeInBytes(maxOf(minBuf, frameBytes * 8))
            .build()
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            error("AudioRecord init failed for source $source")
        }
        this.sink = sink
        record = rec
        val info = probeEffects(rec, source)
        lastEffectsInfo = info
        rec.startRecording()
        readerThread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val buf = ByteArray(frameBytes)
            while (!Thread.currentThread().isInterrupted) {
                val n = rec.read(buf, 0, frameBytes, AudioRecord.READ_BLOCKING)
                when {
                    n < 0 -> return@Thread
                    n == frameBytes && flowOpen.get() ->
                        sink?.onFrame(buf.copyOf())
                }
            }
        }, "alice-capture").apply { start() }
        return info
    }

    private fun probeEffects(rec: AudioRecord, source: Int): EffectsInfo {
        val sid = rec.audioSessionId
        val sourceName = when (source) {
            MediaRecorder.AudioSource.VOICE_COMMUNICATION -> "VOICE_COMMUNICATION"
            MediaRecorder.AudioSource.MIC -> "MIC"
            MediaRecorder.AudioSource.UNPROCESSED -> "UNPROCESSED"
            else -> "source($source)"
        }
        // UNPROCESSED must stay unprocessed — attach nothing there.
        var aecAttached = false; var aecEnabled = false; var nsAttached = false
        if (source != MediaRecorder.AudioSource.UNPROCESSED) {
            try {
                aec = AcousticEchoCanceler.create(sid).also {
                    aecAttached = it != null
                    it?.enabled = true
                    aecEnabled = it?.enabled == true
                }
            } catch (_: Exception) { aec = null }
            try {
                ns = NoiseSuppressor.create(sid).also { nsAttached = it != null; it?.enabled = true }
            } catch (_: Exception) { ns = null }
        }
        return EffectsInfo(
            sourceName,
            AcousticEchoCanceler.isAvailable(), aecAttached, aecEnabled,
            NoiseSuppressor.isAvailable(), nsAttached)
    }

    fun startFrameFlow() { flowOpen.set(true) }
    fun stopFrameFlow() { flowOpen.set(false) }

    fun stopCapture() {
        flowOpen.set(false)
        readerThread?.interrupt(); readerThread = null
        try { record?.stop() } catch (_: Exception) {}
        record?.release(); record = null
        try { aec?.release() } catch (_: Exception) {} ; aec = null
        try { ns?.release() } catch (_: Exception) {} ; ns = null
        sink = null
    }

    // ---- playback ------------------------------------------------------------

    private var track: AudioTrack? = null
    private var playerThread: Thread? = null
    private val playing = AtomicBoolean(false)
    private val playQueue = LinkedBlockingQueue<ByteArray>()
    private val bytesWritten = AtomicLong(0)

    private object Sentinels {
        val FLUSH: ByteArray = byteArrayOf()   // drain marker
        val QUIT: ByteArray = byteArrayOf(1)
    }

    fun startPlayback(volume: Float? = null) {
        stopPlayback()
        val minBuf = AudioTrack.getMinBufferSize(
            ttsSampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val trk = AudioTrack.Builder()
            .setAudioAttributes(
                android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build())
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(ttsSampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(minBuf)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        track = trk
        trk.setVolume(volume ?: 1f)
        firstWriteAt = 0
        bytesWritten.set(0)
        trk.play()
        playing.set(true)
        playerThread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            loop@ while (playing.get()) {
                val chunk = playQueue.poll(100, TimeUnit.MILLISECONDS) ?: continue
                when {
                    chunk === Sentinels.QUIT -> break@loop
                    chunk === Sentinels.FLUSH -> {
                        val t = track ?: break@loop
                        // all enqueued bytes are written; wait for the track's
                        // own small buffer to play out too (frames*2 bytes)
                        val target = bytesWritten.get() / 2
                        while (playing.get() && t.playbackHeadPosition < target) {
                            Thread.sleep(10)
                        }
                        onDrained?.invoke()
                    }
                    else -> {
                        if (firstWriteAt == 0L) {
                            firstWriteAt = SystemClock.elapsedRealtime()
                            onFirstPlayback?.invoke()
                        }
                        track?.write(chunk, 0, chunk.size)
                        bytesWritten.addAndGet(chunk.size.toLong())
                    }
                }
            }
        }, "alice-play").apply { start() }
    }

    /** Enqueue TTS PCM (24 kHz mono s16le). */
    fun enqueueTts(pcm: ByteArray) { if (pcm.isNotEmpty()) playQueue.add(pcm) }

    /** After the last chunk of an utterance: [onDrained] fires once the
     *  queue and the track buffer have played out. */
    fun flushAndNotifyDrain() { playQueue.add(Sentinels.FLUSH) }

    fun stopPlayback() {
        playing.set(false)
        playQueue.clear()
        playQueue.add(Sentinels.QUIT)
        playerThread?.join(500); playerThread = null
        try { track?.pause() } catch (_: Exception) {}
        track?.flush()
        track?.release(); track = null
    }

    // ---- WAV helper ------------------------------------------------------------

    fun writeWav(os: OutputStream, pcm: ByteArray, sr: Int) {
        fun le(v: Int) = byteArrayOf(
            (v and 0xff).toByte(), (v shr 8 and 0xff).toByte(),
            (v shr 16 and 0xff).toByte(), (v shr 24 and 0xff).toByte())
        os.write("RIFF".toByteArray()); os.write(le(36 + pcm.size)); os.write("WAVE".toByteArray())
        os.write("fmt ".toByteArray()); os.write(le(16)); os.write(le(1))
        os.write(le(1)); os.write(le(sr)); os.write(le(sr * 2)); os.write(le(2)); os.write(le(16))
        os.write("data".toByteArray()); os.write(le(pcm.size)); os.write(pcm)
    }
}
