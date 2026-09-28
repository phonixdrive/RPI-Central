const ABANDONED_AFTER_MS = 14 * 24 * 60 * 60 * 1000;

function toDate(value) {
  if (!value) {
    return null;
  }
  if (typeof value.toDate === "function") {
    return value.toDate();
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
  return null;
}

/** A shared location is removed once its chosen duration ends or it is abandoned. */
function isExpiredLocationShare(data, now = new Date()) {
  const expiresAt = toDate(data.expiresAtTimestamp) || toDate(data.expiresAt);
  if (expiresAt && expiresAt <= now) {
    return true;
  }

  const updatedAt = toDate(data.updatedAtServer) || toDate(data.updatedAt);
  return Boolean(updatedAt) && now.getTime() - updatedAt.getTime() >= ABANDONED_AFTER_MS;
}

module.exports = {isExpiredLocationShare};
