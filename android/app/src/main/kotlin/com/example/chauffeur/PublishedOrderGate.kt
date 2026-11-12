package com.example.chauffeur

import com.google.android.gms.tasks.Tasks
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Source
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Fail-closed server check for course reminders handled outside Flutter. */
object PublishedOrderGate {
    private data class HistoryEvent(
        val date: Date,
        val status: String,
        val authorId: String,
    )

    private const val TAG = "PublishedOrderGate"

    fun isActiveAssignedCourse(orderId: String, driverId: String): Boolean {
        return try {
            if (FirebaseAuth.getInstance().currentUser?.uid != driverId) {
                false
            } else {
                val database = FirebaseFirestore.getInstance()
                val order = Tasks.await(
                    database.collection("Orders").document(orderId).get(Source.SERVER),
                ).data
                val category = (order?.get("category") as? String)
                    ?.trim()
                    ?.lowercase()
                val driver = Tasks.await(
                    database.collection("Drivers").document(driverId).get(Source.SERVER),
                ).data
                val categories = (driver?.get("categories") as? List<*>)
                    ?.filterIsInstance<String>()
                    ?.map { it.trim().lowercase() }
                val rawHistory = order?.get("commandStatus") as? List<*>
                val events = rawHistory?.map { parseEvent(it) ?: return false }
                    .orEmpty()
                val latest = events.maxByOrNull { it.date.time }
                val status: String
                val assignedDriver: String?
                if (latest != null) {
                    status = latest.status
                    assignedDriver = if (status == "PENDING_ASSIGNMENT") {
                        null
                    } else {
                        events
                            .filter {
                                it.status != "PENDING_ASSIGNMENT" &&
                                    it.authorId.isNotBlank()
                            }
                            .maxByOrNull { it.date.time }
                            ?.authorId
                    }
                } else {
                    status = normalizeStatus(order?.get("status") as? String ?: "")
                    assignedDriver = (order?.get("driverId") as? String)
                        ?.takeIf { it.isNotBlank() }
                }

                order?.get("validatedForDriverAt") is Timestamp &&
                    category != null &&
                    categories != null &&
                    category in categories &&
                    assignedDriver == driverId &&
                    status in setOf("ASSIGNED", "EN_ROUTE", "ON_SITE", "CLIENT_ON_BOARD")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Unable to verify course $orderId for driver $driverId", e)
            false
        }
    }

    private fun parseEvent(raw: Any?): HistoryEvent? {
        val event = raw as? Map<*, *> ?: return null
        val date = when (val value = event["date"]) {
            is Timestamp -> value.toDate()
            is Date -> value
            is String -> listOf(
                "yyyy-MM-dd'T'HH:mm:ss.SSSX",
                "yyyy-MM-dd'T'HH:mm:ssX",
            ).firstNotNullOfOrNull { pattern ->
                runCatching {
                    SimpleDateFormat(pattern, Locale.US)
                        .apply { isLenient = false }
                        .parse(value)
                }.getOrNull()
            }
            else -> null
        } ?: return null
        val status = normalizeStatus(event["status"] as? String ?: "")
        val authorId = event["id"] as? String ?: return null
        if (status.isEmpty()) return null
        return HistoryEvent(date, status, authorId)
    }

    private fun normalizeStatus(raw: String): String {
        val name = raw.substringAfterLast('.')
            .trim()
            .uppercase()
            .replace('-', '_')
            .replace(' ', '_')
        return when (name) {
            "EN_ATTENTE", "PENDING" -> "PENDING_ASSIGNMENT"
            "ACCEPTÉE", "ACCEPTEE", "ACCEPTED" -> "ASSIGNED"
            "EN_ROUTE", "EN_COURS", "IN_PROGRESS" -> "EN_ROUTE"
            "SUR_PLACE" -> "ON_SITE"
            "CLIENT_À_BORD", "CLIENT_A_BORD" -> "CLIENT_ON_BOARD"
            "TERMINÉE", "TERMINEE", "COMPLETED" -> "COMPLETED"
            "ANNULÉE", "ANNULEE", "CANCELLED", "CANCELED" -> "CANCELLED"
            "CLIENT_ABSENT", "NO_SHOW" -> "NO_SHOW"
            "INTERROMPUE", "INTERRUPTED" -> "INTERRUPTED"
            else -> name
        }
    }
}
