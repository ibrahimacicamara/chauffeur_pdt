"use strict";

const crypto = require("node:crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { Timestamp } = require("firebase-admin/firestore");
const { access } = require("./tablet_pairing");
const region = "europe-west1";
const languages = new Set(["fr", "en", "es", "zh", "pt", "ru", "ja", "hi"]);

function assignment(order) {
  if (!order) return { driver: null, onboard: false };
  const events = order.commandStatus ?? [];
  if (!Array.isArray(events)) throw new HttpsError("failed-precondition", "Historique de course invalide.");
  const status = (event) => String(event?.status ?? "").replace(/^OrderStatus\./, "").toUpperCase();
  const reset = events.findLastIndex((event) => status(event) === "PENDING_ASSIGNMENT");
  const active = events.slice(reset + 1);
  const driver = (active.find((event) => status(event) === "ASSIGNED" && event.id?.trim()) ??
    active.find((event) => event.id?.trim()))?.id?.trim() ?? (reset < 0 ? order.driverId : null);
  return {
    driver,
    onboard: status(events.at(-1)) === "CLIENT_ON_BOARD" &&
      !["Terminée", "Annulée"].includes(order.status),
  };
}

function name(value) {
  if (typeof value !== "string" || !value.trim() || [...value.trim()].length > 100) {
    throw new HttpsError("invalid-argument", "Nom obligatoire (100 caractères maximum).");
  }
  return value.trim();
}
function identifier(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) {
    throw new HttpsError("invalid-argument", "Identifiant invalide.");
  }
  return value;
}
function roster(order) {
  const clients = order.clients ?? [];
  if (!Array.isArray(clients)) throw new HttpsError("failed-precondition", "Passagers invalides.");
  return clients.filter((client) => typeof client?.name === "string" && client.name.trim())
    .map((client, index) => ({
      id: crypto.createHash("sha256").update(`${index}:${client.name}:${client.phone ?? ""}`).digest("hex").slice(0, 24),
      name: name(client.name),
    }));
}

