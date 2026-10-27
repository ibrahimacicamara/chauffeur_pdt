"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { assignment } = require("./client_sessions");

test("client course is visible only for current onboard assignment", () => {
  const data = { driverId: "old", commandStatus: [
    { status: "OrderStatus.ASSIGNED", id: "old" },
    { status: "OrderStatus.PENDING_ASSIGNMENT", id: "old" },
    { status: "OrderStatus.ASSIGNED", id: "driver" },
    { status: "OrderStatus.CLIENT_ON_BOARD", id: "driver" },
  ] };
  assert.deepEqual(assignment(data), { driver: "driver", onboard: true });
  assert.equal(assignment({ ...data, status: "Terminée" }).onboard, false);
  data.commandStatus.push({ status: "OrderStatus.COMPLETED", id: "driver" });
  assert.equal(assignment(data).onboard, false);
  assert.deepEqual(assignment(null), { driver: null, onboard: false });
});

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  test("Client sessions integration requires emulator", { skip: true }, () => {});
} else {
  if (!/^(localhost|127\.0\.0\.1):\d+$/.test(process.env.FIRESTORE_EMULATOR_HOST)) throw new Error("Local emulator required");
  const { initializeApp } = require("firebase-admin/app");
  const { getFirestore } = require("firebase-admin/firestore");
  const { handlers } = require("./client_sessions");
  initializeApp({ projectId: "demo-chauffeur" });
  const db = getFirestore();
  const api = handlers(db);
  const driver = `test-driver-${Date.now()}`;
  const orderId = `test-order-${Date.now()}`;
  const request = (data = {}) => ({ auth: { uid: driver }, data });
  test("onboard sync, free sessions, isolated messages, retries and clearing course", async () => {
    const root = db.doc(`Clients/${driver}`);
    const order = db.doc(`Orders/${orderId}`);
    try {
      await db.doc(`Drivers/${driver}`).set({ name: "Driver" });
      await api.start(request({ name: "Free client", language: "en" }));
      const ended = (await root.get()).data().currentClient;
      await api.end(request({ sessionId: ended.sessionId }));
      assert.equal((await root.get()).data().currentClient, null);
      await api.start(request({ name: "Free client", language: "en" }));
      const free = (await root.get()).data().currentClient;
      assert.equal(free.orderId, null);
      await order.set({
        driverId: driver, clients: [{ name: "Alice" }, { name: "Bob" }],
        departureAddress: "Paris", steps: ["Orly"],
        commandStatus: [{ status: "OrderStatus.ASSIGNED", id: driver }],
      });
      await api.sync(driver, orderId);
      assert.equal((await root.get()).data().currentClient.sessionId, free.sessionId);
      await order.update({ commandStatus: [{ status: "OrderStatus.CLIENT_ON_BOARD", id: driver }] });
      await api.sync(driver, orderId);
      const current = (await root.get()).data().currentClient;
      assert.equal(current.name, "Alice");
      assert.equal(current.driverName, "Driver");
      assert.equal(current.orderId, orderId);
      assert.notEqual(current.sessionId, free.sessionId);
      await api.sync(driver, orderId);
      assert.equal((await root.get()).data().currentClient.sessionId, current.sessionId);
      await assert.rejects(api.send(request({
        sessionId: free.sessionId, messageId: "message", role: "client", text: "old",
      })), { code: "failed-precondition" });
      await api.preference(request({ sessionId: current.sessionId, language: "en" }));
      await api.refresh(request());
      assert.equal((await root.get()).data().currentClient.language, "en");
      const payload = { sessionId: current.sessionId, messageId: "message", role: "client", text: "Hello" };
      await api.send(request(payload));
      await api.send(request(payload));
      const messages = root.collection("sessions").doc(current.sessionId).collection("messages");
      assert.equal((await messages.get()).size, 1);
      assert.equal((await messages.doc("message").get()).data().source, "en");
      assert.equal((await messages.doc("message").get()).data().target, "fr");
      await api.send(request({ ...payload, messageId: "reply", role: "driver", text: "Bonjour" }));
      assert.equal((await messages.doc("reply").get()).data().target, "en");
      await api.translation(request({ ...payload, translation: "Bonjour" }));
      assert.equal((await messages.doc("message").get()).data().translation, "Bonjour");
      await api.preference(request({
        sessionId: current.sessionId, language: "ja", clientId: current.clients[1].id,
      }));
      const bob = (await root.get()).data().currentClient;
      assert.equal(bob.name, "Bob");
      assert.notEqual(bob.sessionId, current.sessionId);
      await order.update({ commandStatus: [{ status: "OrderStatus.COMPLETED", id: driver }] });
      await assert.rejects(api.send(request({
        sessionId: bob.sessionId, messageId: "message", role: "driver", text: "Bye",
      })), { code: "failed-precondition" });
      await api.sync(driver, orderId);
      assert.equal((await root.get()).data().currentClient, null);
      assert.equal((await messages.get()).size, 2);
      await assert.rejects(api.start({ data: { name: "Anonymous", language: "en" } }), { code: "unauthenticated" });
    } finally {
      await db.recursiveDelete(root);
      await order.delete();
      await db.doc(`Drivers/${driver}`).delete();
    }
  });

  test("rules allow only the same driver to read Clients and reject all direct writes", async () => {
    const token = (user) => {
      const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
      return `${encode({ alg: "none", typ: "JWT" })}.${encode({
        sub: user, user_id: user, aud: "demo-chauffeur",
        iss: "https://securetoken.google.com/demo-chauffeur",
        iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 3600,
        firebase: { sign_in_provider: "custom" },
      })}.`;
    };
    const root = db.doc(`Clients/${driver}`);
    await root.set({ currentClient: null });
    const url = `http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/demo-chauffeur/databases/(default)/documents/Clients/${driver}`;
    try {
      assert.equal((await fetch(url)).status, 403);
      assert.equal((await fetch(url, { headers: { Authorization: `Bearer ${token("other")}` } })).status, 403);
      assert.equal((await fetch(url, { headers: { Authorization: `Bearer ${token(driver)}` } })).status, 200);
      assert.equal((await fetch(url, {
        method: "PATCH", headers: { Authorization: `Bearer ${token(driver)}`, "Content-Type": "application/json" },
        body: JSON.stringify({ fields: {} }),
      })).status, 403);
    } finally { await root.delete(); }
  });
}
