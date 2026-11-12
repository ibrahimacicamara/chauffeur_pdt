"use strict";

// Suppression de compte chauffeur à la demande (App Store 5.1.1(v)).
// Les courses passées sont conservées pour la comptabilité, avec le chauffeur
// remplacé par un pseudonyme ; les courses à venir sont remises en attente.

const crypto = require("node:crypto");
const { getAuth } = require("firebase-admin/auth");
const { FieldValue, Timestamp } = require("firebase-admin/firestore");
const { HttpsError, onCall } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

const region = "europe-west1";
// Mêmes statuts que la libération manuelle côté application.
const RELEASABLE = new Set(["ASSIGNED", "EN_ROUTE", "ON_SITE"]);

function statusName(raw) {
  return String(raw ?? "").replace(/^OrderStatus\./, "").toUpperCase()
    .replace(/[-\s]/g, "_");
}

function eventTime(event) {
  const date = event?.date;
  if (date && typeof date.toMillis === "function") return date.toMillis();
  if (typeof date === "number") return date;
  const parsed = Date.parse(date);
  return Number.isNaN(parsed) ? 0 : parsed;
}

function latestEvent(history) {
  let latest = null;
  for (const event of history) {
    if (!latest || eventTime(event) >= eventTime(latest)) latest = event;
  }
  return latest;
}

/**
 * Calcule la mise à jour d'une course pour un chauffeur supprimé.
 * Retourne null si la course ne concerne pas ce chauffeur.
 * Lève "in-ride" si un client est à bord avec ce chauffeur.
 */
function anonymizeOrder(data, uid, pseudonym, now = new Date()) {
  const history = Array.isArray(data?.commandStatus) ? data.commandStatus : [];
  const involved = data?.driverId === uid ||
    history.some((event) => event && event.id === uid);
  if (!involved) return null;

  const latest = latestEvent(history);
  const current = latest ? statusName(latest.status) : (data.driverId ? "ASSIGNED" : "PENDING_ASSIGNMENT");
  const assignedToUser = latest ? latest.id === uid : data.driverId === uid;
  if (assignedToUser && current === "CLIENT_ON_BOARD") {
    const error = new Error("in-ride");
    error.code = "in-ride";
    throw error;
  }

  const commandStatus = history.map((event) =>
    event && event.id === uid ? { ...event, id: pseudonym } : event);
  const released = assignedToUser && RELEASABLE.has(current);
  const update = { commandStatus };
  if (released) {
    commandStatus.push({
      date: now.toISOString(),
      status: "OrderStatus.PENDING_ASSIGNMENT",
      id: "",
      location: latest?.location ?? { latitude: 0, longitude: 0 },
    });
    update.driverId = FieldValue.delete();
    update.commandStatusUpdatedAt = Timestamp.fromDate(now);
  } else if (data.driverId === uid) {
    update.driverId = pseudonym;
  }
  return { update, released };
}

async function deleteQuery(db, query) {
  for (;;) {
    const snapshot = await query.limit(400).get();
    if (snapshot.empty) return;
    const batch = db.batch();
    snapshot.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
  }
}

function handlers(db, auth = getAuth()) {
  const deleteDriverAccount = async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Connectez-vous.");
    if (request.auth.token?.firebase?.sign_in_provider === "anonymous") {
      throw new HttpsError("permission-denied", "Action réservée au chauffeur.");
    }
    const pseudonym = `supprime-${crypto.randomBytes(8).toString("hex")}`;

    // 1. Courses : vérification puis anonymisation (rien n'est supprimé avant).
    const orders = await db.collection("Orders").get();
    const updates = [];
    for (const doc of orders.docs) {
      try {
        const result = anonymizeOrder(doc.data(), uid, pseudonym);
        if (result) updates.push([doc.ref, result]);
      } catch (error) {
        if (error.code === "in-ride") {
          throw new HttpsError("failed-precondition",
            "Terminez votre course en cours avant de supprimer votre compte.");
        }
        throw error;
      }
    }
    for (let i = 0; i < updates.length; i += 400) {
      const batch = db.batch();
      for (const [ref, { update }] of updates.slice(i, i + 400)) batch.update(ref, update);
      await batch.commit();
    }

    // 2. Paiements administrateur archivés sous le pseudonyme.
    const driverRef = db.collection("Drivers").doc(uid);
    const payments = await driverRef.collection("Payments").get();
    const archive = db.collection("DeletedDrivers").doc(pseudonym);
    await archive.set({
      deletedAt: Timestamp.now(),
      releasedOrders: updates.filter(([, result]) => result.released).length,
      anonymizedOrders: updates.length,
    });
    for (let i = 0; i < payments.docs.length; i += 400) {
      const batch = db.batch();
      for (const payment of payments.docs.slice(i, i + 400)) {
        batch.set(archive.collection("Payments").doc(payment.id), payment.data());
      }
      await batch.commit();
    }

    // 3. Données personnelles.
    await db.recursiveDelete(driverRef);
    await db.recursiveDelete(db.collection("Clients").doc(uid));
    await deleteQuery(db, db.collection("DriverPushTokens").where("driverId", "==", uid));
    await deleteQuery(db, db.collection("DriverReminders").where("driverId", "==", uid));
    await deleteQuery(db, db.collection("DriverTravelAlerts").where("driverId", "==", uid));
    await deleteQuery(db, db.collection("TabletLinks").where("driverId", "==", uid));
    await deleteQuery(db, db.collection("TabletPairingCodes").where("driverId", "==", uid));
    await db.doc(`TabletPairingOwners/${uid}`).delete();

    // 4. Compte de connexion, en dernier.
    try {
      await auth.deleteUser(uid);
    } catch (error) {
      if (error?.code !== "auth/user-not-found") throw error;
    }
    logger.info("Compte chauffeur supprimé", { pseudonym, orders: updates.length });
    return { deleted: true };
  };
  return { deleteDriverAccount };
}

function register(db) {
  const api = handlers(db);
  return { deleteDriverAccount: onCall({ region }, api.deleteDriverAccount) };
}

module.exports = { anonymizeOrder, handlers, register };
