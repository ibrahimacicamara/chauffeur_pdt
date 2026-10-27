"use strict";

const crypto = require("node:crypto");
const { Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { course, validatePosition } = require("./reminder_logic");
const { computeTravel } = require("./google_routes");

const ADMIN_UID = "YGE0x3Im8XUtmxWBtD740mszQ3B2";
const mapsKey = defineSecret("GOOGLE_MAPS_API_KEY");

function checkCourse(data, uid, generation, now) {
  const planned = course(data);
  if (!planned || planned.driverId !== uid) {
    throw new HttpsError("permission-denied", "Cette course ne vous est plus attribuée.");
  }
  if (planned.generation !== generation) {
    throw new HttpsError("failed-precondition", "La course a changé. Rechargez le rappel.");
  }
  if (now < planned.due || now >= planned.departure) {
    throw new HttpsError("failed-precondition", "La confirmation est possible uniquement entre H-1 et le départ.");
  }
  return planned;
}

function confirmationResult(data) {
  return {
    durationSeconds: data.durationSeconds,
    routeDistanceMeters: data.routeDistanceMeters,
    adminAlertId: data.adminAlertId ?? null,
  };
}

function register(db, { calculateTravel = computeTravel } = {}) {
  const reminders = db.collection("DriverReminders");
  const alerts = db.collection("DriverTravelAlerts");

  const confirmDriverAvailability = onCall({
    region: "europe-west1", secrets: [mapsKey], timeoutSeconds: 60,
  }, async (request) => {
    if (!request.auth ||
        request.auth.token?.firebase?.sign_in_provider === "anonymous") {
      throw new HttpsError("unauthenticated", "Connectez-vous avec un compte chauffeur.");
    }
    const { orderId, generation, position } = request.data ?? {};
    if (typeof orderId !== "string" || !orderId || orderId.includes("/") ||
        typeof generation !== "string" || !generation) {
      throw new HttpsError("invalid-argument", "Course ou rappel invalide.");
    }
    let fix;
    try {
      fix = validatePosition(position, Date.now());
    } catch {
      throw new HttpsError("invalid-argument", "Position GPS invalide ou trop ancienne. Réessayez.");
    }
    const uid = request.auth.uid;
    const orderRef = db.collection("Orders").doc(orderId);
    const reminderRef = reminders.doc(orderId);
    const [order, reminder, driver] = await Promise.all([
      orderRef.get(), reminderRef.get(), db.collection("Drivers").doc(uid).get(),
    ]);
    if (!driver.exists) throw new HttpsError("permission-denied", "Profil chauffeur introuvable.");
    const planned = checkCourse(order.data(), uid, generation, Date.now());
    const existing = reminder.data();
    if (!existing || existing.generation !== generation || existing.driverId !== uid ||
        existing.state === "cancelled") {
      throw new HttpsError("failed-precondition", "Rappel indisponible. Rechargez la course.");
    }
    if (existing.state === "confirmed" && Number.isFinite(existing.durationSeconds) &&
        existing.confirmationDepartureAddress === planned.address) {
      return confirmationResult(existing);
    }
    let travel;
    try {
      travel = await calculateTravel(fix, planned.address, mapsKey.value());
    } catch (error) {
      logger.error("Calcul du trajet impossible", { orderId, code: error.code ?? "internal" });
      if (error instanceof HttpsError) throw error;
      throw new HttpsError("unavailable", "Calcul du trajet impossible. Réessayez.");
    }
    if (!Number.isFinite(travel.durationSeconds) || travel.durationSeconds < 0 ||
        !Number.isFinite(travel.routeDistanceMeters) || travel.routeDistanceMeters < 0) {
      throw new HttpsError("unavailable", "Le trajet calculé est invalide. Réessayez.");
    }
    const alertId = crypto.createHash("sha256")
      .update(JSON.stringify([orderId, generation, planned.address])).digest("hex");
    return db.runTransaction(async (tx) => {
      const [freshOrder, freshReminder, existingAlert] = await Promise.all([
        tx.get(orderRef), tx.get(reminderRef), tx.get(alerts.doc(alertId)),
      ]);
      const current = checkCourse(freshOrder.data(), uid, generation, Date.now());
      if (current.address !== planned.address) {
        throw new HttpsError("failed-precondition", "Le départ a changé. Réessayez.");
      }
      const job = freshReminder.data();
      if (!job || job.generation !== generation || job.driverId !== uid || job.state === "cancelled") {
        throw new HttpsError("failed-precondition", "Le rappel a changé. Rechargez la course.");
      }
      if (job.state === "confirmed" && Number.isFinite(job.durationSeconds) &&
          job.confirmationDepartureAddress === planned.address) {
        return confirmationResult(job);
      }
      const confirmedAt = Timestamp.now();
      const late = travel.durationSeconds > 3600;
      const result = {
        state: "confirmed",
        confirmationDepartureAddress: planned.address,
        confirmedAt,
        positionCapturedAt: Timestamp.fromMillis(fix.capturedAt),
        position: { latitude: fix.latitude, longitude: fix.longitude },
        ...travel,
        estimatedArrivalAt: Timestamp.fromMillis(confirmedAt.toMillis() + travel.durationSeconds * 1000),
        adminAlertId: late ? alertId : null,
      };
      tx.update(reminderRef, result);
      if (late && !existingAlert.exists) {
        tx.create(alerts.doc(alertId), {
          orderId, driverId: uid, generation,
          adminId: ADMIN_UID,
          durationSeconds: travel.durationSeconds,
          routeDistanceMeters: travel.routeDistanceMeters,
          departureDate: Timestamp.fromMillis(planned.departure),
          createdAt: confirmedAt,
          state: "pending", attempts: 0,
          nextAttemptAt: confirmedAt, deliveredTokenIds: [],
        });
      }
      return confirmationResult(result);
    });
  });

  async function sendAlert(alertId) {
    const ref = alerts.doc(alertId);
    const lease = crypto.randomUUID();
    const claimed = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const alert = snapshot.data();
      if (!alert || alert.state !== "pending" ||
          alert.nextAttemptAt.toMillis() > Date.now()) return null;
      const [order, reminder] = await Promise.all([
        tx.get(db.collection("Orders").doc(alert.orderId)),
        tx.get(reminders.doc(alert.orderId)),
      ]);
      const planned = course(order.data());
      const job = reminder.data();
      const validAlert = alert.kind === "no_response"
        ? job && ["sent", "unconfirmed"].includes(job.state) &&
          job.followupVersion === 1 && job.sentAt?.toMillis() <= Date.now() - 300000 &&
          job.noResponseAlertId === alertId && job.generation === alert.generation &&
          job.sentAt?.toMillis() === alert.reminderSentAt?.toMillis()
        : job?.state === "confirmed" && job?.adminAlertId === alertId &&
          job?.confirmationDepartureAddress === planned?.address;
      if (!planned || planned.generation !== alert.generation || !validAlert) {
        tx.update(ref, { state: "cancelled" });
        return null;
      }
      tx.update(ref, {
        lease, attempts: alert.attempts + 1,
        nextAttemptAt: Timestamp.fromMillis(Date.now() + 5 * 60000),
      });
      return { ...alert, lease };
    });
    if (!claimed) return;
    try {
      const devices = await db.collection("DriverPushTokens")
        .where("driverId", "==", ADMIN_UID).get();
      if (devices.empty) throw new Error("Aucun appareil administrateur enregistré");
      const delivered = new Set(claimed.deliveredTokenIds);
      for (let offset = 0; offset < devices.docs.length; offset += 500) {
        if (claimed.kind === "no_response") {
          const [freshReminder, freshOrder] = await Promise.all([
            reminders.doc(claimed.orderId).get(),
            db.collection("Orders").doc(claimed.orderId).get(),
          ]);
          const current = freshReminder.data();
          const planned = course(freshOrder.data());
          if (!current || !["sent", "unconfirmed"].includes(current.state) ||
              current.generation !== claimed.generation ||
              current.noResponseAlertId !== alertId || !planned ||
              planned.generation !== claimed.generation) {
            await db.runTransaction(async (tx) => {
              const fresh = await tx.get(ref);
              if (fresh.data()?.lease === lease && fresh.data()?.state === "pending") {
                tx.update(ref, { state: "cancelled" });
              }
            });
            return;
          }
        }
        const batch = devices.docs.slice(offset, offset + 500)
          .filter((device) => !delivered.has(device.id));
        if (!batch.length) continue;
        const result = await getMessaging().sendEachForMulticast({
          tokens: batch.map((device) => device.data().token),
          notification: {
            title: claimed.kind === "no_response"
              ? "Chauffeur sans réponse" : "Alerte trajet chauffeur",
            body: claimed.kind === "no_response"
              ? "Le chauffeur n’a pas confirmé sa disponibilité cinq minutes après le rappel."
              : `Le trajet estimé vers le départ dépasse une heure (${Math.ceil(claimed.durationSeconds / 60)} min).`,
          },
          data: {
            type: "driver_travel_alert", driverId: ADMIN_UID,
            orderId: claimed.orderId, alertId,
            alertKind: claimed.kind ?? "travel_time",
          },
          android: { priority: "high" },
          apns: { payload: { aps: { sound: "default" } } },
        });
        for (let i = 0; i < result.responses.length; i++) {
          const response = result.responses[i];
          if (response.success) {
            delivered.add(batch[i].id);
          } else {
            logger.warn("Alerte trajet FCM refusée", { alertId, code: response.error?.code });
            if (["messaging/registration-token-not-registered", "messaging/invalid-registration-token"]
              .includes(response.error?.code)) await batch[i].ref.delete();
          }
        }
        await db.runTransaction(async (tx) => {
          const latest = await tx.get(ref);
          if (latest.data()?.lease === lease && latest.data()?.state === "pending") {
            tx.update(ref, { deliveredTokenIds: [...delivered] });
          }
        });
      }
      if (!delivered.size) throw new Error("Aucune alerte acceptée par FCM");
      // Keep retries for devices not yet reached without resending successful tokens.
      const remaining = await db.collection("DriverPushTokens")
        .where("driverId", "==", ADMIN_UID).get();
      if (remaining.docs.some((device) => !delivered.has(device.id))) {
        throw new Error("Certains appareils administrateur restent à notifier");
      }
      await db.runTransaction(async (tx) => {
        const latest = await tx.get(ref);
        if (latest.data()?.lease === lease && latest.data()?.state === "pending") {
          tx.update(ref, { state: "sent", sentAt: Timestamp.now() });
        }
      });
    } catch (error) {
      logger.error("Alerte trajet non envoyée", { alertId, message: error.message });
      await db.runTransaction(async (tx) => {
        const latest = await tx.get(ref);
        if (latest.data()?.lease === lease && latest.data()?.state === "pending") {
          tx.update(ref, {
            state: latest.data().attempts >= 5 ? "failed" : "pending",
            lastError: error.message,
          });
        }
      });
    }
  }

  async function sendPendingAlerts() {
    const pending = await alerts.where("state", "==", "pending").get();
    for (const alert of pending.docs) await sendAlert(alert.id);
  }

  return {
    functions: {
      confirmDriverAvailability,
      sendDriverTravelAlert: onDocumentCreated({
        document: "DriverTravelAlerts/{alertId}", region: "europe-west1", retry: true,
      }, (event) => sendAlert(event.params.alertId)),
    },
    sendPendingAlerts,
  };
}

module.exports = { register, checkCourse, ADMIN_UID };
