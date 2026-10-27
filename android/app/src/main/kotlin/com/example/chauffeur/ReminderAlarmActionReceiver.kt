package com.example.chauffeur

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** Handles the "Couper le son" notification action and fallback-notification dismissal. */
class ReminderAlarmActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ReminderAlarmController.ACTION_SILENCE) return
        val keys = intent.getStringArrayExtra(ReminderAlarmController.EXTRA_KEYS)?.toList().orEmpty()
        if (keys.isEmpty()) return
        val app = context.applicationContext
        val pending = goAsync()
        ReminderAlarmController.executor.execute {
            try {
                ReminderAlarmController.silence(app, keys)
            } catch (e: Exception) {
                Log.e(ReminderAlarmController.TAG, "Silence action failed", e)
            } finally {
                pending.finish()
            }
        }
    }
}