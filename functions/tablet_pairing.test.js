"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { handlers } = require("./tablet_pairing");
const { handlers: sessionHandlers } = require("./client_sessions");

if (!/^(localhost|127\.0\.0\.1):\d+$/.test(process.env.FIRESTORE_EMULATOR_HOST ?? "")) {
  throw new Error("Local Firestore emulator required");
}
initializeApp({ projectId: "demo-chauffeur" });
const db = getFirestore();
const api = handlers(db);
const sessions = sessionHandlers(db);
const driver = `pair-driver-${Date.now()}`;
const tablet = `tablet-${Date.now()}`;
const tablet2 = `${tablet}-second`;
const auth = (uid, anonymous = false) => ({
  uid, token: { firebase: { sign_in_provider: anonymous ? "anonymous" : "password" } },
});
const request = (data = {}) => ({ auth: auth(driver), data });
const tabletRequest = (data = {}, id = tablet) => ({ auth: auth(id, true), data });
const hash = (code) => crypto.createHash("sha256").update(code).digest("hex");

async function newCode() {
  await db.doc(`TabletPairingOwners/${driver}`).delete();
  return (await api.create(request())).code;
}

function token(user, anonymous = false) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${encode({ alg: "none", typ: "JWT" })}.${encode({
    sub: user, user_id: user, aud: "demo-chauffeur",
    iss: "https://securetoken.google.com/demo-chauffeur",
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 3600,
    firebase: { sign_in_provider: anonymous ? "anonymous" : "password" },
  })}.`;
}
async function read(path, user = tablet, anonymous = true, method = "GET") {
  return fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/demo-chauffeur/databases/(default)/documents/${path}`, {
    method, headers: { Authorization: `Bearer ${token(user, anonymous)}`, "Content-Type": "application/json" },
    ...(method === "PATCH" ? { body: JSON.stringify({ fields: {} }) } : {}),
  });
}

test("persistent multi-tablet pairing, active-session permissions, revocation and reconnect", async () => {
  assert.equal((await read(`TabletLinks/${tablet}`)).status, 404);
  assert.equal((await read(`TabletLinks/${tablet2}`)).status, 403);
  assert.equal((await read(`Clients/${driver}`)).status, 403);
  await db.doc(`Drivers/${driver}`).set({ name: "Driver" });
  const code = await newCode();
  assert.match(code, /^[A-F0-9]{10}$/);
  await assert.rejects(api.create(request()), { code: "resource-exhausted" });
  await api.redeem(tabletRequest({ code, name: "iPad" }));
  assert.equal((await db.doc(`TabletLinks/${tablet}`).get()).data().driverId, driver);
  await assert.rejects(api.redeem(tabletRequest({ code, name: "duplicate" }, tablet2)), { code: "failed-precondition" });
  const second = await newCode();
  await api.redeem(tabletRequest({ code: second, name: "Android" }, tablet2));
  // No new pairing is required when a client session changes.
  await sessions.start(tabletRequest({ name: "Alice", language: "en" }));
  const current = (await db.doc(`Clients/${driver}`).get()).data().currentClient;
  await sessions.send(tabletRequest({
    sessionId: current.sessionId, messageId: "client", text: "Hello", role: "client", translation: "Bonjour",
  }));
  assert.equal((await db.doc(`Clients/${driver}/sessions/${current.sessionId}/messages/client`).get()).data().translation, "Bonjour");
  await assert.rejects(sessions.send(tabletRequest({
    sessionId: current.sessionId, messageId: "forged", text: "Driver", role: "driver",
  })), { code: "permission-denied" });
  await sessions.send(request({ sessionId: current.sessionId, messageId: "reply", text: "Bonjour", role: "driver" }));
  await sessions.translation(tabletRequest({
    sessionId: current.sessionId, messageId: "reply", translation: "Hello",
  }));
  assert.equal((await read(`Clients/${driver}`)).status, 200);
  const messages = `Clients/${driver}/sessions/${current.sessionId}/messages/reply`;
  assert.equal((await read(messages)).status, 200);
  assert.equal((await read(`Clients/other`)).status, 403);
  assert.equal((await read(`Drivers/${driver}`)).status, 403);
  assert.equal((await read(`Clients/${driver}`, tablet, true, "PATCH")).status, 403);
  assert.equal((await read(`TabletPairingCodes/${hash(second)}`)).status, 403);
  assert.equal((await read(`TabletLinks/${tablet}`)).status, 200);
  assert.equal((await read(`TabletLinks/${tablet2}`)).status, 403);
  assert.equal((await read(`TabletLinks/${tablet2}`, driver, false)).status, 200);
  assert.equal((await read(`Clients/${driver}`, driver, false)).status, 200);
  assert.equal((await read(messages, "unrelated-driver", false)).status, 403);
  await sessions.end(tabletRequest({ sessionId: current.sessionId }));
  assert.equal((await read(messages)).status, 403);
  await sessions.start(tabletRequest({ name: "Bob", language: "ja" }, tablet2));
  const bob = (await db.doc(`Clients/${driver}`).get()).data().currentClient;
  assert.notEqual(bob.sessionId, current.sessionId);
  await sessions.refresh(tabletRequest());
  await assert.rejects(api.revoke(tabletRequest({ tabletId: tablet2 })), { code: "permission-denied" });
  await assert.rejects(api.revoke({ auth: auth("other"), data: { tabletId: tablet } }), { code: "permission-denied" });
  await api.revoke(request({ tabletId: tablet }));
  assert.equal((await read(`TabletLinks/${tablet}`)).status, 200);
  assert.equal((await read(`Clients/${driver}`)).status, 403);
  await assert.rejects(sessions.refresh(tabletRequest()), { code: "permission-denied" });
  await assert.rejects(sessions.send(tabletRequest({
    sessionId: bob.sessionId, messageId: "revoked", text: "Hello", role: "client",
  })), { code: "permission-denied" });
  assert.equal((await read(`Clients/${driver}`, tablet2)).status, 200);
  const rePair = await newCode();
  await api.redeem(tabletRequest({ code: rePair, name: "iPad reassociated" }));
  assert.equal((await read(`Clients/${driver}`)).status, 200);
});

test("codes expire, are replaced, consumed atomically and attempts are limited", async () => {
  const testId = (name) => `${name}-${driver}`;
  const expired = await newCode();
  await db.doc(`TabletPairingCodes/${hash(expired)}`).update({ expiresAt: Timestamp.fromMillis(Date.now() - 1000) });
  await assert.rejects(api.redeem(tabletRequest({ code: expired, name: "Expired" }, testId("expired"))), { code: "failed-precondition" });
  const old = await newCode();
  const valid = await newCode();
  await assert.rejects(api.redeem(tabletRequest({ code: old, name: "Old" }, testId("old"))), { code: "failed-precondition" });
  const raced = await Promise.allSettled([testId("race-one"), testId("race-two")].map(
    (id) => api.redeem(tabletRequest({ code: valid, name: id }, id)),
  ));
  assert.equal(raced.filter((item) => item.status === "fulfilled").length, 1);
  for (let i = 0; i < 5; i++) {
    await assert.rejects(api.redeem(tabletRequest({ code: "0000000000", name: "Guess" }, testId("guessing"))), { code: "failed-precondition" });
  }
  await assert.rejects(api.redeem(tabletRequest({ code: "0000000000", name: "Guess" }, testId("guessing"))), { code: "resource-exhausted" });
  await assert.rejects(api.redeem(request({ code: valid, name: "Not anonymous" })), { code: "permission-denied" });
});