function handlers(db) {
  const root = (driver) => db.collection("Clients").doc(driver);

  async function sync(driver, orderId) {
    await db.runTransaction(async (tx) => {
      const ref = root(driver);
      const orderRef = db.collection("Orders").doc(orderId);
      const [pointer, snapshot, profile] = await Promise.all([
        tx.get(ref), tx.get(orderRef), tx.get(db.collection("Drivers").doc(driver)),
      ]);
      const order = snapshot.data();
      const state = assignment(order);
      const current = pointer.data()?.currentClient;
      if (!state.onboard || state.driver !== driver) {
        if (current?.orderId === orderId) {
          tx.set(ref, { currentClient: null, driverName: profile.data()?.name ?? "", updatedAt: Timestamp.now() }, { merge: true });
        }
        return;
      }
      if (current?.orderId && current.orderId !== orderId) {
        const other = await tx.get(db.collection("Orders").doc(current.orderId));
        const previous = assignment(other.data());
        if (previous.onboard && previous.driver === driver) {
          throw new HttpsError("failed-precondition", "Deux courses sont au statut Client à bord. Corrigez leurs statuts.");
        }
      }
      const clients = roster(order);
      if (!clients.length) throw new HttpsError("failed-precondition", "Renseignez un passager sur la course.");
      const selected = clients.find((client) => client.id === current?.clientId) ?? clients[0];
      const sameSession = current?.orderId === orderId && selected.id === current.clientId;
      const sessionId = sameSession ? current.sessionId : crypto.randomUUID();
      const language = sameSession ? current.language : "fr";
      const driverName = name(profile.data()?.name);
      const info = {
        sessionId, clientId: selected.id, name: selected.name, language,
        orderId, clients, driverName,
        departureAddress: typeof order.departureAddress === "string" ? order.departureAddress : "",
        steps: Array.isArray(order.steps) ? order.steps.filter((step) => typeof step === "string") : [],
      };
      tx.set(ref, { currentClient: info, driverName, updatedAt: Timestamp.now() }, { merge: true });
      tx.set(ref.collection("sessions").doc(sessionId), {
        clientName: selected.name, clientId: selected.id, language, orderId,
        driverName, updatedAt: Timestamp.now(),
      }, { merge: true });
    });
  }

  async function validateCurrent(tx, request, sessionId) {
    const actor = await access(tx, db, request);
    const driver = actor.driver;
    const ref = root(driver);
    const snapshot = await tx.get(ref);
    const current = snapshot.data()?.currentClient;
    if (!current || current.sessionId !== identifier(sessionId)) {
      throw new HttpsError("failed-precondition", "La session client a changé. Actualisez la conversation.");
    }
    if (current.orderId) {
      const order = await tx.get(db.collection("Orders").doc(current.orderId));
      const state = assignment(order.data());
      if (!state.onboard || state.driver !== driver) {
        throw new HttpsError("failed-precondition", "Le client n’est plus à bord.");
      }
    }
    return { ref, current, actor };
  }

  const refresh = async (request) => {
    const { driver } = await db.runTransaction((tx) => access(tx, db, request));
    // Legacy assignments also live in commandStatus, not necessarily in driverId.
    const orders = await db.collection("Orders").get();
    const active = orders.docs.filter((doc) => {
      const state = assignment(doc.data());
      return state.driver === driver && state.onboard;
    });
    if (active.length > 1) throw new HttpsError("failed-precondition", "Plusieurs courses ont un client à bord.");
    if (active.length) await sync(driver, active[0].id);
    else {
      const current = (await root(driver).get()).data()?.currentClient;
      if (current?.orderId) await sync(driver, current.orderId);
    }
    return { refreshed: true };
  };

  const start = async (request) => {
    await refresh(request);
    return db.runTransaction(async (tx) => {
      const { driver } = await access(tx, db, request);
      const ref = root(driver);
      const [snapshot, profile] = await Promise.all([tx.get(ref), tx.get(db.doc(`Drivers/${driver}`))]);
      if (snapshot.data()?.currentClient?.orderId) {
        throw new HttpsError("failed-precondition", "Une course est déjà à bord.");
      }
      const language = request.data?.language;
      if (!languages.has(language)) throw new HttpsError("invalid-argument", "Langue invalide.");
      const sessionId = crypto.randomUUID();
      const current = {
        sessionId, name: name(request.data?.name), language,
        driverName: name(profile.data()?.name), orderId: null, clients: [], clientId: null,
      };
      tx.set(ref, { currentClient: current, driverName: current.driverName, updatedAt: Timestamp.now() }, { merge: true });
      tx.set(ref.collection("sessions").doc(sessionId), {
        clientName: current.name, driverName: current.driverName,
        language, orderId: null, updatedAt: Timestamp.now(),
      });
      return { sessionId };
    });
  };

  const preference = async (request) => {
    return db.runTransaction(async (tx) => {
      const { ref, current, actor } = await validateCurrent(tx, request, request.data?.sessionId);
      if (actor.tablet && request.data?.clientId != null) {
        throw new HttpsError("permission-denied", "Seul le chauffeur peut changer de passager.");
      }
      const language = request.data.language;
      if (!languages.has(language)) throw new HttpsError("invalid-argument", "Langue invalide.");
      let info = { ...current, language };
      if (request.data.clientId != null && current.orderId) {
        const selected = current.clients.find((client) => client.id === request.data.clientId);
        if (!selected) throw new HttpsError("invalid-argument", "Passager invalide.");
        if (selected.id !== current.clientId) {
          info = { ...info, clientId: selected.id, name: selected.name, sessionId: crypto.randomUUID() };
        }
      }
      tx.set(ref, { currentClient: info, updatedAt: Timestamp.now() }, { merge: true });
      tx.set(ref.collection("sessions").doc(info.sessionId), {
        clientName: info.name, clientId: info.clientId, driverName: info.driverName,
        language, orderId: info.orderId, updatedAt: Timestamp.now(),
      }, { merge: true });
      return { updated: true };
    });
  };

  const send = async (request) => {
    return db.runTransaction(async (tx) => {
      const data = request.data ?? {};
      const { ref, current, actor } = await validateCurrent(tx, request, data.sessionId);
      if (actor.tablet && data.role !== "client") {
        throw new HttpsError("permission-denied", "La tablette peut envoyer uniquement les messages du client.");
      }
      if (!["client", "driver"].includes(data.role) ||
          typeof data.text !== "string" || !data.text.trim() || [...data.text].length > 500) {
        throw new HttpsError("invalid-argument", "Message invalide (500 caractères maximum).");
      }
      const messageRef = ref.collection("sessions").doc(current.sessionId).collection("messages").doc(identifier(data.messageId));
      const existing = await tx.get(messageRef);
      const source = data.role === "client" ? current.language : "fr";
      const target = data.role === "client" ? "fr" : current.language;
      if (data.translation != null &&
          (data.role !== "client" || typeof data.translation !== "string" ||
           !data.translation.trim() || data.translation.length > 5000)) {
        throw new HttpsError("invalid-argument", "Traduction client invalide.");
      }
      if (existing.exists) {
        const saved = existing.data();
        if (saved.text !== data.text.trim() || saved.role !== data.role) {
          throw new HttpsError("already-exists", "Identifiant déjà utilisé.");
        }
        return { sent: true };
      }
      tx.create(messageRef, {
        role: data.role, text: data.text.trim(), source, target,
        senderUid: request.auth.uid, createdAt: Timestamp.now(),
        ...(data.translation != null ? { translation: data.translation.trim() } : {}),
      });
      return { sent: true };
    });
  };
  const end = async (request) => {
    return db.runTransaction(async (tx) => {
      const { ref, current } = await validateCurrent(tx, request, request.data?.sessionId);
      if (current.orderId) throw new HttpsError("failed-precondition", "Terminez la course pour fermer cette session.");
      tx.set(ref, { currentClient: null, updatedAt: Timestamp.now() }, { merge: true });
      return { ended: true };
    });
  };
  const translation = async (request) => {
    return db.runTransaction(async (tx) => {
      const data = request.data ?? {};
      const { ref, current } = await validateCurrent(tx, request, data.sessionId);
      const messageRef = ref.collection("sessions").doc(current.sessionId)
        .collection("messages").doc(identifier(data.messageId));
      const message = await tx.get(messageRef);
      if (!message.exists) throw new HttpsError("not-found", "Message introuvable.");
      if (typeof data.translation !== "string" || !data.translation.trim() || data.translation.length > 5000) {
        throw new HttpsError("invalid-argument", "Traduction invalide.");
      }
      tx.update(messageRef, { translation: data.translation.trim() });
      return { saved: true };
    });
  };
  return { sync, refresh, start, preference, send, end, translation };
}

function register(db) {
  const api = handlers(db);
  return {
    refreshCurrentClient: onCall({ region }, api.refresh),
    startClientSession: onCall({ region }, api.start),
    setCurrentClientLanguage: onCall({ region }, api.preference),
    sendClientSessionMessage: onCall({ region }, api.send),
    endClientSession: onCall({ region }, api.end),
    saveClientMessageTranslation: onCall({ region }, api.translation),
    syncCurrentClient: onDocumentWritten({ document: "Orders/{orderId}", region, retry: true }, async (event) => {
      const drivers = new Set([
        assignment(event.data?.before.data()).driver,
        assignment(event.data?.after.data()).driver,
      ].filter(Boolean));
      for (const driver of drivers) await api.sync(driver, event.params.orderId);
    }),
  };
}
module.exports = { assignment, handlers, register };
