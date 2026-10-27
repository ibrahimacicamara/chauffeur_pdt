"use strict";

const crypto = require("node:crypto");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const {
  onDocumentCreated,
  onDocumentWritten,
} = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { course } = require("./reminder_logic");
const { courseCategory, hasCategory, isAvailableCourse } = require("./course_notifications");

initializeApp();
const db = getFirestore();
Object.assign(exports, require("./client_sessions").register(db));
Object.assign(exports, require("./tablet_pairing").register(db));
const availability = require("./driver_availability").register(db);
Object.assign(exports, availability.functions);
const followups = require("./reminder_followups").register(
  db, require("./driver_availability").ADMIN_UID,
);
exports.stopDriverReminderAlarm = followups.stopDriverReminderAlarm;
const region = "europe-west1";
const reminders = db.collection("DriverReminders");

async function driverUid(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Connectez-vous.");
  const driver = await db.collection("Drivers").doc(request.auth.uid).get();
  if (!driver.exists) {
    throw new HttpsError("permission-denied", "Profil chauffeur introuvable.");
  }
  return request.auth.uid;
}

exports.registerDriverPushToken = onCall({ region }, async (request) => {
  const uid = await driverUid(request);
  const token = request.data?.token;
  if (typeof token !== "string" || token.length < 10 || token.length > 4096) {
    throw new HttpsError("invalid-argument", "Jeton de notification invalide.");
  }
  const id = crypto.createHash("sha256").update(token).digest("hex");
  await db.collection("DriverPushTokens").doc(id).set({
    driverId: uid, token, updatedAt: Timestamp.now(),
  });
  return { registered: true };
});

exports.unregisterDriverPushToken = onCall({ region }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Connectez-vous.");
  const token = request.data?.token;
  if (typeof token !== "string" || token.length > 4096) {
    throw new HttpsError("invalid-argument", "Jeton invalide.");
  }
  const ref = db.collection("DriverPushTokens")
    .doc(crypto.createHash("sha256").update(token).digest("hex"));
  await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (snapshot.data()?.driverId === request.auth.uid) tx.delete(ref);
  });
  return { removed: true };
});

async function syncOrder(orderId) {
  const orderRef = db.collection("Orders").doc(orderId);
  const reminderRef = reminders.doc(orderId);
  await db.runTransaction(async (tx) => {
    const [order, reminder] = await Promise.all([tx.get(orderRef), tx.get(reminderRef)]);
    const planned = course(order.data());
    if (!planned || planned.departure <= Date.now()) {
      if (reminder.exists) tx.update(reminderRef, { state: "cancelled" });
      return;
    }
    if (reminder.data()?.generation === planned.generation &&
        reminder.data()?.state !== "cancelled" &&
        (reminder.data()?.state !== "confirmed" ||
         reminder.data()?.confirmationDepartureAddress === planned.address)) return;
    tx.set(reminderRef, {
      orderId, driverId: planned.driverId, generation: planned.generation,
      departureDate: Timestamp.fromMillis(planned.departure),
      dueAt: Timestamp.fromMillis(planned.due),
      nextAttemptAt: Timestamp.fromMillis(planned.due),
      state: "pending", attempts: 0,
    });
  });
}

exports.syncDriverReminder = onDocumentWritten({
  document: "Orders/{orderId}", region, retry: true,
}, (event) => syncOrder(event.params.orderId));

