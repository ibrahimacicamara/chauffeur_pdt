"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { course, validatePosition, distanceMeters } = require("./reminder_logic");

const order = {
  departureDate: "2026-10-14T10:00:00Z",
  departureAddress: "Paris",
  commandStatus: [{ status: "OrderStatus.ASSIGNED", id: "driver" }],
};

test("H-1, author from commandStatus, ISO and Timestamp dates", () => {
  const result = course(order);
  assert.equal(result.driverId, "driver");
  assert.equal(result.due, Date.parse("2026-10-14T09:00:00Z"));
  assert.equal(course({ ...order, departureDate: { toMillis: () => result.departure } }).generation, result.generation);
  assert.notEqual(course({ ...order, departureDate: "2026-10-15T10:00:00Z" }).generation, result.generation);
});
test("unassigned and closed courses have no reminder", () => {
  assert.equal(course({ departureDate: order.departureDate }), null);
  for (const status of ["COMPLETED", "CANCELLED", "NO_SHOW", "INTERRUPTED"]) {
    assert.equal(course({ ...order, commandStatus: [...order.commandStatus, { status, id: "driver" }] }), null);
  }
  assert.equal(course({ ...order, status: "Terminée" }), null);
  assert.throws(() => course({ ...order, departureDate: "bad" }));
  assert.throws(() => course({ ...order, departureDate: "2026-10-14T10:00:00" }));
});
test("only fresh valid GPS fixes are accepted", () => {
  const now = Date.now();
  assert.equal(validatePosition({ latitude: 48, longitude: 2, capturedAt: now }, now).latitude, 48);
  for (const change of [{ latitude: 91 }, { longitude: NaN }, { capturedAt: now - 120001 }, { capturedAt: now + 30001 }]) {
    assert.throws(() => validatePosition({ latitude: 48, longitude: 2, capturedAt: now, ...change }, now));
  }
});
test("release ignores legacy ownership and reassignment uses the new driver", () => {
  const released = {
    ...order, driverId: "driver",
    commandStatus: [...order.commandStatus, { status: "PENDING_ASSIGNMENT", id: "" }],
  };
  assert.equal(course(released), null);
  assert.notEqual(course({
    ...released,
    commandStatus: [...released.commandStatus, { status: "ASSIGNED", id: "driver" }],
  }).generation, course(order).generation);
  assert.equal(course({
    ...released,
    commandStatus: [...released.commandStatus, { status: "ASSIGNED", id: "other" }],
  }).driverId, "other");
});
test("great-circle distance is expressed in meters, not road distance", () => {
  assert.equal(distanceMeters({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 0 }), 0);
  assert.equal(distanceMeters({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 1 }), 111195);
});
