# Firebase Social Setup

Enable these Firebase products for the app:

- Authentication
  - Email/Password
  - Anonymous
- Cloud Firestore

Add the Apple app to Firebase and place `GoogleService-Info.plist` in the `RPI Central` target.

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

## Notes

- The app searches users by `usernameLower` and `displayNameLower`.
- Guest mode uses Firebase anonymous auth.
- Schedule sharing is friend-only and gated by `shareSchedule`.
- Location sharing is not implemented yet.
