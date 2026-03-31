# Firebase Social Setup

Enable these Firebase products for the app:

- Authentication
  - Email/Password
  - Anonymous
- Cloud Firestore
- Cloud Functions
- Cloud Messaging

Add the Apple app to Firebase and place `GoogleService-Info.plist` in the `RPI Central` target.

To make social notifications work while the app is backgrounded or closed, also:

- enable the `Push Notifications` capability in the iOS app target
- enable `Background Modes > Remote notifications` if you want silent/background handling later
- upload an APNs authentication key or certificate in Firebase Console > Project Settings > Cloud Messaging
- deploy the Firebase function in `firebase/functions`

## Firestore collections

- `users/{uid}`
  - `displayName`
  - `displayNameLower`
  - `username`
  - `usernameLower`
  - `email`
  - `isGuest`
  - `shareSchedule`
  - `shareLocation`
  - `createdAt`
  - `lastScheduleAt`
  - `deviceTokens/{installationID}`
    - `fcmToken`
    - `feedNotificationsEnabled`
    - `groupNotificationsEnabled`
    - `platform`
    - `updatedAt`
- `friendRequests/{requestID}`
  - `fromUserID`
  - `toUserID`
  - `status`
  - `createdAt`
  - `respondedAt`
- `friendships/{sortedUidA_sortedUidB}`
  - `members`
  - `createdAt`
- `sharedSchedules/{uid}`
  - `ownerID`
  - `semesterCode`
  - `generatedAt`
  - `items`

## Rules

Deploy the rules from:

```text
firebase/firestore.rules
```

Deploy the social push function from:

```text
firebase/functions
```

## Notes

- The app searches users by `usernameLower` and `displayNameLower`.
- Guest mode uses Firebase anonymous auth.
- Schedule sharing is friend-only and gated by `shareSchedule`.
- Location sharing is not implemented yet.
- Social push notifications are sent from a Firestore-triggered Firebase Function when a document is created under `users/{uid}/socialNotifications`.
