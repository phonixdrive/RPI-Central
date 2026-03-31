const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

admin.initializeApp();

exports.sendSocialNotificationPush = onDocumentCreated(
  "users/{userId}/socialNotifications/{notificationId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      return;
    }

    const alert = snapshot.data() || {};
    const userId = event.params.userId;
    const alertType = `${alert.type || ""}`;
    const title = `${alert.title || "RPI Central"}`.trim() || "RPI Central";
    const body = `${alert.body || ""}`.trim();
    if (!body) {
      return;
    }

    const tokensSnapshot = await admin
      .firestore()
      .collection("users")
      .doc(userId)
      .collection("deviceTokens")
      .get();

    if (tokensSnapshot.empty) {
      return;
    }

    const eligibleTokenDocs = tokensSnapshot.docs.filter((doc) => {
      const data = doc.data() || {};
      const token = `${data.fcmToken || ""}`.trim();
      if (!token) {
        return false;
      }
      if (data.remoteNotificationsRegistered === false) {
        return false;
      }

      if (alertType === "groupMessage") {
        return data.groupNotificationsEnabled !== false;
      }

      return data.feedNotificationsEnabled !== false;
    });

    if (eligibleTokenDocs.length === 0) {
      return;
    }

    const tokens = eligibleTokenDocs
      .map((doc) => `${doc.data().fcmToken || ""}`.trim())
      .filter(Boolean);

    if (tokens.length === 0) {
      return;
    }

    const response = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: {
        title,
        body,
      },
      data: {
        socialAlertId: `${alert.id || snapshot.id || ""}`,
        socialType: alertType,
        socialContextID: `${alert.contextID || ""}`,
        senderID: `${alert.senderID || ""}`,
      },
      apns: {
        headers: {
          "apns-priority": "10",
        },
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    });

    const cleanup = [];
    response.responses.forEach((result, index) => {
      if (result.success) {
        return;
      }

      const errorCode = result.error && result.error.code ? result.error.code : "";
      const shouldDelete =
        errorCode === "messaging/invalid-registration-token" ||
        errorCode === "messaging/registration-token-not-registered";

      if (shouldDelete) {
        cleanup.push(eligibleTokenDocs[index].ref.delete());
      } else {
        logger.warn("Push send failed", {
          notificationId: snapshot.id,
          userId,
          errorCode,
        });
      }
    });

    if (cleanup.length > 0) {
      await Promise.allSettled(cleanup);
    }
  }
);
