package dev.voicelive.flutter_gpt_live

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * #ANDROID-BG: keeps a voice call alive while the app is in the background.
 *
 * A foreground service of type "microphone" is what lets Android keep giving
 * the app microphone access after it leaves the screen (Android 11+), and the
 * ongoing notification shows that a call is running, with an "End" action.
 * A partial wake lock and a low-latency Wi-Fi lock keep WebRTC audio flowing
 * with the screen off. Must be started while the app is in the foreground.
 */
class CallService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_END -> {
                // Let Flutter end the session cleanly (server close); without a
                // Flutter engine there is no call left, so just stop.
                val end = onEndRequested
                if (end != null) end() else stopEverything()
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Идёт разговор"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "GPT Live слушает и отвечает"
        val notification = buildNotification(title, text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            // No microphone permission yet or started from the background:
            // never crash the app; the call simply ends when it is hidden.
            stopSelf()
            return START_NOT_STICKY
        }
        acquireLocks()
        return START_NOT_STICKY
    }

    /** Swiping the app away kills the Flutter engine and the call with it. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopEverything()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun stopEverything() {
        releaseLocks()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GptLive:call").apply {
                setReferenceCounted(false)
                acquire(MAX_LOCK_MS)
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "GptLive:call").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun buildNotification(title: String, text: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Разговор", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Идущий голосовой разговор"
                    setShowBadge(false)
                }
            )
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        val end = PendingIntent.getService(
            this, 1, Intent(this, CallService::class.java).setAction(ACTION_END), flags,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_CALL)
            .addAction(
                Notification.Action.Builder(null, "Завершить", end).build()
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    companion object {
        const val ACTION_START = "dev.voicelive.call.START"
        const val ACTION_END = "dev.voicelive.call.END"
        const val ACTION_STOP = "dev.voicelive.call.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "call"
        private const val NOTIFICATION_ID = 4711
        // Safety net: the in-app limit is at most 60 minutes.
        private const val MAX_LOCK_MS = 2L * 60 * 60 * 1000

        /** Set by MainActivity; asks Flutter to end the call. */
        @Volatile
        var onEndRequested: (() -> Unit)? = null
    }
}
