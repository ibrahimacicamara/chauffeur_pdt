package com.example.chauffeur

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Receives FCM deliveries (com.google.android.c2dm.intent.RECEIVE) in parallel with the
 * Firebase/FlutterFire receivers, which keep working unchanged. Handles only the data-only
 * driver_reminder_alarm / driver_reminder_alarm_stop types, natively, whatever the app state.
 */
class ReminderAlarmFcmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.google.android.c2dm.intent.RECEIVE") return
        val extras = intent.extras ?: return
        val messageType = extras.getString("message_type")
        if (messageType != null && messageType != "gcm") return
        val type = extras.getString("type")
        if (type != ReminderAlarmController.TYPE_ALARM && type != ReminderAlarmController.TYPE_STOP) return

        val app = context.applicationContext
        val messageId = extras.getString("google.message_id")
        val priority = extras.getString("google.delivered_priority")
        val orderId = extras.getString("orderId")
        val driverId = extras.getString("driverId")
        val generation = extras.getString("generation")
        val expiresAt = extras.getString("expiresAt")?.trim()?.toLongOrNull()
        val notBefore = extras.getString("alarmNotBefore")?.trim()?.toLongOrNull()
        Log.i(ReminderAlarmController.TAG, "FCM $type message=$messageId deliveredPriority=$priority")

        val pending = goAsync()
        ReminderAlarmController.executor.execute {
            try {
                if (!ReminderAlarmStore.validId(orderId) || !ReminderAlarmStore.validId(driverId) ||
                    !ReminderAlarmStore.validId(generation)
                ) {
                    Log.w(ReminderAlarmController.TAG, "FCM $type ignored: invalid identifiers")
                } else if (type == ReminderAlarmController.TYPE_STOP) {
                    ReminderAlarmController.stop(app, driverId!!, orderId!!, generation!!)
                } else if (expiresAt == null || notBefore == null) {
                    Log.w(ReminderAlarmController.TAG, "FCM alarm ignored: invalid expiresAt/alarmNotBefore")
                } else {
                    val spec = ReminderAlarmSpec(orderId!!, driverId!!, generation!!, expiresAt, notBefore)
                    ReminderAlarmController.startAlarm(app, spec, "fcm:$messageId")
                }
            } catch (e: Exception) {
                Log.e(ReminderAlarmController.TAG, "FCM $type handling failed", e)
            } finally {
                pending.finish()
            }
        }
    }
}