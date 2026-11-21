package com.heyalice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * Always-on foreground service: owns [AliceRuntime] (audio engine, PTT side
 * key, gateway client). Battery-exempted at M0; docked profile keeps this
 * running indefinitely.
 */
class AliceService : Service() {

    override fun onCreate() {
        super.onCreate()
        channel()
        AliceRuntime.start(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        AliceRuntime.disconnect()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun channel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Alice voice", NotificationManager.IMPORTANCE_LOW))
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Alice")
            .setContentText("Voice loop running — hold the side key to talk")
            .setOngoing(true)
            .build()

    companion object {
        private const val CHANNEL_ID = "alice_voice"
        private const val NOTIFICATION_ID = 1
    }
}
