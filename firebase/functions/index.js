const {onDocumentCreated, onDocumentDeleted} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const {deviceCanReceiveAlert} = require("./notification-policy");
const {isExpiredLocationShare} = require("./location-policy");

admin.initializeApp();

/** Removes `viewerId` from `ownerId`'s shared location, if it exists. */
async function revokeLocationViewer(firestore, ownerId, viewerId) {
  const reference = firestore.collection("locationShares").doc(ownerId);
  try {
    await reference.update({
      viewerIDs: admin.firestore.FieldValue.arrayRemove(viewerId),
    });
  } catch (error) {
    // NOT_FOUND: that user was not sharing a location.
    if (error.code !== 5) {
      throw error;
    }
  }
}

async function recursivelyDeleteQuery(firestore, query) {
  const snapshot = await query.get();
  for (const document of snapshot.docs) {
    await firestore.recursiveDelete(document.ref);
  }
}

async function removeMembership(query, userId) {
  const snapshot = await query.get();
  await Promise.all(snapshot.docs.map((document) => document.ref.update({
    memberIDs: admin.firestore.FieldValue.arrayRemove(userId),
  })));
}

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

    const eligibleTokens = new Map();
    for (const doc of tokensSnapshot.docs) {
      const data = doc.data() || {};
      const token = `${data.fcmToken || ""}`.trim();
      if (deviceCanReceiveAlert(data, alertType, alert.contextID) && !eligibleTokens.has(token)) {
        eligibleTokens.set(token, doc);
      }
    }

    const tokenEntries = Array.from(eligibleTokens.entries()).slice(0, 500);
    if (tokenEntries.length === 0) {
      return;
    }

    const tokens = tokenEntries.map(([token]) => token);

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
        cleanup.push(tokenEntries[index][1].ref.delete());
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

exports.deleteSocialAccount = onDocumentCreated(
  {
    document: "accountDeletionRequests/{userId}",
    retry: true,
  },
  async (event) => {
    const userId = event.params.userId;
    const requestSnapshot = event.data;
    if (!requestSnapshot || requestSnapshot.data()?.requesterID !== userId) {
      return;
    }

    const firestore = admin.firestore();

    await recursivelyDeleteQuery(
      firestore,
      firestore.collection("friendRequests").where("fromUserID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collection("friendRequests").where("toUserID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collection("friendships").where("members", "array-contains", userId)
    );

    await removeMembership(
      firestore.collection("friendGroups").where("memberIDs", "array-contains", userId),
      userId
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collection("friendGroups").where("ownerID", "==", userId)
    );

    await removeMembership(
      firestore.collection("courseCommunities").where("memberIDs", "array-contains", userId),
      userId
    );
    await removeMembership(
      firestore.collection("groupChats").where("memberIDs", "array-contains", userId),
      userId
    );

    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("comments").where("userID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("resources").where("createdByUserID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("messages").where("userID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("polls").where("createdByUserID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("calendarShares").where("ownerID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("socialNotifications").where("senderID", "==", userId)
    );
    await recursivelyDeleteQuery(
      firestore,
      firestore.collectionGroup("friendViews").where("viewerID", "==", userId)
    );

    // Shared locations: the user's own, and their access to everyone else's.
    await firestore.recursiveDelete(firestore.collection("locationShares").doc(userId));
    const visibleLocations = await firestore
      .collection("locationShares")
      .where("viewerIDs", "array-contains", userId)
      .get();
    await Promise.all(visibleLocations.docs.map((document) => document.ref.update({
      viewerIDs: admin.firestore.FieldValue.arrayRemove(userId),
    })));

    await firestore.recursiveDelete(firestore.collection("sharedSchedules").doc(userId));
    // Also removes users/{uid}/private, appBackups, deviceTokens, and alerts.
    await firestore.recursiveDelete(firestore.collection("users").doc(userId));

    try {
      await admin.auth().deleteUser(userId);
    } catch (error) {
      if (error.code !== "auth/user-not-found") {
        throw error;
      }
    }

    await requestSnapshot.ref.delete();
  }
);

// When either person ends a friendship, stop sharing in both directions even
// if the other person's app is not open to notice.
exports.cleanUpEndedFriendship = onDocumentDeleted(
  "friendships/{friendshipId}",
  async (event) => {
    const members = event.data?.data()?.members;
    if (!Array.isArray(members) || members.length !== 2) {
      return;
    }

    const firestore = admin.firestore();
    const [first, second] = members;
    await Promise.all([
      revokeLocationViewer(firestore, first, second),
      revokeLocationViewer(firestore, second, first),
      firestore.collection("sharedSchedules").doc(first).collection("friendViews").doc(second).delete(),
      firestore.collection("sharedSchedules").doc(second).collection("friendViews").doc(first).delete(),
    ]);
  }
);

// Shared locations expire on schedule even if the sharer's phone is off.
exports.expireLocationShares = onSchedule("every 30 minutes", async () => {
  const firestore = admin.firestore();
  const now = new Date();
  const expired = await firestore
    .collection("locationShares")
    .where("expiresAtTimestamp", "<=", admin.firestore.Timestamp.fromDate(now))
    .get();

  // Documents nobody has updated in two weeks are abandoned; remove them too.
  const staleCutoff = admin.firestore.Timestamp.fromMillis(now.getTime() - 14 * 24 * 60 * 60 * 1000);
  const abandoned = await firestore
    .collection("locationShares")
    .where("updatedAtServer", "<=", staleCutoff)
    .get();

  const documents = new Map();
  for (const document of [...expired.docs, ...abandoned.docs]) {
    if (isExpiredLocationShare(document.data(), now)) {
      documents.set(document.id, document.ref);
    }
  }

  await Promise.all(Array.from(documents.values()).map((reference) => reference.delete()));
  if (documents.size > 0) {
    logger.info("Removed expired shared locations", {count: documents.size});
  }
});
