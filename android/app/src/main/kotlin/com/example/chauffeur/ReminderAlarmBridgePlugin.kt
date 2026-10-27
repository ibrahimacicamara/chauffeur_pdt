package com.example.chauffeur

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** In-app Flutter bridge (UI engine). Background alarms never depend on it. */
class ReminderAlarmBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.example.chauffeur/reminder_alarm"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val changeListener: () -> Unit = { channel?.invokeMethod("onAlarmsChanged", null) }
    private val openListener: () -> Unit = { channel?.invokeMethod("onAlarmOpened", null) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        ReminderAlarmController.addChangeListener(changeListener)
        ReminderAlarmOpens.addListener(openListener)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ReminderAlarmController.removeChangeListener(changeListener)
        ReminderAlarmOpens.removeListener(openListener)
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    private class Rejected(val code: String, message: String) : Exception(message)

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        ReminderAlarmController.executor.execute {
            val outcome = runCatching(block)
            ReminderAlarmController.mainHandler.post {
                outcome.fold(
                    { result.success(it) },
                    {
                        if (it is Rejected) result.error(it.code, it.message, null)
                        else result.error("reminder_alarm_error", it.message ?: it.javaClass.simpleName, null)
                    },
                )
            }
        }
    }

    private fun id(call: MethodCall, name: String): String {
        val value = call.argument<Any>(name) as? String
        if (!ReminderAlarmStore.validId(value)) throw Rejected("invalid_argument", "Invalid $name")
        return value!!
    }

    private fun boundDriver(ctx: Context): String =
        ReminderAlarmStore.boundDriver(ctx) ?: throw Rejected("not_bound", "No driver bound to reminder alarms")

    private fun millis(call: MethodCall, name: String): Long =
        (call.argument<Any>(name) as? Number)?.toLong() ?: throw Rejected("invalid_argument", "Invalid $name")

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("unavailable", "Bridge detached", null)
        val parsed = try {
            when (call.method) {
                "bindDriver" -> listOf(id(call, "driverId"))
                "stop", "silence" -> listOf(id(call, "orderId"), id(call, "generation"))
                "start" -> listOf(id(call, "orderId"), id(call, "driverId"), id(call, "generation"))
                else -> emptyList()
            }
        } catch (e: Rejected) {
            return result.error(e.code, e.message, null)
        }
        when (call.method) {
            "bindDriver" -> background(result) { ReminderAlarmController.bindDriver(ctx, parsed[0]); true }
            "unbindDriver" -> background(result) { ReminderAlarmController.stopAll(ctx, unbind = true); null }
            "stopAll" -> background(result) { ReminderAlarmController.stopAll(ctx, unbind = false); null }
            "stop" -> background(result) {
                ReminderAlarmController.stop(ctx, boundDriver(ctx), parsed[0], parsed[1])
                true
            }
            "silence" -> background(result) {
                val key = ReminderAlarmStore.key(boundDriver(ctx), parsed[0], parsed[1])
                ReminderAlarmController.silence(ctx, listOf(key))
                true
            }
            "activeAlarms" -> background(result) {
                val now = System.currentTimeMillis()
                ReminderAlarmStore.activeAlarms(ctx, now).map { it.toMap(false) } +
                    ReminderAlarmStore.silencedAlarms(ctx, now).map { it.toMap(true) }
            }
            "start" -> {
                val spec = try {
                    ReminderAlarmSpec(parsed[0], parsed[1], parsed[2], millis(call, "expiresAt"), millis(call, "alarmNotBefore"))
                } catch (e: Rejected) {
                    return result.error(e.code, e.message, null)
                }
                background(result) { ReminderAlarmController.startAlarm(ctx, spec, "bridge") }
            }
            "takePendingOpens" -> result.success(ReminderAlarmOpens.drain())
            "notificationsEnabled" -> result.success(ReminderAlarmController.notificationsEnabled(ctx))
            else -> result.notImplemented()
        }
    }
}