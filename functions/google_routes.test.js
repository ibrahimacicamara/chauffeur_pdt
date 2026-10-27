"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { computeTravel } = require("./google_routes");
const { checkCourse } = require("./driver_availability");
const { course } = require("./reminder_logic");

const geocoded = {
  status: "OK",
  results: [{ geometry: { location: { lat: 48.85, lng: 2.35 } } }],
};
const origin = { latitude: 48, longitude: 2 };
function response(data) { return { ok: true, json: async () => data }; }

test("Routes uses server GPS, traffic-aware driving and preserves the exact duration", async () => {
  for (const seconds of [3599, 3600, 3600.01, 3601]) {
    const calls = [];
    const result = await computeTravel(origin, "Synthetic address", "fake-key", async (url, options) => {
      calls.push({ url, options });
      return response(calls.length === 1 ? geocoded :
        { routes: [{ duration: `${seconds}s`, distanceMeters: 42000 }] });
    });
    assert.equal(result.durationSeconds, seconds);
    assert.equal(result.routeDistanceMeters, 42000);
    const body = JSON.parse(calls[1].options.body);
    assert.equal(body.routingPreference, "TRAFFIC_AWARE");
    assert.equal(body.travelMode, "DRIVE");
    assert.deepEqual(body.origin.location.latLng, origin);
    assert.equal(calls[1].options.headers["X-Goog-FieldMask"], "routes.duration,routes.distanceMeters");
  }
});

test("unresolved, ambiguous and partial departure addresses fail explicitly", async () => {
  for (const data of [
    { status: "ZERO_RESULTS", results: [] },
    { status: "REQUEST_DENIED" },
    { status: "OK", results: [] },
    { status: "OK", results: [geocoded.results[0], geocoded.results[0]] },
    { status: "OK", results: [{ ...geocoded.results[0], partial_match: true }] },
  ]) {
    await assert.rejects(computeTravel(origin, "Test", "fake-key", async () => response(data)));
  }
});

test("network errors, bad JSON and invalid routes never become successful confirmations", async () => {
  for (const fetcher of [
    async () => { throw new Error("network"); },
    async () => ({ ok: false }),
    async () => ({ ok: true, json: async () => { throw new Error("invalid"); } }),
  ]) {
    await assert.rejects(computeTravel(origin, "Test", "fake-key", fetcher));
  }
  for (const route of [null, { duration: "bad", distanceMeters: 1 },
    { duration: "3601s", distanceMeters: -1 }]) {
    let count = 0;
    await assert.rejects(computeTravel(origin, "Test", "fake-key", async () =>
      response(++count === 1 ? geocoded : { routes: route ? [route] : [] })));
  }
});

test("confirmation checks assignment, generation and the exact H-1 window", () => {
  const now = Date.now();
  const order = { driverId: "driver", departureDate: new Date(now + 3600000), departureAddress: "Test" };
  const generation = course(order).generation;
  assert.equal(checkCourse(order, "driver", generation, now).driverId, "driver");
  assert.throws(() => checkCourse(order, "other", generation, now));
  assert.throws(() => checkCourse(order, "driver", "old", now));
  assert.throws(() => checkCourse(order, "driver", generation, now - 1));
  assert.throws(() => checkCourse(order, "driver", generation, now + 3600000));
  assert.throws(() => checkCourse({ ...order, status: "Annulée" }, "driver", generation, now));
});
