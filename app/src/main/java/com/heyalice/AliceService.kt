package com.heyalice

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * Always-on foreground service: owns the audio engine, wake word listener, VAD,
 * and the voice session state machine. The docked profile keeps this running
 * indefinitely; the battery-optimisation exemption is granted at M0 bring-up.
 */
class AliceService : Service() {

    override fun onCreate() {
        super.onCreate()
        // TODO(M1): start AudioEngine (full-duplex) + PTT side-key capture (D1.2)
        // TODO(M4): wake word armed (docked profile), attention dots via status UI
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        // TODO(M1): notification channel + "Alice is listening" content
        return Notification.Builder(this).build()
    }

    companion object {
        private const val NOTIFICATION_ID = 1
    }
}
