function normalizedContextID(value) {
  return `${value || ""}`.trim();
}

function deviceCanReceiveAlert(device, alertType, contextID) {
  const token = `${device.fcmToken || ""}`.trim();
  if (!token || device.remoteNotificationsRegistered === false) {
    return false;
  }

  if (alertType === "groupMessage") {
    if (device.groupNotificationsEnabled === false) {
      return false;
    }

    const normalizedContext = normalizedContextID(contextID);
    const mutedContexts = Array.isArray(device.mutedGroupChatIDs)
      ? device.mutedGroupChatIDs.map(normalizedContextID)
      : [];
    return !normalizedContext || !mutedContexts.includes(normalizedContext);
  }

  return device.feedNotificationsEnabled !== false;
}

module.exports = {deviceCanReceiveAlert};