async function sendCourseNotification(orderId, category, driverId) {
  const rootRef = db.collection("DriverCourseNotifications").doc(orderId);
  const deliveryRef = rootRef.collection("deliveries").doc(driverId);
  const lease = crypto.randomUUID();
  await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(deliveryRef);
    const delivery = snapshot.data();
    if (delivery?.state === "sent" || delivery?.state === "skipped") return;
    if (
      delivery?.state === "sending" &&
      delivery.leaseUntil?.toMillis() > Date.now()
    ) {
      throw new Error(`Notification en cours pour le chauffeur ${driverId}`);
    }
    tx.set(deliveryRef, {
      state: "sending",
      lease,
      leaseUntil: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000),
      attempts: (delivery?.attempts ?? 0) + 1,
    });
  });
  const current = await deliveryRef.get();
  if (current.data()?.state !== "sending" || current.data()?.lease !== lease) {
    return;
  }

  try {
    const driverSnapshot = await db.collection("Drivers").doc(driverId).get();
    const driver = driverSnapshot.data();
    if (
      !driverSnapshot.exists ||
      driver?.available !== true ||
      !hasCategory(driver.categories, category)
    ) {
      await deliveryRef.update({
        state: "skipped",
        reason: "driver-no-longer-eligible",
        completedAt: Timestamp.now(),
        lease: null,
        leaseUntil: null,
      });
      return;
    }

    const registrations = await db.collection("DriverPushTokens")
      .where("driverId", "==", driverId).get();
    if (registrations.empty) {
      await deliveryRef.update({
        state: "skipped",
        reason: "no-registered-device",
        completedAt: Timestamp.now(),
        lease: null,
        leaseUntil: null,
      });
      return;
    }

    let successes = 0;
    for (let offset = 0; offset < registrations.docs.length; offset += 500) {
      const batch = registrations.docs.slice(offset, offset + 500);
      const result = await getMessaging().sendEachForMulticast({
        tokens: batch.map((entry) => entry.data().token),
        notification: {
          title: "Nouvelle course disponible",
          body: "Une course correspondant à vos catégories est disponible. Ouvrez l’application pour la consulter.",
        },
        data: { type: "driver_course", orderId, driverId },
        android: { priority: "high", ttl: 60 * 60 * 1000 },
        apns: {
          headers: {
            "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
          },
        },
      });
      successes += result.successCount;
      for (let index = 0; index < result.responses.length; index++) {
        const response = result.responses[index];
        if (response.success) continue;
        logger.warn("Échec de notification de course", {
          orderId,
          driverId,
          code: response.error?.code,
        });
        if (
          [
            "messaging/registration-token-not-registered",
            "messaging/invalid-registration-token",
          ].includes(response.error?.code)
        ) {
          await batch[index].ref.delete();
        }
      }
    }
    if (!successes) {
      throw new Error("Aucune notification de course acceptée par FCM");
    }
    await deliveryRef.update({
      state: "sent",
      sentAt: Timestamp.now(),
      lease: null,
      leaseUntil: null,
    });
  } catch (error) {
    await db.runTransaction(async (tx) => {
      const latest = await tx.get(deliveryRef);
      if (latest.data()?.lease !== lease || latest.data()?.state !== "sending") {
        return;
      }
      tx.update(deliveryRef, {
        state: "pending",
        lease: null,
        leaseUntil: null,
        lastError: error.message,
      });
    });
    throw error;
  }
}

async function notifyDriversForNewCourse(orderId, data) {
  if (!isAvailableCourse(data)) return;
  const category = courseCategory(data);
  if (!category) return;

  const notificationRef = db.collection("DriverCourseNotifications").doc(orderId);
  let notificationSnapshot = await notificationRef.get();
  if (!notificationSnapshot.exists) {
    const drivers = await db.collection("Drivers")
      .where("available", "==", true).get();
    const recipients = drivers.docs
      .filter((driver) => hasCategory(driver.data().categories, category))
      .map((driver) => driver.id);
    await db.runTransaction(async (tx) => {
      const existing = await tx.get(notificationRef);
      if (existing.exists) return;
      tx.create(notificationRef, {
        orderId,
        category,
        recipientIds: recipients,
        state: recipients.length ? "pending" : "skipped",
        createdAt: Timestamp.now(),
      });
    });
    notificationSnapshot = await notificationRef.get();
  }

  const notification = notificationSnapshot.data();
  if (!notification || notification.state === "sent" ||
      notification.state === "skipped") return;
  const recipients = notification.recipientIds;
  if (!Array.isArray(recipients)) {
    throw new Error(`Liste des chauffeurs invalide pour la course ${orderId}`);
  }

  for (const driverId of recipients) {
    if (typeof driverId !== "string" || !driverId || driverId.includes("/")) {
      throw new Error(`Identifiant chauffeur invalide pour la course ${orderId}`);
    }
    await sendCourseNotification(orderId, notification.category, driverId);
  }

  const deliveries = await notificationRef.collection("deliveries").get();
  const completed = new Set(
    deliveries.docs
      .filter((delivery) =>
        ["sent", "skipped"].includes(delivery.data().state),
      )
      .map((delivery) => delivery.id),
  );
  if (!recipients.every((driverId) => completed.has(driverId))) {
    throw new Error(`Notifications de course encore en attente pour ${orderId}`);
  }
  await notificationRef.update({ state: "sent", sentAt: Timestamp.now() });
}

