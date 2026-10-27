"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");

const local = process.env.FIRESTORE_EMULATOR_HOST;
if (!local) {
  test("Availability Firestore integration (requires emulator)", { skip: true }, () => {});
} else {
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(local)) throw new Error("Local emulator required");
  process.env.GOOGLE_MAPS_API_KEY = "test-only-key";
  const { initializeApp } = require("firebase-admin/app");
  initializeApp({ projectId: "demo-chauffeur-availability" });
  const { getFirestore, Timestamp } = require("firebase-admin/firestore");
  const { getMessaging } = require("firebase-admin/messaging");
  const { register, ADMIN_UID } = require("./driver_availability");
  const { course } = require("./reminder_logic");
  const db = getFirestore();
  let duration, failCalculation, changeOrder, calculationCalls, sends, generation;
  const backend = register(db, { calculateTravel: async () => {
    calculationCalls++;
    if (failCalculation) throw new Error("simulated failure");
    if (changeOrder) await db.doc("Orders/course").update(changeOrder);
    return {
      durationSeconds: duration, routeDistanceMeters: 42000,
      destination: { latitude: 48, longitude: 2 }, provider: "google_routes",
    };
  } });
  const messaging = getMessaging();
  const originalSend = messaging.sendEachForMulticast;
  beforeEach(async () => {
    for (const collection of ["Orders", "Drivers", "DriverReminders", "DriverTravelAlerts", "DriverPushTokens"]) {
      await db.recursiveDelete(db.collection(collection));
    }
    duration = 3601;
    calculationCalls = 0;
    failCalculation = false;
    changeOrder = null;
    sends = [];
    messaging.sendEachForMulticast = async (message) => {
      sends.push(message);
      return { responses: message.tokens.map(() => ({ success: true })), successCount: message.tokens.length };
    };
    await db.doc("Drivers/driver").set({ available: true });
    const order = {
      driverId: "driver", departureDate: Timestamp.fromMillis(Date.now() + 1800000),
      departureAddress: "Synthetic test address",
    };
    generation = course(order).generation;
    await db.doc("Orders/course").set(order);
    await db.doc("DriverReminders/course").set({
      driverId: "driver", generation, state: "sent",
    });
  });
  afterEach(() => { messaging.sendEachForMulticast = originalSend; });

  function request(uid = "driver") {
    return {
      auth: { uid, token: { firebase: { sign_in_provider: "password" } } },
      data: {
        orderId: "course", generation,
        position: { latitude: 48, longitude: 2, capturedAt: Date.now() },
      },
    };
  }
  test("confirms once and creates one alert only for a duration strictly over 3600 seconds", async () => {
    for (const value of [3599, 3600, 3600.01]) {
      duration = value;
      await db.doc("DriverReminders/course").update({ state: "sent" });
      const result = await backend.functions.confirmDriverAvailability.run(request());
      assert.equal(result.durationSeconds, value);
      assert.equal(Boolean(result.adminAlertId), value > 3600);
    }
    const first = await backend.functions.confirmDriverAvailability.run(request());
    const second = await backend.functions.confirmDriverAvailability.run(request());
    assert.deepEqual(first, second);
    assert.equal(calculationCalls, 3);
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 1);
    const saved = (await db.doc("DriverReminders/course").get()).data();
    assert.equal(saved.state, "confirmed");
    assert.deepEqual(saved.position, { latitude: 48, longitude: 2 });
    assert.ok(saved.confirmedAt);
  });
  test("rejects foreign/anonymous users, stale GPS, early/expired reminders and changed courses", async () => {
    await assert.rejects(backend.functions.confirmDriverAvailability.run(request("other")));
    const anonymous = request();
    anonymous.auth.token.firebase.sign_in_provider = "anonymous";
    await assert.rejects(backend.functions.confirmDriverAvailability.run(anonymous));
    const stale = request();
    stale.data.position.capturedAt -= 120001;
    await assert.rejects(backend.functions.confirmDriverAvailability.run(stale));
    for (const delta of [7200000, -1000]) {
      await db.doc("Orders/course").update({ departureDate: Timestamp.fromMillis(Date.now() + delta) });
      await assert.rejects(backend.functions.confirmDriverAvailability.run(request()));
    }
    assert.equal(calculationCalls, 0);
  });
  test("routing failure and reassignment during calculation do not confirm", async () => {
    failCalculation = true;
    await assert.rejects(backend.functions.confirmDriverAvailability.run(request()));
    assert.equal((await db.doc("DriverReminders/course").get()).data().state, "sent");
    failCalculation = false;
    changeOrder = { driverId: "other" };
    await assert.rejects(backend.functions.confirmDriverAvailability.run(request()));
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 0);
  });
  test("admin push targets only admin devices and retries do not duplicate a sent alert", async () => {
    await db.doc("DriverPushTokens/admin").set({ driverId: ADMIN_UID, token: "fake-admin-token" });
    await db.doc("DriverPushTokens/driver").set({ driverId: "driver", token: "fake-driver-token" });
    const result = await backend.functions.confirmDriverAvailability.run(request());
    await backend.sendPendingAlerts();
    await backend.sendPendingAlerts();
    assert.equal(sends.length, 1);
    assert.deepEqual(sends[0].tokens, ["fake-admin-token"]);
    assert.equal(sends[0].data.type, "driver_travel_alert");
    assert.equal(sends[0].data.alertId, result.adminAlertId);
    assert.equal((await db.doc(`DriverTravelAlerts/${result.adminAlertId}`).get()).data().state, "sent");
  });
  test("concurrent confirmations create only one alert", async () => {
    const results = await Promise.all([
      backend.functions.confirmDriverAvailability.run(request()),
      backend.functions.confirmDriverAvailability.run(request()),
    ]);
    assert.equal(results[0].adminAlertId, results[1].adminAlertId);
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 1);
  });
  test("a changed departure address during calculation requires a new confirmation", async () => {
    changeOrder = { departureAddress: "New synthetic address" };
    await assert.rejects(backend.functions.confirmDriverAvailability.run(request()));
    assert.equal((await db.doc("DriverReminders/course").get()).data().state, "sent");
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 0);
  });
  test("reassigned course cancels the queued admin notification", async () => {
    const result = await backend.functions.confirmDriverAvailability.run(request());
    await db.doc("Orders/course").update({ driverId: "other" });
    await backend.sendPendingAlerts();
    assert.equal(sends.length, 0);
    assert.equal((await db.doc(`DriverTravelAlerts/${result.adminAlertId}`).get()).data().state, "cancelled");
  });
  test("partial FCM failures retry only devices not yet reached", async () => {
    await db.doc("DriverPushTokens/admin1").set({ driverId: ADMIN_UID, token: "fake-admin-1" });
    await db.doc("DriverPushTokens/admin2").set({ driverId: ADMIN_UID, token: "fake-admin-2" });
    let first = true;
    messaging.sendEachForMulticast = async (message) => {
      sends.push(message);
      const responses = message.tokens.map((token) =>
        first && token === "fake-admin-2"
          ? { success: false, error: { code: "messaging/server-unavailable" } }
          : { success: true });
      first = false;
      return { responses, successCount: responses.filter((item) => item.success).length };
    };
    const result = await backend.functions.confirmDriverAvailability.run(request());
    const ref = db.doc(`DriverTravelAlerts/${result.adminAlertId}`);
    await backend.sendPendingAlerts();
    assert.equal((await ref.get()).data().state, "pending");
    await ref.update({ nextAttemptAt: Timestamp.now() });
    await backend.sendPendingAlerts();
    assert.deepEqual(sends[1].tokens, ["fake-admin-2"]);
    assert.equal((await ref.get()).data().state, "sent");
  });
  test("missing admin device persists a visible error and can retry later", async () => {
    const result = await backend.functions.confirmDriverAvailability.run(request());
    await backend.sendPendingAlerts();
    const ref = db.doc(`DriverTravelAlerts/${result.adminAlertId}`);
    assert.equal((await ref.get()).data().state, "pending");
    assert.match((await ref.get()).data().lastError, /Aucun appareil/);
    await db.doc("DriverPushTokens/admin").set({ driverId: ADMIN_UID, token: "fake-admin-token" });
    await ref.update({ nextAttemptAt: Timestamp.now() });
    await backend.sendPendingAlerts();
    assert.equal((await ref.get()).data().state, "sent");
  });
}
