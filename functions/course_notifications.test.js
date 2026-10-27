"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { courseCategory, hasCategory, isAvailableCourse } = require("./course_notifications");

test("category membership ignores case but requires a complete list entry", () => {
  for (const category of ["van", "VAN", "Van", "vAn"]) {
    assert.equal(hasCategory(["eco", "VAN"], category), true);
    assert.equal(hasCategory(["van"], category), true);
  }
  assert.equal(hasCategory(["ECO"], "eco"), true);
  assert.equal(hasCategory(["premium van"], "van"), false);
  assert.equal(hasCategory(["van"], "eco"), false);
  assert.equal(hasCategory([], "van"), false);
  assert.equal(hasCategory(null, "van"), false);
  assert.equal(hasCategory([null, 42], "van"), false);
  assert.equal(hasCategory([""], ""), false);
  assert.equal(hasCategory(["van"], null), false);
});

test("only non-empty course categories are eligible", () => {
  assert.equal(courseCategory({ category: "van" }), "van");
  assert.equal(courseCategory({ category: " Van " }), " Van ");
  assert.equal(courseCategory({ category: " " }), null);
  assert.equal(courseCategory({ category: 4 }), null);
});

test("new unassigned courses are eligible, assigned or closed courses are not", () => {
  assert.equal(isAvailableCourse({ category: "van" }), true);
  assert.equal(
    isAvailableCourse({
      commandStatus: [{ status: "OrderStatus.PENDING_ASSIGNMENT", id: "" }],
    }),
    true,
  );
  assert.equal(
    isAvailableCourse({
      commandStatus: [{ status: "OrderStatus.ASSIGNED", id: "driver" }],
    }),
    false,
  );
  assert.equal(
    isAvailableCourse({
      driverId: "legacy-driver",
      commandStatus: [
        { status: "OrderStatus.ASSIGNED", id: "old-driver" },
        { status: "OrderStatus.PENDING_ASSIGNMENT", id: "" },
      ],
    }),
    true,
  );
  assert.equal(isAvailableCourse({ status: "Annulée" }), false);
  assert.equal(
    isAvailableCourse({
      commandStatus: [{ status: "OrderStatus.CANCELLED", id: "" }],
    }),
    false,
  );
  assert.throws(
    () => isAvailableCourse({ commandStatus: "invalid" }),
    /Historique invalide/,
  );
  assert.throws(
    () => isAvailableCourse({ commandStatus: [{ status: "ASSIGNED", id: 1 }] }),
    /Étape d’historique invalide/,
  );
});
