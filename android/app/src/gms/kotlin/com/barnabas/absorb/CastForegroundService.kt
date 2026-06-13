package com.barnabas.absorb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Lightweight foreground service that keeps the Absorb process alive during
 * Chromecast playback. The Cast SDK's notification is owned by Google Play
 * Services, so it does not promote Absorb's process to foreground. Without
 * this service, Android Doze throttles the Dart-side listening-time sync
 * timer when the screen is locked, causing cast listening stats to be
 * severely undercounted (GH #184).
 *
 * Notification is set to IMPORTANCE_MIN / PRIORITY_MIN so it stays collapsed
 * in the shade and does not duplicate the Cast SDK's transport notification.
 */
class CastForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand - promoting to foreground")
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy - releasing foreground")
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Chromecast session",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Keeps Absorb running while casting so listening stats sync."
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            PendingIntent.getActivity(this, 0, it, flags)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Absorb")
            .setContentText("Casting")
            .setSmallIcon(R.drawable.ic_notification)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setSilent(true)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(pendingIntent)
            .build()
    }

    companion object {
        private const val TAG = "CastForegroundService"
        private const val CHANNEL_ID = "absorb_cast_session"
        private const val NOTIFICATION_ID = 9003

        fun start(context: Context) {
            val intent = Intent(context, CastForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CastForegroundService::class.java))
        }
    }
}
