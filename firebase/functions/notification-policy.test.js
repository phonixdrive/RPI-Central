const test = require("node:test");
const assert = require("node:assert/strict");
const {deviceCanReceiveAlert} = require("./notification-policy");

test("rejects missing or unregistered push tokens", () => {
  assert.equal(deviceCanReceiveAlert({}, "feed", null), false);
  assert.equal(deviceCanReceiveAlert({fcmToken: "token", remoteNotificationsRegistered: false}, "feed", null), false);
});

test("respects feed and group notification preferences", () => {
  const device = {fcmToken: "token", remoteNotificationsRegistered: true};
  assert.equal(deviceCanReceiveAlert(device, "feed", null), true);
  assert.equal(deviceCanReceiveAlert({...device, feedNotificationsEnabled: false}, "feed", null), false);
  assert.equal(deviceCanReceiveAlert(device, "groupMessage", "chat-1"), true);
  assert.equal(deviceCanReceiveAlert({...device, groupNotificationsEnabled: false}, "groupMessage", "chat-1"), false);
});

test("does not notify a device for its muted chat", () => {
  const device = {
    fcmToken: "token",
    remoteNotificationsRegistered: true,
    mutedGroupChatIDs: ["chat-1", " chat-2 "],
  };
  assert.equal(deviceCanReceiveAlert(device, "groupMessage", "chat-1"), false);
  assert.equal(deviceCanReceiveAlert(device, "groupMessage", "chat-2"), false);
  assert.equal(deviceCanReceiveAlert(device, "groupMessage", "chat-3"), true);
});