exports.notifyDriversForNewCourse = onDocumentCreated({
  document: "Orders/{orderId}", region, retry: true,
}, (event) =>
  notifyDriversForNewCourse(event.params.orderId, event.data?.data()),
);

exports.sendDriverReminders = onSchedule({
  schedule: "every 1 minutes", region, timeZone: "Europe/Paris",
}, async () => {
  const now = Timestamp.now();
  const jobs = await reminders.where("state", "==", "pending")
    .where("nextAttemptAt", "<=", now).limit(200).get();
  for (const doc of jobs.docs) {
    let claimed;
    try {
      claimed = await db.runTransaction(async (tx) => {
        const [fresh, order] = await Promise.all([
          tx.get(doc.ref), tx.get(db.collection("Orders").doc(doc.id)),
        ]);
        const job = fresh.data();
        if (!job || job.state !== "pending" || job.nextAttemptAt.toMillis() > Date.now()) return null;
        const planned = course(order.data());
        if (!planned || planned.generation !== job.generation) {
          tx.update(doc.ref, { state: "cancelled" });
          return null;
        }
        if (planned.departure <= Date.now()) {
          tx.update(doc.ref, { state: "unconfirmed" });
          return null;
        }
        const lease = crypto.randomUUID();
        tx.update(doc.ref, {
          lease, attempts: job.attempts + 1,
          nextAttemptAt: Timestamp.fromMillis(Date.now() + 5 * 60000),
        });
        return { ...job, lease };
      });
    } catch (error) {
      logger.error("Rappel impossible à traiter", { orderId: doc.id, detail: error.message });
      continue;
    }
    if (!claimed) continue;
    try {
      const driver = await db.collection("Drivers").doc(claimed.driverId).get();
      if (!driver.exists) throw new Error("Profil chauffeur introuvable");
      const registrations = await db.collection("DriverPushTokens")
        .where("driverId", "==", claimed.driverId).get();
      if (registrations.empty) throw new Error("Aucun appareil enregistré");
      let successes = 0;
      let firstAcceptedAt;
      for (let offset = 0; offset < registrations.docs.length; offset += 500) {
        const batch = registrations.docs.slice(offset, offset + 500);
        const result = await getMessaging().sendEachForMulticast({
          tokens: batch.map((entry) => entry.data().token),
          notification: {
            title: "Votre course démarre dans moins d’une heure",
            body: "Confirmez votre disponibilité pour calculer votre trajet jusqu’au départ.",
          },
          data: {
            type: "driver_reminder", orderId: doc.id,
            driverId: claimed.driverId, generation: claimed.generation,
          },
          android: { priority: "high", ttl: Math.max(0, claimed.departureDate.toMillis() - Date.now()) },
          apns: { headers: { "apns-expiration": String(Math.floor(claimed.departureDate.toMillis() / 1000)) } },
        });
        successes += result.successCount;
        if (result.successCount > 0 && !firstAcceptedAt) firstAcceptedAt = Timestamp.now();
        for (let i = 0; i < result.responses.length; i++) {
          const response = result.responses[i];
          if (response.success) continue;
          logger.warn("Échec FCM", { orderId: doc.id, code: response.error?.code });
          if (["messaging/registration-token-not-registered", "messaging/invalid-registration-token"]
            .includes(response.error?.code)) await batch[i].ref.delete();
        }
      }
      if (!successes) throw new Error("Aucune notification acceptée par FCM");
      await db.runTransaction(async (tx) => {
        const latest = await tx.get(doc.ref);
        if (latest.data()?.lease === claimed.lease && latest.data()?.state === "pending") {
          tx.update(doc.ref, { state: "sent", sentAt: firstAcceptedAt, followupVersion: 1 });
        }
      });

    } catch (error) {
      logger.error("Rappel non envoyé", { orderId: doc.id, message: error.message });
      await db.runTransaction(async (tx) => {
        const latest = await tx.get(doc.ref);
        if (latest.data()?.lease !== claimed.lease || latest.data()?.state !== "pending") return;
        tx.update(doc.ref, {
          state: latest.data().attempts >= 5 ? "failed" : "pending",
          lastError: error.message,
        });
      });
    }
  }
  await followups.processFollowups();
  const overdue = await reminders.where("state", "==", "sent")
    .where("departureDate", "<=", now).limit(200).get();
  for (const doc of overdue.docs) {
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(doc.ref);
      if (fresh.data()?.state === "sent") tx.update(doc.ref, { state: "unconfirmed" });
    });
  }
  await availability.sendPendingAlerts();
});
