const test = require("node:test");
const assert = require("node:assert/strict");
const {isExpiredLocationShare} = require("./location-policy");

const now = new Date("2026-09-28T12:00:00Z");

test("keeps a location that has not expired", () => {
  assert.equal(isExpiredLocationShare({
    expiresAt: "2026-09-28T13:00:00Z",
    updatedAt: "2026-09-28T11:59:00Z",
  }, now), false);
  assert.equal(isExpiredLocationShare({expiresAt: "", updatedAt: "2026-09-28T11:00:00Z"}, now), false);
});

test("removes a location after its sharing window ends", () => {
  assert.equal(isExpiredLocationShare({
    expiresAt: "2026-09-28T11:00:00Z",
    updatedAt: "2026-09-28T10:59:00Z",
  }, now), true);
  assert.equal(isExpiredLocationShare({
    expiresAtTimestamp: {toDate: () => new Date("2026-09-28T11:30:00Z")},
  }, now), true);
});

test("removes a location nobody has updated for two weeks", () => {
  assert.equal(isExpiredLocationShare({updatedAt: "2026-09-10T12:00:00Z", expiresAt: ""}, now), true);
});
