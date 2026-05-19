package io.infernode

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File
import kotlin.concurrent.thread

/**
 * Foreground service for the InferNode 9P export daemon use case.
 *
 * The Activity path runs emu in-process while the UI is visible.
 * For "I want my phone exporting /sdcard over 9P all the time" (the
 * docs/HELLAPHONE.md daemon recipe), the Activity is wrong — Android
 * will kill it under memory pressure. Foreground service with a
 * sticky notification is the canonical pattern.
 *
 * Phase 1c v1: minimum viable. Single instance; idempotent start;
 * stops when explicitly stopped or when the runtime exits.
 */
class InfernodeService : Service() {

    private var bootThread: Thread? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (bootThread == null) {
            bootThread = thread(name = "emu-daemon") { runDaemon() }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        // No reliable way to ask Emu.run to return; the process going
        // away will close emu down. v2 will plumb a shutdown signal
        // through the JNI bridge.
        super.onDestroy()
    }

    private fun runDaemon() {
        val infernoRoot = File(filesDir, "inferno-root")
        // The Activity is responsible for extracting assets; the
        // service trusts the root is present. If a user starts the
        // service before ever opening the Activity, this fails fast.
        val serveScript = File(infernoRoot, "serve9p.b")
        Emu.run(
            arrayOf("-c1", "-r", infernoRoot.absolutePath, "/dis/sh.dis", "/${serveScript.name}")
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan = NotificationChannel(
                CHAN_ID, "InferNode daemon", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background 9P / runtime service"
            }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(chan)
        }
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHAN_ID)
            .setContentTitle("InferNode")
            .setContentText("9P daemon running")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build()

    companion object {
        private const val CHAN_ID = "infernode.daemon"
        private const val NOTIF_ID = 0x9F00
    }
}
