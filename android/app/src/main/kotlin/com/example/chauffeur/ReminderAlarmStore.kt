package com.example.chauffeur

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

data class ReminderAlarmSpec(
    val orderId: String,
    val driverId: String,
    val generation: String,
    val expiresAt: Long,
    val alarmNotBefore: Long,
) {
    val key: String get() = ReminderAlarmStore.key(driverId, orderId, generation)

    fun toJson(): JSONObject = JSONObject()
        .put("orderId", orderId)
        .put("driverId", driverId)
        .put("generation", generation)
        .put("expiresAt", expiresAt)
        .put("alarmNotBefore", alarmNotBefore)

    fun toMap(silenced: Boolean): Map<String, Any> = mapOf(
        "orderId" to orderId,
        "driverId" to driverId,
        "generation" to generation,
        "expiresAt" to expiresAt,
        "alarmNotBefore" to alarmNotBefore,
        "silenced" to silenced,
    )

    companion object {
        fun fromJson(json: JSONObject): ReminderAlarmSpec? = try {
            ReminderAlarmSpec(
                json.getString("orderId"),
                json.getString("driverId"),
                json.getString("generation"),
                json.getLong("expiresAt"),
                json.getLong("alarmNotBefore"),
            )
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Persisted alarm state shared by the FCM receiver, the Flutter bridge and the service.
 * Every mutation is serialized on [lock] and written synchronously with commit(); callers
 * run on ReminderAlarmController.executor except for short reads from the service.
 */
object ReminderAlarmStore {
    const val MAX_WINDOW_MS = 12L * 60 * 60 * 1000
    const val CLOCK_SKEW_MS = 2L * 60 * 1000
    private const val TOMBSTONE_TTL_MS = 48L * 60 * 60 * 1000
    private const val MAX_ID_LENGTH = 256
    private const val SEP = '\u001F'

    private const val PREFS = "reminder_alarm_store"
    private const val BOUND_DRIVER = "bound_driver"
    private const val ACTIVE = "active"
    private const val SILENCED = "silenced"
    private const val TOMBSTONES = "tombstones"
    private const val SILENCE_MARKS = "silence_marks"

    private val lock = Any()

    fun key(driverId: String, orderId: String, generation: String) =
        "$driverId$SEP$orderId$SEP$generation"

    fun validId(value: String?): Boolean =
        !value.isNullOrBlank() && value.length <= MAX_ID_LENGTH && value.indexOf(SEP) < 0

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun obj(p: SharedPreferences, name: String): JSONObject =
        try { JSONObject(p.getString(name, "{}") ?: "{}") } catch (_: Exception) { JSONObject() }

    private fun keysOf(json: JSONObject): Set<String> = json.keys().asSequence().toSet()

    fun boundDriver(context: Context): String? = synchronized(lock) {
        prefs(context).getString(BOUND_DRIVER, null)
    }

    /** Binds the signed-in driver. Returns alarm keys cleared because the UID changed. */
    fun bindDriver(context: Context, driverId: String): Set<String> = synchronized(lock) {
        val p = prefs(context)
        val previous = p.getString(BOUND_DRIVER, null)
        val editor = p.edit().putString(BOUND_DRIVER, driverId)
        var removed = emptySet<String>()
        if (previous != null && previous != driverId) {
            removed = keysOf(obj(p, ACTIVE)) + keysOf(obj(p, SILENCED))
            editor.putString(ACTIVE, "{}").putString(SILENCED, "{}")
        }
        if (!editor.commit()) throw IllegalStateException("bind_not_persisted")
        removed
    }

    /**
     * Clears every active/silenced alarm (tombstoning them so duplicates cannot ring again).
     * When [unbind] is true the driver binding is removed too. Returns the removed keys.
     */
    fun clearAll(context: Context, unbind: Boolean, now: Long): Set<String> = synchronized(lock) {
        val p = prefs(context)
        val removed = keysOf(obj(p, ACTIVE)) + keysOf(obj(p, SILENCED))
        val tombstones = prune(obj(p, TOMBSTONES), now)
        for (k in removed) tombstones.put(k, now + TOMBSTONE_TTL_MS)
        val editor = p.edit()
            .putString(ACTIVE, "{}")
            .putString(SILENCED, "{}")
            .putString(TOMBSTONES, tombstones.toString())
        if (unbind) editor.remove(BOUND_DRIVER)
        if (!editor.commit()) throw IllegalStateException("clear_not_persisted")
        removed
    }

    /**
     * Validates and atomically registers an alarm. Returns null when accepted,
     * otherwise a machine-readable rejection reason.
     */
    fun admit(context: Context, spec: ReminderAlarmSpec, now: Long): String? = synchronized(lock) {
        if (!validId(spec.orderId) || !validId(spec.driverId) || !validId(spec.generation)) {
            return "invalid_identifiers"
        }
        val p = prefs(context)
        val bound = p.getString(BOUND_DRIVER, null) ?: return "not_bound"
        if (bound != spec.driverId) return "driver_mismatch"
        if (spec.expiresAt <= now) return "expired"
        if (spec.expiresAt - now > MAX_WINDOW_MS) return "invalid_time_bounds"
        if (spec.alarmNotBefore > spec.expiresAt) return "invalid_time_bounds"
        if (spec.alarmNotBefore - now > CLOCK_SKEW_MS) return "too_early"

        val tombstones = prune(obj(p, TOMBSTONES), now)
        val silenced = prune(obj(p, SILENCED), now)
        val marks = prune(obj(p, SILENCE_MARKS), now)
        val active = prune(obj(p, ACTIVE), now)
        val key = spec.key
        val result = when {
            tombstones.has(key) -> "stopped"
            silenced.has(key) || marks.has(key) -> "silenced"
            active.has(key) -> "already_active"
            else -> {
                active.put(key, spec.toJson())
                null
            }
        }
        p.edit()
            .putString(TOMBSTONES, tombstones.toString())
            .putString(SILENCED, silenced.toString())
            .putString(SILENCE_MARKS, marks.toString())
            .putString(ACTIVE, active.toString())
            .commit()
        result
    }

    /**
     * Tombstones exactly (driverId, orderId, generation) so a late or duplicated alarm for that
     * generation can never ring afterwards. Returns true when an active/silenced alarm was removed.
     */
    fun stop(context: Context, driverId: String, orderId: String, generation: String, now: Long): Boolean =
        synchronized(lock) {
            val p = prefs(context)
            val k = key(driverId, orderId, generation)
            val tombstones = prune(obj(p, TOMBSTONES), now).put(k, now + TOMBSTONE_TTL_MS)
            val active = obj(p, ACTIVE)
            val silenced = obj(p, SILENCED)
            val removedActive = active.remove(k) != null
            val removedSilenced = silenced.remove(k) != null
            val committed = p.edit()
                .putString(TOMBSTONES, tombstones.toString())
                .putString(ACTIVE, active.toString())
                .putString(SILENCED, silenced.toString())
                .commit()
            if (!committed) throw IllegalStateException("stop_not_persisted")
            removedActive || removedSilenced
        }

    /**
     * Moves active alarms to the silenced set. Keys that are not ringing yet get a silence mark so a
     * late alarm message for that generation stays quiet. Silencing never implies a confirmation.
     * Returns the alarms that were actually ringing; throws if the state could not be persisted.
     */
    fun silence(context: Context, keys: Collection<String>, now: Long): List<ReminderAlarmSpec> =
        synchronized(lock) {
            val p = prefs(context)
            val active = prune(obj(p, ACTIVE), now)
            val silenced = prune(obj(p, SILENCED), now)
            val marks = prune(obj(p, SILENCE_MARKS), now)
            val moved = mutableListOf<ReminderAlarmSpec>()
            for (k in keys) {
                val spec = active.optJSONObject(k)?.let(ReminderAlarmSpec::fromJson)
                if (spec == null) {
                    if (!silenced.has(k)) marks.put(k, now + TOMBSTONE_TTL_MS)
                    continue
                }
                active.remove(k)
                silenced.put(k, spec.toJson())
                moved += spec
            }
            val committed = p.edit()
                .putString(ACTIVE, active.toString())
                .putString(SILENCED, silenced.toString())
                .putString(SILENCE_MARKS, marks.toString())
                .commit()
            if (!committed) throw IllegalStateException("silence_not_persisted")
            moved
        }

    /** Active alarms still inside their window and bound to the current driver. */
    fun activeAlarms(context: Context, now: Long): List<ReminderAlarmSpec> = synchronized(lock) {
        val p = prefs(context)
        val bound = p.getString(BOUND_DRIVER, null)
        val tombstones = obj(p, TOMBSTONES)
        val active = prune(obj(p, ACTIVE), now)
        val result = mutableListOf<ReminderAlarmSpec>()
        for (k in active.keys().asSequence().toList()) {
            val spec = active.optJSONObject(k)?.let(ReminderAlarmSpec::fromJson)
            if (spec == null || spec.driverId != bound || tombstones.has(k)) {
                active.remove(k)
            } else {
                result += spec
            }
        }
        p.edit().putString(ACTIVE, active.toString()).commit()
        result
    }

    fun silencedAlarms(context: Context, now: Long): List<ReminderAlarmSpec> = synchronized(lock) {
        val p = prefs(context)
        val silenced = prune(obj(p, SILENCED), now)
        p.edit().putString(SILENCED, silenced.toString()).commit()
        silenced.keys().asSequence()
            .mapNotNull { silenced.optJSONObject(it)?.let(ReminderAlarmSpec::fromJson) }
            .toList()
    }

    private fun expiryOf(value: Any?): Long = when (value) {
        is Number -> value.toLong()
        is JSONObject -> value.optLong("expiresAt", 0L)
        else -> 0L
    }

    private fun prune(json: JSONObject, now: Long): JSONObject {
        for (k in json.keys().asSequence().toList()) {
            if (expiryOf(json.opt(k)) <= now) json.remove(k)
        }
        return json
    }
}