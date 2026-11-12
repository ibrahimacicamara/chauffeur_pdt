"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { FieldValue } = require("firebase-admin/firestore");
const { anonymizeOrder } = require("./account_deletion");

const uid = "driver-1";
const alias = "supprime-abc";
const where = { latitude: 48.8, longitude: 2.3 };
const event = (status, id, date) => ({ status: `OrderStatus.${status}`, id, date, location: where });
const now = new Date("2026-11-20T10:00:00Z");

test("ignore les courses d'autres chauffeurs", () => {
  const data = { commandStatus: [event("ASSIGNED", "other", "2026-11-01T10:00:00Z")] };
  assert.equal(anonymizeOrder(data, uid, alias, now), null);
});

test("remet en attente une course à venir et anonymise l'historique", () => {
  const data = {
    driverId: uid,
    commandStatus: [
      event("PENDING_ASSIGNMENT", "", "2026-11-01T10:00:00Z"),
      event("ASSIGNED", uid, "2026-11-01T10:05:00Z"),
    ],
  };
  const { update, released } = anonymizeOrder(data, uid, alias, now);
  assert.equal(released, true);
  assert.deepEqual(update.commandStatus.map((e) => e.id), ["", alias, ""]);
  assert.equal(update.commandStatus.at(-1).status, "OrderStatus.PENDING_ASSIGNMENT");
  assert.deepEqual(update.commandStatus.at(-1).location, where);
  assert.ok(update.driverId.isEqual(FieldValue.delete()));
  assert.ok(!JSON.stringify(update.commandStatus).includes(uid));
});

test("conserve une course terminée sous pseudonyme", () => {
  const data = {
    driverId: uid,
    commandStatus: [
      event("ASSIGNED", uid, "2026-11-01T10:00:00Z"),
      event("COMPLETED", uid, "2026-11-01T12:00:00Z"),
    ],
  };
  const { update, released } = anonymizeOrder(data, uid, alias, now);
  assert.equal(released, false);
  assert.equal(update.driverId, alias);
  assert.equal(update.commandStatus.length, 2);
  assert.ok(update.commandStatus.every((e) => e.id === alias));
});

test("refuse pendant qu'un client est à bord", () => {
  const data = { commandStatus: [event("CLIENT_ON_BOARD", uid, "2026-11-01T10:00:00Z")] };
  assert.throws(() => anonymizeOrder(data, uid, alias, now), { code: "in-ride" });
});

test("anonymise sans libérer une course reprise par un autre chauffeur", () => {
  const data = {
    commandStatus: [
      event("ASSIGNED", uid, "2026-11-01T10:00:00Z"),
      event("PENDING_ASSIGNMENT", "", "2026-11-01T11:00:00Z"),
      event("ASSIGNED", "other", "2026-11-01T12:00:00Z"),
    ],
  };
  const { update, released } = anonymizeOrder(data, uid, alias, now);
  assert.equal(released, false);
  assert.equal(update.driverId, undefined);
  assert.deepEqual(update.commandStatus.map((e) => e.id), [alias, "", "other"]);
});
