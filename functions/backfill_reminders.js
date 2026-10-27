"use strict";

// Explicit administrative bootstrap for orders created before function deployment.
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { course } = require("./reminder_logic");
initializeApp();
const db = getFirestore();

async function main() {
  const write = process.argv.includes("--write");
  const orders = await db.collection("Orders").get();
  let count = 0;
  for (const doc of orders.docs) {
    await db.runTransaction(async (tx) => {
      const ref = db.collection("DriverReminders").doc(doc.id);
      const [fresh, existing] = await Promise.all([tx.get(doc.ref), tx.get(ref)]);
      const planned = course(fresh.data());
      if (!planned || planned.departure <= Date.now() || existing.exists) return;
      count++;
      if (write) tx.set(ref, {
        orderId: doc.id, driverId: planned.driverId, generation: planned.generation,
        departureDate: Timestamp.fromMillis(planned.departure),
        dueAt: Timestamp.fromMillis(planned.due),
        nextAttemptAt: Timestamp.fromMillis(planned.due),
        state: "pending", attempts: 0,
      });
    });
  }
  console.log(`${write ? "Created" : "Dry run, eligible"}: ${count}`);
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
