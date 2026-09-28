const assert = require("node:assert/strict");
const test = require("node:test");

// Loading index.js catches SDK API mismatches (for example firebase-admin
// dropping admin.firestore()) that the pure policy tests never touch.
test("functions load and export every trigger", () => {
  process.env.GCLOUD_PROJECT ||= "demo-rpi-central";
  const functions = require("./index.js");
  assert.deepEqual(Object.keys(functions).sort(), [
    "cleanUpEndedFriendship",
    "deleteSocialAccount",
    "expireLocationShares",
    "sendSocialNotificationPush",
  ]);
});
