package com.heyalice.net

import android.os.SystemClock
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Voice-session WebSocket client (docs/protocol.md): uplink 20 ms PCM frames
 * + JSON control; downlink partials/final + seq-numbered TTS PCM chunks
 * (8-byte header: u32 seq, u32 offset). Latency stamps use
 * SystemClock.elapsedRealtime and flow through [Listener].
 */
class GatewayClient(private val listener: Listener) {

    interface Listener {
        fun onReady(sttModel: String, ttsVoice: String, ttsSr: Int)
        fun onPartial(text: String)
        fun onFinal(text: String, seq: Int, sttMs: Int, tFinal: Long)
        fun onTtsChunk(seq: Int, offset: Int, pcm: ByteArray, tFirst: Long?)
        fun onTtsEnd(seq: Int, ttsMs: Int)
        fun onError(msg: String)
        fun onClosed()
    }

    companion object { private const val TAG = "AliceGateway" }

    private val client = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(5, TimeUnit.SECONDS)
        .build()
    private var ws: WebSocket? = null

    @Volatile private var ttsFirstSeenAt: Long? = null

    fun connect(url: String): Boolean {
        ttsFirstSeenAt = null
        val req = Request.Builder().url(url).build()
        ws = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "open $url")
                sendJson(JSONObject().put("type", "hello")
                    .put("sr", 16_000).put("ch", 1).put("fmt", "s16le")
                    .put("t_ms", SystemClock.elapsedRealtime()))
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val msg = JSONObject(text)
                when (msg.optString("type")) {
                    "ready" -> listener.onReady(
                        msg.optString("stt_model"), msg.optString("tts_voice"),
                        msg.optInt("sr", 24_000))
                    "partial" -> listener.onPartial(msg.optString("committed"))
                    "final" -> listener.onFinal(
                        msg.optString("text"), msg.optInt("seq"),
                        msg.optInt("stt_ms"), SystemClock.elapsedRealtime())
                    "tts_start" -> { /* first chunk follows; sr already known */ }
                    "tts_end" -> listener.onTtsEnd(
                        msg.optInt("seq"), msg.optInt("tts_ms"))
                    "error" -> listener.onError(msg.optString("msg"))
                }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val arr = bytes.toByteArray()
                if (arr.size < 8) return
                val seq = u32(arr, 0)
                val offset = u32(arr, 4)
                var tFirst: Long? = null
                if (ttsFirstSeenAt == null) {
                    ttsFirstSeenAt = SystemClock.elapsedRealtime()
                    tFirst = ttsFirstSeenAt
                }
                listener.onTtsChunk(seq, offset, arr.copyOfRange(8, arr.size), tFirst)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "failure: ${t.message}")
                listener.onError("connection failed: ${t.message}")
                listener.onClosed()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                listener.onClosed()
            }
        })
        return true
    }

    fun sendPcm(frame: ByteArray) {
        ws?.send(frame.toByteString())
    }

    fun sendPttStart() { ttsFirstSeenAt = null; sendJson(
        JSONObject().put("type", "ptt_start").put("t_ms", SystemClock.elapsedRealtime())) }

    fun sendPttEnd() = sendJson(
        JSONObject().put("type", "ptt_end").put("t_ms", SystemClock.elapsedRealtime()))

    fun sendCancel() = sendJson(JSONObject().put("type", "cancel"))

    fun sendTtsRequest(text: String) = sendJson(
        JSONObject().put("type", "tts_request").put("text", text))

    private fun sendJson(obj: JSONObject) {
        ws?.let { val s = obj.toString(); if (!it.send(s)) Log.w(TAG, "send dropped (closed)") }
    }

    fun close() {
        ws?.close(1000, "bye")
        ws = null
    }

    private fun u32(b: ByteArray, o: Int) =
        ((b[o].toInt() and 0xff) or ((b[o + 1].toInt() and 0xff) shl 8) or
            ((b[o + 2].toInt() and 0xff) shl 16) or ((b[o + 3].toInt() and 0xff) shl 24))
}
