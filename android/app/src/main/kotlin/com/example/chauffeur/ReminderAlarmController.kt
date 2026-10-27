package com.example.chauffeur

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Single entry point for every alarm mutation (FCM receiver, notification actions, Flutter bridge).
 * Blocking methods must be called on [executor].
 */
object ReminderAlarmController {
    const val TAG = "ReminderAlarm"

    const val TYPE_ALARM = "driver_reminder_alarm"
    const val TYPE_STOP = "driver_reminder_alarm_stop"

    const val ACTION_OPEN = "com.example.chauffeur.REMINDER_ALARM_OPEN"
    const val ACTION_SILENCE = "com.example.chauffeur.REMINDER_ALARM_SILENCE"
    const val EXTRA_KEYS = "reminder_alarm_keys"
    const val EXTRA_ORDER_ID = "reminder_alarm_order_id"
    const val EXTRA_DRIVER_ID = "reminder_alarm_driver_id"
    const val EXTRA_GENERATION = "reminder_alarm_generation"

    const val CHANNEL_ALARM = "driver_reminder_alarm"
    const val CHANNEL_FALLBACK = "driver_reminder_alarm_fallback"
    const val CHANNEL_PENDING = "driver_reminder_alarm_pending"
    const val NOTIFICATION_ID_SERVICE = 7301
    private const val NOTIFICATION_ID_FALLBACK = 7302
    private const val NOTIFICATION_ID_PENDING = 7303

    private const val TITLE = "Rappel de disponibilit\u00e9"

    val executor: ExecutorService = Executors.newSingleThreadExecutor()
    val mainHandler = Handler(Looper.getMainLooper())
    private val changeListeners = CopyOnWriteArraySet<() -> Unit>()

    fun addChangeListener(listener: () -> Unit) { changeListeners += listener }
    fun removeChangeListener(listener: () -> Unit) { changeListeners -= listener }
    private fun notifyChanged() = mainHandler.post { changeListeners.forEach { it() } }

    private fun now() = System.currentTimeMillis()

    fun bindDriver(context: Context, driverId: String) {
        val app = context.applicationContext
        val removed = ReminderAlarmStore.bindDriver(app, driverId)
        if (removed.isNotEmpty()) {
            Log.i(TAG, "Driver binding changed; cleared ${removed.size} alarm(s) of previous driver")
            cancelNotifications(app, removed)
            refreshService()
            notifyChanged()
        }
    }

    /** Returns null-free result code: start_requested, fallback_notification or a rejection reason. */
    fun startAlarm(context: Context, spec: ReminderAlarmSpec, source: String): String {
        val app = context.applicationContext
        val rejection = ReminderAlarmStore.admit(app, spec, now())
        if (rejection != null) {
            Log.i(TAG, "Alarm ${spec.orderId}/${spec.generation} from $source not started: $rejection")
            return rejection
        }
        notifyChanged()
        return launchService(app, source)
    }

