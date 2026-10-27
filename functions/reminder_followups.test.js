"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { followupDue } = require("./reminder_followups");

test("followups use exact one-minute and five-minute thresholds since FCM acceptance", () => {
  const job = { followupVersion: 1, state: "sent", sentAt: { toMillis: () => 1000 } };
  assert.deepEqual(followupDue(job, 60999), { alarm: false, alert: false });
  assert.deepEqual(followupDue(job, 61000), { alarm: true, alert: false });
  assert.deepEqual(followupDue(job, 300999), { alarm: true, alert: false });
  assert.deepEqual(followupDue(job, 301000), { alarm: true, alert: true });
  assert.deepEqual(followupDue({
    ...job, alarmSentAt: {}, noResponseAlertId: "alert",
  }, 500000), { alarm: false, alert: false });
  assert.deepEqual(followupDue({
    ...job, alarmExpiredAt: {}, noResponseAlertId: "alert",
  }, 500000), { alarm: false, alert: false });
});

test("unaccepted, confirmed and cancelled reminders never relaunch", () => {
  for (const state of ["pending", "confirmed", "cancelled", "failed"]) {
    assert.deepEqual(followupDue({
      followupVersion: 1, state, sentAt: { toMillis: () => 0 },
    }, 999999), { alarm: false, alert: false });
  }
  assert.deepEqual(followupDue({ state: "sent" }, 999999), { alarm: false, alert: false });
  assert.deepEqual(followupDue(null, 999999), { alarm: false, alert: false });
  assert.deepEqual(followupDue({
    state: "sent", sentAt: { toMillis: () => 0 },
  }, 999999), { alarm: false, alert: false });
  assert.deepEqual(followupDue({
    followupVersion: 1, state: "unconfirmed", sentAt: { toMillis: () => 0 },
  }, 300000), { alarm: true, alert: true });
});
