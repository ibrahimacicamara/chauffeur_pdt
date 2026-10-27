package com.example.chauffeur

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/** Foreground mediaPlayback service looping the alarm sound while unconfirmed alarms remain active. */
class ReminderAlarmService : Service() {
    companion object {
        const val ACTION_START = "com.example.chauffeur.REMINDER_ALARM_START"
        private const val TAG = ReminderAlarmController.TAG

        @Volatile
        var instance: ReminderAlarmService? = null
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private val tick = Runnable { sync() }
    private var player: MediaPlayer? = null
    private var foreground = false
    private var playbackFailed = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val alarms = ReminderAlarmStore.activeAlarms(this, System.currentTimeMillis())
        // startForeground must always be called after startForegroundService, even if nothing rings.
        if (!enterForeground(alarms)) {
            val app = applicationContext
            ReminderAlarmController.executor.execute { ReminderAlarmController.showFallbackNotifications(app) }
            stopSelf()
            return START_NOT_STICKY
        }
        sync(alarms)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        stopPlayback()
        instance = null
        super.onDestroy()
    }

    private fun enterForeground(alarms: List<ReminderAlarmSpec>): Boolean {
        val notification = ReminderAlarmController.buildServiceNotification(this, alarms)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    ReminderAlarmController.NOTIFICATION_ID_SERVICE, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(ReminderAlarmController.NOTIFICATION_ID_SERVICE, notification)
            }
            foreground = true
            if (!ReminderAlarmController.notificationsEnabled(this)) {
                Log.w(TAG, "Notifications disabled: alarm rings without visible notification/silence action")
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "startForeground refused (${e.javaClass.simpleName}: ${e.message})")
            false
        }
    }

    fun sync() = sync(ReminderAlarmStore.activeAlarms(this, System.currentTimeMillis()))

    private fun sync(alarms: List<ReminderAlarmSpec>) {
        handler.removeCallbacks(tick)
        if (alarms.isEmpty()) {
            stopPlayback()
            if (foreground) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
                else @Suppress("DEPRECATION") stopForeground(true)
                foreground = false
            }
            stopSelf()
            return
        }
        val now = System.currentTimeMillis()
        if (foreground) {
            try {
                getSystemService(android.app.NotificationManager::class.java)?.notify(
                    ReminderAlarmController.NOTIFICATION_ID_SERVICE,
                    ReminderAlarmController.buildServiceNotification(this, alarms),
                )
            } catch (e: Exception) {
                Log.w(TAG, "Unable to update alarm notification: ${e.message}")
            }
        }
        var next = alarms.minOf { it.expiresAt }
        if (alarms.any { it.alarmNotBefore <= now }) {
            if (startPlayback()) {
                ReminderAlarmController.cancelFallback(this, alarms)
            } else if (!playbackFailed) {
                playbackFailed = true
                Log.e(TAG, "No playable alarm sound; posting insistent fallback notification")
                val app = applicationContext
                ReminderAlarmController.executor.execute { ReminderAlarmController.showFallbackNotifications(app) }
            }
        } else {
            stopPlayback()
        }
        alarms.filter { it.alarmNotBefore > now }.minOfOrNull { it.alarmNotBefore }?.let { next = minOf(next, it) }
        handler.postDelayed(tick, (next - now + 50).coerceAtLeast(1000L))
    }

    private fun soundCandidates(): List<Uri> {
        val actual = try {
            RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
        } catch (_: Exception) {
            null
        }
        return listOfNotNull(
            actual,
            Settings.System.DEFAULT_ALARM_ALERT_URI,
            Settings.System.DEFAULT_RINGTONE_URI,
            Settings.System.DEFAULT_NOTIFICATION_URI,
        ).distinct()
    }

    private fun startPlayback(): Boolean {
        if (player?.isPlaying == true) return true
        stopPlayback()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        for (uri in soundCandidates()) {
            val p = MediaPlayer()
            try {
                p.setAudioAttributes(attributes)
                p.setDataSource(this, uri)
                p.isLooping = true
                p.setWakeMode(this, PowerManager.PARTIAL_WAKE_LOCK)
                p.prepare()
                p.start()
                player = p
                playbackFailed = false
                val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                if (audio.getStreamVolume(AudioManager.STREAM_ALARM) == 0) {
                    Log.w(TAG, "Alarm stream volume is 0: the alarm loop is inaudible")
                }
                Log.i(TAG, "Alarm loop playing ($uri)")
                return true
            } catch (e: Exception) {
                Log.w(TAG, "Cannot play $uri: ${e.javaClass.simpleName}: ${e.message}")
                p.release()
            }
        }
        return false
    }

    private fun stopPlayback() {
        player?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
    }
}