    private fun launchService(app: Context, source: String): String {
        if (ReminderAlarmService.instance != null) {
            refreshService()
            Log.i(TAG, "Alarm from $source added to the running alarm service")
            return "start_requested"
        }
        val intent = Intent(app, ReminderAlarmService::class.java).setAction(ReminderAlarmService.ACTION_START)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) app.startForegroundService(intent)
            else app.startService(intent)
            Log.i(TAG, "Alarm service start requested from $source")
            "start_requested"
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (API 31+), IllegalStateException, SecurityException.
            Log.w(TAG, "Alarm service start refused from $source (${e.javaClass.simpleName}: ${e.message}); posting insistent fallback notification")
            showFallbackNotifications(app)
            "fallback_notification"
        }
    }

    fun stop(context: Context, driverId: String, orderId: String, generation: String): Boolean {
        val app = context.applicationContext
        val removed = ReminderAlarmStore.stop(app, driverId, orderId, generation, now())
        cancelNotifications(app, listOf(ReminderAlarmStore.key(driverId, orderId, generation)))
        refreshService()
        notifyChanged()
        Log.i(TAG, "Alarm $orderId/$generation stopped (wasPresent=$removed)")
        return removed
    }

    /** Silences ringing alarms; the reminder stays unconfirmed (server escalation unaffected). */
    fun silence(context: Context, keys: Collection<String>): Int {
        val app = context.applicationContext
        val moved = ReminderAlarmStore.silence(app, keys, now())
        for (spec in moved) {
            cancel(app, spec.key, NOTIFICATION_ID_FALLBACK)
            post(app, spec.key, NOTIFICATION_ID_PENDING, buildPendingNotification(app, spec))
        }
        refreshService()
        notifyChanged()
        Log.i(TAG, "Silenced ${moved.size} alarm(s)")
        return moved.size
    }

    fun stopAll(context: Context, unbind: Boolean) {
        val app = context.applicationContext
        val removed = ReminderAlarmStore.clearAll(app, unbind, now())
        cancelNotifications(app, removed)
        refreshService()
        notifyChanged()
        Log.i(TAG, "Stopped all alarms (${removed.size}), unbind=$unbind")
    }

    fun refreshService() = mainHandler.post { ReminderAlarmService.instance?.sync() }

    fun showFallbackNotifications(context: Context) {
        val app = context.applicationContext
        val alarms = ReminderAlarmStore.activeAlarms(app, now())
        if (!notificationsEnabled(app)) {
            Log.e(TAG, "Notifications disabled: ${alarms.size} alarm(s) cannot be presented")
            return
        }
        for (spec in alarms) post(app, spec.key, NOTIFICATION_ID_FALLBACK, buildFallbackNotification(app, spec))
    }

    fun cancelFallback(context: Context, alarms: Collection<ReminderAlarmSpec>) {
        for (spec in alarms) cancel(context, spec.key, NOTIFICATION_ID_FALLBACK)
    }

    private fun cancelNotifications(context: Context, keys: Collection<String>) {
        for (k in keys) {
            cancel(context, k, NOTIFICATION_ID_FALLBACK)
            cancel(context, k, NOTIFICATION_ID_PENDING)
        }
    }

    fun notificationsEnabled(context: Context): Boolean = manager(context).areNotificationsEnabled()

    private fun manager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun post(context: Context, tag: String, id: Int, notification: Notification) {
        try {
            manager(context).notify(tag, id, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Unable to post notification: ${e.message}")
        }
    }

    private fun cancel(context: Context, tag: String, id: Int) = manager(context).cancel(tag, id)

    private fun alarmAudioAttributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = manager(context)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALARM, "Alarme de rappel", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alarme sonore tant que la disponibilit\u00e9 n'est pas confirm\u00e9e"
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_FALLBACK, "Alarme de rappel (secours)", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Utilis\u00e9e lorsque le service d'alarme ne peut pas d\u00e9marrer"
                setSound(Settings.System.DEFAULT_ALARM_ALERT_URI, alarmAudioAttributes())
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_PENDING, "Rappel en attente", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Rappels dont le son a \u00e9t\u00e9 coup\u00e9 mais non confirm\u00e9s"
            },
        )
    }

    @Suppress("DEPRECATION")
    private fun builder(context: Context, channel: String): Notification.Builder {
        ensureChannels(context)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            Notification.Builder(context).setPriority(
                if (channel == CHANNEL_PENDING) Notification.PRIORITY_LOW else Notification.PRIORITY_MAX,
            )
        }
    }

    private fun immutable(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

    private fun openIntent(context: Context, spec: ReminderAlarmSpec?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (spec != null) {
            intent.setAction(ACTION_OPEN)
                .putExtra(EXTRA_ORDER_ID, spec.orderId)
                .putExtra(EXTRA_DRIVER_ID, spec.driverId)
                .putExtra(EXTRA_GENERATION, spec.generation)
        }
        return PendingIntent.getActivity(
            context, spec?.key?.hashCode() ?: 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or immutable(),
        )
    }

    private fun silenceIntent(context: Context, keys: List<String>): PendingIntent {
        val intent = Intent(context, ReminderAlarmActionReceiver::class.java)
            .setAction(ACTION_SILENCE)
            .putExtra(EXTRA_KEYS, keys.toTypedArray())
        return PendingIntent.getBroadcast(
            context, keys.sorted().joinToString("|").hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or immutable(),
        )
    }

    private fun timeoutAfter(b: Notification.Builder, expiresAt: Long) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) b.setTimeoutAfter((expiresAt - now()).coerceAtLeast(1000L))
    }

    @Suppress("DEPRECATION")
    fun buildServiceNotification(context: Context, alarms: List<ReminderAlarmSpec>): Notification {
        val first = alarms.minByOrNull { it.expiresAt }
        val text = when (alarms.size) {
            0 -> "V\u00e9rification des rappels\u2026"
            1 -> "Confirmez votre disponibilit\u00e9 pour la course."
            else -> "${alarms.size} courses attendent votre confirmation."
        }
        val b = builder(context, CHANNEL_ALARM)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(TITLE)
            .setContentText(text)
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(openIntent(context, first))
        if (alarms.isNotEmpty()) {
            b.addAction(android.R.drawable.ic_lock_silent_mode, "Couper le son", silenceIntent(context, alarms.map { it.key }))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return b.build()
    }

    @Suppress("DEPRECATION")
    private fun buildFallbackNotification(context: Context, spec: ReminderAlarmSpec): Notification {
        val silence = silenceIntent(context, listOf(spec.key))
        val b = builder(context, CHANNEL_FALLBACK)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(TITLE)
            .setContentText("Confirmez votre disponibilit\u00e9 pour la course.")
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setContentIntent(openIntent(context, spec))
            .setDeleteIntent(silence)
            .addAction(android.R.drawable.ic_lock_silent_mode, "Couper le son", silence)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            b.setSound(Settings.System.DEFAULT_ALARM_ALERT_URI, alarmAudioAttributes())
        }
        timeoutAfter(b, spec.expiresAt)
        return b.build().apply { flags = flags or Notification.FLAG_INSISTENT }
    }

    private fun buildPendingNotification(context: Context, spec: ReminderAlarmSpec): Notification {
        val b = builder(context, CHANNEL_PENDING)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(TITLE)
            .setContentText("Son coup\u00e9 \u2014 confirmation toujours requise.")
            .setCategory(Notification.CATEGORY_REMINDER)
            .setOnlyAlertOnce(true)
            .setContentIntent(openIntent(context, spec))
        timeoutAfter(b, spec.expiresAt)
        return b.build()
    }
}