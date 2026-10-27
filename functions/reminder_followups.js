"use strict";

const crypto = require("node:crypto");
const { Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const { course } = require("./reminder_logic");

function followupDue(job, now) {
  if (!job || job.followupVersion !== 1 || !["sent", "unconfirmed"].includes(job.state) ||
      !job.sentAt?.toMillis) return { alarm: false, alert: false };
  const elapsed = now - job.sentAt.toMillis();
  return {
    alarm: elapsed >= 60000 && !job.alarmSentAt && !job.alarmExpiredAt,
    alert: elapsed >= 300000 && !job.noResponseAlertId,
  };
}

function register(db, adminId) {
  const reminders = db.collection("DriverReminders");

  async function processReminder(ref) {
    const lease = crypto.randomUUID();
    const claimed = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(ref);
      const job = fresh.data();
      const due = followupDue(job, Date.now());
      if (!due.alarm && !due.alert) return null;
      const order = await tx.get(db.collection("Orders").doc(ref.id));
      const planned = course(order.data());
      if (!planned || planned.generation !== job.generation) {
        tx.update(ref, { state: "cancelled" });
        return null;
      }
      const updates = {};
      if (due.alarm && planned.departure <= Date.now()) {
        updates.alarmExpiredAt = Timestamp.now();
      }
      if (due.alert) {
        const alertId = crypto.createHash("sha256")
          .update(JSON.stringify(["no_response", ref.id, job.generation, job.sentAt.toMillis()]))
          .digest("hex");
        const alertRef = db.collection("DriverTravelAlerts").doc(alertId);
        const existing = await tx.get(alertRef);
        if (!existing.exists) {
          tx.create(alertRef, {
            kind: "no_response",
            orderId: ref.id, driverId: job.driverId, generation: job.generation,
            adminId, reminderSentAt: job.sentAt,
            departureDate: Timestamp.fromMillis(planned.departure),
            createdAt: Timestamp.now(), state: "pending", attempts: 0,
            nextAttemptAt: Timestamp.now(), deliveredTokenIds: [],
          });
        }
        updates.noResponseAlertId = alertId;
      }
      const canSend = due.alarm && planned.departure > Date.now() &&
        (!job.alarmNextAttemptAt || job.alarmNextAttemptAt.toMillis() <= Date.now());
      if (canSend) {
        updates.alarmLease = lease;
        updates.alarmNextAttemptAt = Timestamp.fromMillis(Date.now() + 60000);
      }
      if (Object.keys(updates).length) tx.update(ref, updates);
      return canSend ? { ...job, lease, departure: planned.departure } : null;
    });
    if (!claimed) return;
    try {
      const registrations = await db.collection("DriverPushTokens")
        .where("driverId", "==", claimed.driverId).get();
      if (registrations.empty) throw new Error("Aucun appareil chauffeur enregistré");
      const delivered = new Set(claimed.alarmDeliveredTokenIds ?? []);
      for (let offset = 0; offset < registrations.docs.length; offset += 500) {
        // Recheck confirmation and attribution immediately before each FCM batch.
        const [fresh, order] = await Promise.all([
          ref.get(), db.collection("Orders").doc(ref.id).get(),
        ]);
        const job = fresh.data();
        const planned = course(order.data());
        if (!job || !["sent", "unconfirmed"].includes(job.state) ||
            job.generation !== claimed.generation || !planned ||
            planned.generation !== claimed.generation || planned.departure <= Date.now()) return;
        const batch = registrations.docs.slice(offset, offset + 500)
          .filter((entry) => !delivered.has(entry.id));
        if (!batch.length) continue;
        const result = await getMessaging().sendEachForMulticast({
          tokens: batch.map((entry) => entry.data().token),
          data: {
            type: "driver_reminder_alarm", orderId: ref.id,
            driverId: claimed.driverId, generation: claimed.generation,
            alarmNotBefore: String(claimed.sentAt.toMillis() + 60000),
            expiresAt: String(claimed.departure),
          },
          android: {
            priority: "high",
            ttl: Math.max(0, claimed.departure - Date.now()),
          },
          apns: {
            headers: {
              "apns-push-type": "alert",
              "apns-priority": "10",
              "apns-expiration": String(Math.floor(claimed.departure / 1000)),
            },
            payload: { aps: {
              alert: {
                title: "Confirmez votre disponibilité",
                body: "Votre rappel de course reste sans réponse. Ouvrez la course pour confirmer.",
              },
              sound: "default",
            } },
          },
        });
        for (let i = 0; i < result.responses.length; i++) {
          const response = result.responses[i];
          if (response.success) delivered.add(batch[i].id);
          else {
            logger.warn("Relance sonore refusée", { orderId: ref.id, code: response.error?.code });
            if (["messaging/registration-token-not-registered", "messaging/invalid-registration-token"]
              .includes(response.error?.code)) await batch[i].ref.delete();
          }
        }
        await db.runTransaction(async (tx) => {
          const fresh = await tx.get(ref);
          if (fresh.data()?.generation === claimed.generation &&
              fresh.data()?.alarmLease === lease) {
            tx.update(ref, { alarmDeliveredTokenIds: [...delivered] });
          }
        });
      }
      if (!delivered.size) throw new Error("Aucune relance sonore acceptée par FCM");
      const remaining = await db.collection("DriverPushTokens")
        .where("driverId", "==", claimed.driverId).get();
      if (remaining.docs.some((entry) => !delivered.has(entry.id))) {
        throw new Error("Certains appareils restent à relancer");
      }
      await db.runTransaction(async (tx) => {
        const fresh = await tx.get(ref);
        if (fresh.data()?.generation === claimed.generation &&
            fresh.data()?.alarmLease === lease) {
          tx.update(ref, { alarmSentAt: Timestamp.now() });
        }
      });
    } catch (error) {
      logger.error("Relance sonore impossible", { orderId: ref.id, message: error.message });
      await db.runTransaction(async (tx) => {
        const fresh = await tx.get(ref);
        if (fresh.data()?.generation === claimed.generation &&
            fresh.data()?.alarmLease === lease) {
          tx.update(ref, { alarmLastError: error.message });
        }
      });
    }
  }

  async function processFollowups() {
    for (const state of ["sent", "unconfirmed"]) {
      const jobs = await reminders.where("state", "==", state).get();
      for (const job of jobs.docs) {
        try {
          await processReminder(job.ref);
        } catch (error) {
          logger.error("Suivi de rappel impossible", { orderId: job.id, message: error.message });
        }
      }
    }
  }

  const stopDriverReminderAlarm = onDocumentWritten({
    document: "DriverReminders/{orderId}", region: "europe-west1", retry: true,
  }, async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before?.sentAt || !before.generation || !before.driverId) return;
    const changed = !after || after.generation !== before.generation ||
      after.driverId !== before.driverId ||
      (after.state !== before.state && ["confirmed", "cancelled", "unconfirmed"].includes(after.state));
    if (!changed) return;
    const registrations = await db.collection("DriverPushTokens")
      .where("driverId", "==", before.driverId).get();
    for (let offset = 0; offset < registrations.docs.length; offset += 500) {
      const batch = registrations.docs.slice(offset, offset + 500);
      const result = await getMessaging().sendEachForMulticast({
        tokens: batch.map((entry) => entry.data().token),
        data: {
          type: "driver_reminder_alarm_stop", orderId: event.params.orderId,
          driverId: before.driverId, generation: before.generation,
        },
        android: { priority: "high", ttl: 3600000 },
        apns: {
          headers: { "apns-push-type": "background", "apns-priority": "5" },
          payload: { aps: { contentAvailable: true } },
        },
      });
      let retry = false;
      for (let i = 0; i < result.responses.length; i++) {
        const response = result.responses[i];
        if (response.success) continue;
        logger.warn("Arrêt alarme FCM refusé", { orderId: event.params.orderId, code: response.error?.code });
        if (["messaging/registration-token-not-registered", "messaging/invalid-registration-token"]
          .includes(response.error?.code)) await batch[i].ref.delete();
        else retry = true;
      }
      if (retry) throw new Error("Arrêt de l’alarme non distribué à tous les appareils");
    }
  });

  return { processFollowups, stopDriverReminderAlarm };
}

module.exports = { followupDue, register };
