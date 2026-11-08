package com.zanghi.phonecam

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Foreground service (type camera, plus microphone once that permission is granted) so streaming continues with the
 * screen locked or the app in the background. Android only allows this if the service starts while the app is
 * visible, which is how the UI starts it.
 */
class StreamService : LifecycleService() {
    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        val c = StreamController(applicationContext, this)
        c.init()
        controller.value = c
        lifecycleScope.launch {
            c.state.collect { s -> updateNotification(s) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification("Starting…"), serviceTypes())
        acquireLocks()
        val pairing = intent?.getStringExtra(EXTRA_PAIRING)?.let { PairingPayload.parse(it) }
        when (intent?.action) {
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
            ACTION_TORCH -> controller.value?.toggleTorch()
            ACTION_REFRESH -> {}   // permissions changed: startForeground above picked up the microphone type
            else -> controller.value?.start(pairing)
        }
        return START_NOT_STICKY
    }

    /** Without the microphone type a backgrounded app records silence, so add it as soon as the permission exists. */
    private fun serviceTypes(): Int {
        val mic = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        return ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or (if (mic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
    }

    override fun onDestroy() {
        controller.value?.release()
        controller.value = null
        wifiLocks.forEach { if (it.isHeld) it.release() }
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wifiLocks.isEmpty()) {
            val wifi = getSystemService(WifiManager::class.java)
            // Low-latency mode only applies while the screen is on and the app is in the foreground; holding the
            // high-perf lock too keeps Wi-Fi out of power-save with the screen off (documented WifiManager pattern).
            @Suppress("DEPRECATION")
            wifiLocks = listOf(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, WifiManager.WIFI_MODE_FULL_HIGH_PERF).map { mode ->
                wifi.createWifiLock(mode, "PhoneCam:$mode").apply { setReferenceCounted(false); acquire() }
            }
        }
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PhoneCam:stream")
                .apply { setReferenceCounted(false); acquire() }
        }
    }

    private fun updateNotification(s: UiState) {
        val text = when (s.phase) {
            Phase.LIVE -> "Live on ${s.macName ?: "Mac"}"
            Phase.CONNECTING -> s.message ?: "Connecting to ${s.macName ?: "Mac"}…"
            Phase.STANDBY -> "Ready for ${s.macName ?: "Mac"}"
            Phase.RECONNECTING -> s.message ?: "Reconnecting…"
            Phase.PAUSED -> "Paused from the Mac"
            Phase.NEEDS_PAIRING -> "Pair again to continue"
            Phase.IDLE -> s.message ?: "Stopped"
        }
        val torch = s.torch.takeIf { s.torchMax > 0 && s.phase != Phase.NEEDS_PAIRING }
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text, torch))
    }

    private fun notification(text: String, torch: Boolean? = null): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Streaming", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, StreamService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_camera)
            .setContentTitle("PhoneCam")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .apply {
                if (torch != null) {
                    val toggle = PendingIntent.getService(this@StreamService, 2,
                        Intent(this@StreamService, StreamService::class.java).setAction(ACTION_TORCH), PendingIntent.FLAG_IMMUTABLE)
                    addAction(0, if (torch) "Light off" else "Light on", toggle)
                }
            }
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        const val EXTRA_PAIRING = "pairing"
        const val ACTION_STOP = "com.zanghi.phonecam.STOP"
        const val ACTION_TORCH = "com.zanghi.phonecam.TORCH"
        const val ACTION_REFRESH = "com.zanghi.phonecam.REFRESH"
        private const val CHANNEL = "stream"
        private const val NOTIFICATION_ID = 1
        val controller = MutableStateFlow<StreamController?>(null)

        fun start(context: Context, pairingUrl: String? = null) {
            context.startForegroundService(Intent(context, StreamService::class.java).putExtra(EXTRA_PAIRING, pairingUrl))
        }

        /** Re-declares the service types (call while the app is visible, e.g. right after a permission grant). */
        fun refresh(context: Context) {
            if (controller.value != null) context.startForegroundService(Intent(context, StreamService::class.java).setAction(ACTION_REFRESH))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, StreamService::class.java))
        }
    }
}
