"use strict";

const { test, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");

const local = process.env.FIRESTORE_EMULATOR_HOST;
if (!local) {
  test("Firestore integration (run with emulators:exec)", { skip: true }, () => {});
} else {
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(local)) throw new Error("Local emulator required");
  process.env.GCLOUD_PROJECT = "demo-chauffeur";
  process.env.GOOGLE_CLOUD_PROJECT = "demo-chauffeur";
  process.env.GCE_METADATA_HOST = "127.0.0.1:9";
  process.env.GCE_METADATA_IP = "127.0.0.1:9";
  const backend = require("./index");
  const { getFirestore, Timestamp } = require("firebase-admin/firestore");
  const { getMessaging } = require("firebase-admin/messaging");
  const db = getFirestore();
  const messaging = getMessaging();
  const originalSend = messaging.sendEachForMulticast;
  let messages;

  async function seed() {
    await db.doc("Drivers/driver").set({ remindersEnabled: true });
    await db.doc("Drivers/other").set({ remindersEnabled: true });
    await db.doc("Orders/course").set({
      departureDate: Timestamp.fromMillis(Date.now() + 30 * 60000),
      departureAddress: "Paris",
      commandStatus: [{ status: "OrderStatus.ASSIGNED", id: "driver" }],
    });
    await backend.syncDriverReminder.run({ params: { orderId: "course" } });
  }

  beforeEach(async () => {
    for (const name of [
      "Drivers",
      "Orders",
      "DriverReminders",
      "DriverPushTokens",
      "DriverCourseNotifications",
    ]) {
      const docs = await db.collection(name).get();
      const batch = db.batch();
      for (const doc of docs.docs) batch.delete(doc.ref);
      await batch.commit();
    }
    messages = [];
    await seed();
    messaging.sendEachForMulticast = async (message) => {
      messages.push(message);
      return { successCount: message.tokens.length, responses: message.tokens.map(() => ({ success: true })) };
    };
  });
  afterEach(() => {
    messaging.sendEachForMulticast = originalSend;
  });

  test("token registration and H-1 push are idempotent", async () => {
    await backend.registerDriverPushToken.run({ auth: { uid: "driver" }, data: { token: "emulator-token-driver" } });
    await backend.sendDriverReminders.run({});
    assert.equal(messages.length, 1);
    assert.equal(messages[0].data.orderId, "course");
    assert.equal(messages[0].data.driverId, "driver");
    assert.equal((await db.doc("DriverReminders/course").get()).data().state, "sent");
    await backend.sendDriverReminders.run({});
    assert.equal(messages.length, 1);
    await backend.unregisterDriverPushToken.run({ auth: { uid: "driver" }, data: { token: "emulator-token-driver" } });
    assert.equal((await db.collection("DriverPushTokens").get()).size, 0);
  });

  test("new courses match categories case-insensitively and notify available drivers once", async () => {
    await db.doc("Drivers/driver").set({
      available: true,
      categories: ["eco", "VAN"],
    });
    await db.doc("Drivers/other").set({
      remindersEnabled: true,
      available: false,
      categories: ["van"],
    });
    await db.doc("Drivers/wrong-category").set({
      remindersEnabled: true,
      available: true,
      categories: ["eco", "premium van"],
    });
    await backend.registerDriverPushToken.run({
      auth: { uid: "driver" },
      data: { token: "emulator-token-course-driver" },
    });
    await backend.registerDriverPushToken.run({
      auth: { uid: "other" },
      data: { token: "emulator-token-course-other" },
    });
    await backend.registerDriverPushToken.run({
      auth: { uid: "wrong-category" },
      data: { token: "emulator-token-course-wrong-category" },
    });
    const orderRef = db.doc("Orders/new-course");
    await orderRef.set({
      category: "van",
      commandStatus: [{ status: "OrderStatus.PENDING_ASSIGNMENT", id: "" }],
    });
    const event = {
      params: { orderId: "new-course" },
      data: await orderRef.get(),
    };

    await backend.notifyDriversForNewCourse.run(event);
    await backend.notifyDriversForNewCourse.run(event);

    assert.equal(messages.length, 1);
    assert.deepEqual(messages[0].tokens, ["emulator-token-course-driver"]);
    assert.equal(messages[0].data.type, "driver_course");
    assert.equal(messages[0].data.orderId, "new-course");
    assert.equal(messages[0].data.driverId, "driver");
    assert.equal(
      (await db.doc("DriverCourseNotifications/new-course").get()).data().state,
      "sent",
    );
  });

  test("reassignment updates the reminder owner", async () => {
    await db.doc("Orders/course").update({
      commandStatus: [{ status: "OrderStatus.ASSIGNED", id: "other" }],
    });
    await backend.syncDriverReminder.run({ params: { orderId: "course" } });
    assert.equal((await db.doc("DriverReminders/course").get()).data().driverId, "other");
    assert.equal((await db.doc("DriverReminders/course").get()).data().state, "pending");
  });

  test("rescheduling, cancellation and expiration invalidate the old reminder", async () => {
    await db.doc("Orders/course").update({ departureDate: Timestamp.fromMillis(Date.now() + 2 * 3600000) });
    await backend.syncDriverReminder.run({ params: { orderId: "course" } });
    await db.doc("Orders/course").update({ status: "Annulée" });
    await backend.syncDriverReminder.run({ params: { orderId: "course" } });
    assert.equal((await db.doc("DriverReminders/course").get()).data().state, "cancelled");
    await seed();
    await db.doc("Orders/course").update({ departureDate: Timestamp.fromMillis(Date.now() - 60000) });
    await db.doc("DriverReminders/course").update({
      state: "sent", departureDate: Timestamp.fromMillis(Date.now() - 60000),
    });
    await backend.sendDriverReminders.run({});
    assert.equal((await db.doc("DriverReminders/course").get()).data().state, "unconfirmed");
  });
}
