"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");

const local = process.env.FIRESTORE_EMULATOR_HOST;
if (!local) {
  test("Reminder followups integration (requires emulator)", { skip: true }, () => {});
} else {
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(local)) throw new Error("Local emulator required");
  const { initializeApp } = require("firebase-admin/app");
  initializeApp({ projectId: "demo-chauffeur-followups" });
  const { getFirestore, Timestamp } = require("firebase-admin/firestore");
  const { getMessaging } = require("firebase-admin/messaging");
  const { course } = require("./reminder_logic");
  const { ADMIN_UID, register: availabilityRegister } = require("./driver_availability");
  const db = getFirestore();
  const followups = require("./reminder_followups").register(db, ADMIN_UID);
  const availability = availabilityRegister(db);
  const messaging = getMessaging();
  const originalSend = messaging.sendEachForMulticast;
  let messages, generation, failures;
  const reminder = db.doc("DriverReminders/course");
  beforeEach(async () => {
    for (const name of ["Orders", "Drivers", "DriverReminders", "DriverTravelAlerts", "DriverPushTokens"]) {
      await db.recursiveDelete(db.collection(name));
    }
    messages = [];
    failures = new Set();
    messaging.sendEachForMulticast = async (message) => {
      messages.push(message);
      const responses = message.tokens.map((token) => failures.has(token)
        ? { success: false, error: { code: "messaging/server-unavailable" } }
        : { success: true });
      return { responses, successCount: responses.filter((item) => item.success).length };
    };
    const order = {
      driverId: "driver", departureDate: Timestamp.fromMillis(Date.now() + 1800000),
      departureAddress: "Synthetic address",
    };
    generation = course(order).generation;
    await db.doc("Orders/course").set(order);
    await reminder.set({
      orderId: "course", driverId: "driver", generation,
      state: "sent", followupVersion: 1, sentAt: Timestamp.fromMillis(Date.now() - 61000),
    });
    await db.doc("DriverPushTokens/driver").set({ driverId: "driver", token: "driver-token" });
    await db.doc("DriverPushTokens/admin").set({ driverId: ADMIN_UID, token: "admin-token" });
  });
  afterEach(() => { messaging.sendEachForMulticast = originalSend; });

  test("one minute sends one data-only Android alarm with iOS sound and no admin alert", async () => {
    await followups.processFollowups();
    await followups.processFollowups();
    assert.equal(messages.length, 1);
    const push = messages[0];
    assert.deepEqual(push.tokens, ["driver-token"]);
    assert.equal(push.notification, undefined);
    assert.equal(push.data.type, "driver_reminder_alarm");
    assert.equal(push.data.generation, generation);
    assert.equal(push.android.priority, "high");
    assert.equal(push.apns.payload.aps.sound, "default");
    assert.ok(Number(push.data.expiresAt) > Number(push.data.alarmNotBefore));
    assert.ok((await reminder.get()).data().alarmSentAt);
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 0);
  });
  test("five minutes creates one no-response alert and sends only to admin", async () => {
    await reminder.update({ sentAt: Timestamp.fromMillis(Date.now() - 301000) });
    await Promise.all([followups.processFollowups(), followups.processFollowups()]);
    const alerts = await db.collection("DriverTravelAlerts").get();
    assert.equal(alerts.size, 1);
    assert.equal(alerts.docs[0].data().kind, "no_response");
    await availability.sendPendingAlerts();
    await availability.sendPendingAlerts();
    const adminPushes = messages.filter((message) => message.data.type === "driver_travel_alert");
    assert.equal(adminPushes.length, 1);
    assert.deepEqual(adminPushes[0].tokens, ["admin-token"]);
    assert.equal(adminPushes[0].data.alertKind, "no_response");
    assert.equal((await alerts.docs[0].ref.get()).data().state, "sent");
  });
  test("confirmation and cancellation suppress both followups", async () => {
    for (const state of ["confirmed", "cancelled"]) {
      await reminder.update({ state, sentAt: Timestamp.fromMillis(Date.now() - 301000) });
      await followups.processFollowups();
    }
    assert.equal(messages.length, 0);
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 0);
  });
  test("reassignment prevents notifications for the old generation", async () => {
    await db.doc("Orders/course").update({ driverId: "other" });
    await followups.processFollowups();
    assert.equal(messages.length, 0);
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 0);
  });
  test("confirmation cancels a queued no-response alert before its push", async () => {
    await reminder.update({ sentAt: Timestamp.fromMillis(Date.now() - 301000) });
    await followups.processFollowups();
    await reminder.update({ state: "confirmed" });
    await availability.sendPendingAlerts();
    const alerts = await db.collection("DriverTravelAlerts").get();
    assert.equal(alerts.docs[0].data().state, "cancelled");
    assert.equal(messages.filter((message) => message.data.type === "driver_travel_alert").length, 0);
  });
  test("missing admin devices leaves a persisted retryable no-response alert", async () => {
    await db.doc("DriverPushTokens/admin").delete();
    await reminder.update({ sentAt: Timestamp.fromMillis(Date.now() - 301000) });
    await followups.processFollowups();
    await availability.sendPendingAlerts();
    const alerts = await db.collection("DriverTravelAlerts").get();
    const alert = alerts.docs[0].data();
    assert.equal(alert.state, "pending");
    assert.match(alert.lastError, /administrateur/);
    assert.equal(messages.filter((message) => message.data.type === "driver_travel_alert").length, 0);
  });
  test("deleted course suppresses queued escalation", async () => {
    await reminder.update({ sentAt: Timestamp.fromMillis(Date.now() - 301000) });
    await followups.processFollowups();
    await db.doc("Orders/course").delete();
    await availability.sendPendingAlerts();
    const alerts = await db.collection("DriverTravelAlerts").get();
    assert.equal(alerts.docs[0].data().state, "cancelled");
    assert.equal(messages.filter((message) => message.data.type === "driver_travel_alert").length, 0);
  });
  test("alarm partial failures retry only tokens not already reached", async () => {
    await db.doc("DriverPushTokens/driver2").set({ driverId: "driver", token: "driver-token2" });
    failures.add("driver-token2");
    await followups.processFollowups();
    assert.equal((await reminder.get()).data().alarmSentAt, undefined);
    assert.match((await reminder.get()).data().alarmLastError, /appareils/);
    await reminder.update({ alarmNextAttemptAt: Timestamp.now() });
    failures.clear();
    await followups.processFollowups();
    assert.deepEqual(messages[1].tokens, ["driver-token2"]);
    assert.ok((await reminder.get()).data().alarmSentAt);
  });
  test("stop push is generation-specific and never a visible alert", async () => {
    const before = await reminder.get();
    await reminder.update({ state: "confirmed" });
    const after = await reminder.get();
    await followups.stopDriverReminderAlarm.run({
      params: { orderId: "course" }, data: { before, after },
    });
    test("reassigned reminder stops only the previous driver and generation", async () => {
      const before = await reminder.get();
      await db.doc("DriverPushTokens/other").set({ driverId: "other", token: "other-token" });
      await reminder.update({ state: "pending", driverId: "other", generation: "new-generation" });
      const after = await reminder.get();
      await followups.stopDriverReminderAlarm.run({
        params: { orderId: "course" }, data: { before, after },
      });
      assert.equal(messages.length, 1);
      assert.deepEqual(messages[0].tokens, ["driver-token"]);
      assert.equal(messages[0].data.generation, generation);
      assert.equal(messages[0].data.driverId, "driver");
    });
    assert.equal(messages.length, 1);
    assert.equal(messages[0].data.type, "driver_reminder_alarm_stop");
    assert.equal(messages[0].data.generation, generation);
    assert.deepEqual(messages[0].tokens, ["driver-token"]);
    assert.equal(messages[0].notification, undefined);
  });
  test("no-response escalation still runs after departure without starting a late alarm", async () => {
    const past = Timestamp.fromMillis(Date.now() - 1000);
    const newGeneration = course({
      driverId: "driver", departureDate: past,
    }).generation;
    await db.doc("Orders/course").update({ departureDate: past });
    await reminder.update({
      state: "unconfirmed", generation: newGeneration,
      sentAt: Timestamp.fromMillis(Date.now() - 301000),
    });
    await followups.processFollowups();
    assert.equal(messages.length, 0);
    assert.equal((await db.collection("DriverTravelAlerts").get()).size, 1);
    assert.ok((await reminder.get()).data().alarmExpiredAt);
  });
}
