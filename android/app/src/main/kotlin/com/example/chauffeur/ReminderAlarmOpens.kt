package com.example.chauffeur

import android.content.Intent
import java.util.concurrent.CopyOnWriteArraySet

/** Queue of notification taps waiting to be consumed by Flutter (initial launch or onNewIntent). */
object ReminderAlarmOpens {
    private val pending = mutableListOf<Map<String, String>>()
    private val listeners = CopyOnWriteArraySet<() -> Unit>()

    fun addListener(listener: () -> Unit) { listeners += listener }
    fun removeListener(listener: () -> Unit) { listeners -= listener }

    /** Captures an alarm-open intent; returns true when it was one. Must run on the main thread. */
    fun capture(intent: Intent?): Boolean {
        if (intent?.action != ReminderAlarmController.ACTION_OPEN) return false
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        val orderId = intent.getStringExtra(ReminderAlarmController.EXTRA_ORDER_ID)
        val driverId = intent.getStringExtra(ReminderAlarmController.EXTRA_DRIVER_ID)
        val generation = intent.getStringExtra(ReminderAlarmController.EXTRA_GENERATION)
        // Prevent re-delivery when the activity is recreated with the same intent.
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(ReminderAlarmController.EXTRA_ORDER_ID)
        intent.removeExtra(ReminderAlarmController.EXTRA_DRIVER_ID)
        intent.removeExtra(ReminderAlarmController.EXTRA_GENERATION)
        if (!ReminderAlarmStore.validId(orderId) || !ReminderAlarmStore.validId(driverId) ||
            !ReminderAlarmStore.validId(generation)
        ) return false
        synchronized(pending) {
            pending += mapOf(
                "orderId" to orderId!!,
                "driverId" to driverId!!,
                "generation" to generation!!,
                "action" to "open",
            )
        }
        listeners.forEach { it() }
        return true
    }

    fun drain(): List<Map<String, String>> = synchronized(pending) {
        val copy = pending.toList()
        pending.clear()
        copy
    }
}