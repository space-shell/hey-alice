package com.heyalice.ptt

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import java.io.InputStream

/**
 * ADR-6 PTT input: read /dev/input/event0 raw via su, measure KEY_POWER
 * DOWN→UP duration; hold ≥ 500 ms → PTT (capture starts when the threshold
 * is crossed while still held; release stops capture and sends).
 *
 * The framework also sees these events (no EVIOCGRAB): short press still
 * toggles the screen; long press is neutralised by the RRO overlay
 * (config_longPressOnPowerBehavior=0).
 *
 * Requires a Magisk superuser grant for THIS app (com.heyalice) — the first
 * run triggers a Magisk prompt; grant it once. su is auto-denied while the
 * screen is locked (stage-1 finding), so capture windows keep the screen on.
 */
class SideKeyWatcher(
    private val onPttStart: () -> Unit,
    private val onPttEnd: (heldMs: Long) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val TAG = "AliceSideKey"
        private const val EV_KEY = 0x01
        private const val KEY_POWER = 0x74
        private const val HOLD_THRESHOLD_MS = 500L
        private const val EVENT_SIZE = 24  // 64-bit input_event
    }

    private var process: Process? = null
    private var reader: Thread? = null
    private val handlerThread = HandlerThread("alice-sidekey").apply { start() }
    private val handler = Handler(handlerThread.looper)

    @Volatile private var downAt: Long = 0
    @Volatile private var pttActive = false

    fun start() {
        stop()
        try {
            val p = ProcessBuilder("su", "-c", "cat /dev/input/event0")
                .redirectErrorStream(false)
                .start()
            process = p
            reader = Thread({
                try {
                    parseLoop(p.inputStream)
                } catch (e: Exception) {
                    if (running) onError("event0 reader failed: ${e.message}")
                }
            }, "alice-sidekey-read").apply { start() }
            running = true
            Log.i(TAG, "watching /dev/input/event0 via su")
        } catch (e: Exception) {
            onError("su cat /dev/input/event0 failed: ${e.message} — " +
                "grant com.heyalice in Magisk (screen must be unlocked)")
        }
    }

    @Volatile private var running = false

    private fun parseLoop(input: InputStream) {
        val buf = ByteArray(EVENT_SIZE)
        while (running) {
            var off = 0
            while (off < EVENT_SIZE) {
                val n = input.read(buf, off, EVENT_SIZE - off)
                if (n < 0) return
                off += n
            }
            // struct input_event (64-bit): sec i64, usec i64, type u16, code u16, value i32
            val type = u16(buf, 16)
            val code = u16(buf, 18)
            val value = i32(buf, 20)
            if (type == EV_KEY && code == KEY_POWER) {
                when (value) {
                    1 -> onKeyDown()
                    0 -> onKeyUp()
                    2 -> { /* repeat */ }
                }
            }
        }
    }

    private fun onKeyDown() {
        downAt = SystemClock.elapsedRealtime()
        pttActive = false
        handler.postDelayed({
            if (downAt != 0L) {           // still held
                pttActive = true
                Log.i(TAG, "PTT start (hold ≥ ${HOLD_THRESHOLD_MS} ms)")
                onPttStart()
            }
        }, HOLD_THRESHOLD_MS)
    }

    private fun onKeyUp() {
        val down = downAt
        downAt = 0
        handler.removeCallbacksAndMessages(null)
        if (pttActive) {
            pttActive = false
            val held = SystemClock.elapsedRealtime() - down
            Log.i(TAG, "PTT end (held $held ms)")
            onPttEnd(held)
        }
    }

    fun stop() {
        running = false
        handler.removeCallbacksAndMessages(null)
        try { process?.destroy() } catch (_: Exception) {}
        process = null
        reader = null
    }

    private fun u16(b: ByteArray, o: Int) =
        ((b[o].toInt() and 0xff) or ((b[o + 1].toInt() and 0xff) shl 8))
    private fun i32(b: ByteArray, o: Int) =
        ((b[o].toInt() and 0xff) or ((b[o + 1].toInt() and 0xff) shl 8) or
            ((b[o + 2].toInt() and 0xff) shl 16) or ((b[o + 3].toInt() and 0xff) shl 24))
}
