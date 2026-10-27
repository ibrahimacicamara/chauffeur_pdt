"use strict";

const crypto = require("node:crypto");
const { HttpsError, onCall } = require("firebase-functions/v2/https");
const { Timestamp } = require("firebase-admin/firestore");

function authenticated(request) {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Connectez-vous.");
  return request.auth.uid;
}

async function access(tx, db, request) {
  const user = authenticated(request);
  const link = await tx.get(db.doc(`TabletLinks/${user}`));
  if (link.exists) {
    if (!link.data().active) throw new HttpsError("permission-denied", "Association de la tablette révoquée.");
    return { driver: link.data().driverId, tablet: true };
  }
  if (request.auth.token?.firebase?.sign_in_provider === "anonymous") {
    throw new HttpsError("permission-denied", "Associez cette tablette au chauffeur.");
  }
  const profile = await tx.get(db.doc(`Drivers/${user}`));
  if (!profile.exists) throw new HttpsError("permission-denied", "Profil chauffeur requis.");
  return { driver: user, tablet: false };
}

async function driverAccess(tx, db, request) {
  const actor = await access(tx, db, request);
  if (actor.tablet) throw new HttpsError("permission-denied", "Action réservée au chauffeur.");
  return actor.driver;
}

function handlers(db) {
  const create = async (request) => {
    const code = crypto.randomBytes(5).toString("hex").toUpperCase();
    const hash = crypto.createHash("sha256").update(code).digest("hex");
    const expiresAt = Timestamp.fromMillis(Date.now() + 5 * 60 * 1000);
    await db.runTransaction(async (tx) => {
      const driver = await driverAccess(tx, db, request);
      const ownerRef = db.doc(`TabletPairingOwners/${driver}`);
      const owner = await tx.get(ownerRef);
      if (owner.exists && Date.now() - owner.data().issuedAt.toMillis() < 10000) {
        throw new HttpsError("resource-exhausted", "Attendez 10 secondes avant de générer un autre code.");
      }
      tx.set(ownerRef, { hash, issuedAt: Timestamp.now() });
      tx.create(db.doc(`TabletPairingCodes/${hash}`), { driverId: driver, expiresAt, used: false });
    });
    return { code, expiresAt: expiresAt.toMillis() };
  };

  const redeem = async (request) => {
    const tablet = authenticated(request);
    if (request.auth.token?.firebase?.sign_in_provider !== "anonymous") {
      throw new HttpsError("permission-denied", "Utilisez l'identité dédiée à la tablette.");
    }
    const code = request.data?.code;
    const label = request.data?.name;
    if (typeof code !== "string" || !/^[A-F0-9]{10}$/.test(code) ||
        typeof label !== "string" || !label.trim() || [...label.trim()].length > 60) {
      throw new HttpsError("invalid-argument", "Code de 10 caractères et nom de tablette requis.");
    }
    const hash = crypto.createHash("sha256").update(code).digest("hex");
    const result = await db.runTransaction(async (tx) => {
      const limitRef = db.doc(`TabletPairingAttempts/${tablet}`);
      const linkRef = db.doc(`TabletLinks/${tablet}`);
      const [limit, link] = await Promise.all([tx.get(limitRef), tx.get(linkRef)]);
      const now = Date.now();
      const recent = limit.exists && now - limit.data().since.toMillis() < 10 * 60 * 1000;
      if (recent && limit.data().count >= 5) return { error: "resource-exhausted" };
      if (link.data()?.active) return { error: "already-exists" };
      tx.set(limitRef, {
        since: recent ? limit.data().since : Timestamp.now(),
        count: recent ? limit.data().count + 1 : 1,
      });
      return {};
    });
    if (result.error) {
      throw new HttpsError(result.error, result.error === "resource-exhausted"
        ? "Trop de tentatives. Réessayez dans 10 minutes."
        : result.error === "already-exists" ? "La tablette est déjà associée." : "Code invalide, expiré ou déjà utilisé.");
    }
    // Commit attempt counting even when code validation fails.
    return db.runTransaction(async (tx) => {
      const codeRef = db.doc(`TabletPairingCodes/${hash}`);
      const linkRef = db.doc(`TabletLinks/${tablet}`);
      const [pairing, link] = await Promise.all([tx.get(codeRef), tx.get(linkRef)]);
      if (!pairing.exists || pairing.data().used || pairing.data().expiresAt.toMillis() <= Date.now()) {
        throw new HttpsError("failed-precondition", "Code expiré ou déjà utilisé.");
      }
      const driver = pairing.data().driverId;
      const [owner, profile] = await Promise.all([
        tx.get(db.doc(`TabletPairingOwners/${driver}`)), tx.get(db.doc(`Drivers/${driver}`)),
      ]);
      if (!profile.exists || owner.data()?.hash !== hash || link.data()?.active) {
        throw new HttpsError("failed-precondition", "Code remplacé ou tablette déjà associée.");
      }
      tx.update(codeRef, { used: true });
      tx.set(linkRef, {
        driverId: driver, name: label.trim(), active: true,
        pairedAt: Timestamp.now(), revokedAt: null,
      });
      return { driverId: driver };
    });
  };

  const revoke = async (request) => db.runTransaction(async (tx) => {
    const driver = await driverAccess(tx, db, request);
    const tablet = request.data?.tabletId;
    if (typeof tablet !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(tablet)) {
      throw new HttpsError("invalid-argument", "Identifiant de tablette invalide.");
    }
    const ref = db.doc(`TabletLinks/${tablet}`);
    const link = await tx.get(ref);
    if (!link.exists || link.data().driverId !== driver) {
      throw new HttpsError("permission-denied", "Cette tablette n'est pas associée à votre compte.");
    }
    tx.update(ref, { active: false, revokedAt: Timestamp.now() });
    return { revoked: true };
  });
  return { create, redeem, revoke };
}

function register(db) {
  const api = handlers(db);
  return {
    createTabletPairingCode: onCall({ region: "europe-west1" }, api.create),
    redeemTabletPairingCode: onCall({ region: "europe-west1" }, api.redeem),
    revokeTablet: onCall({ region: "europe-west1" }, api.revoke),
  };
}

module.exports = { access, driverAccess, handlers, register };
