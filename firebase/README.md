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
  - `acceptedRequestID`
  - `createdAt`
- `users/{uid}/private/appState` (owner-only)
  - `webAppState`, `webAppStateUpdatedAt`, `webAppStateSource`, `webAppStateVersion`
  - Replaces the same fields on the public `users/{uid}` document, which any
    signed-in user can read. The iOS app migrates the old fields here and deletes
    them from the profile on its next sync.
- `sharedSchedules/{uid}` (class and academic items only) and
  `sharedSchedules/{uid}/friendViews/{friendUid}` (plus personal events shared
  with that friend)
  - `ownerID`, `viewerID` (friend views)
  - `semesterCode`
  - `generatedAt`
  - `schemaVersion` (`2`)
  - `coverageStart`, `coverageEnd` — the published range. Version 2 covers the
    rest of the current term plus finals (up to 200 days), so friends' copies stay
    correct even when the owner doesn't open the app.
  - `items`
- `locationShares/{uid}`
  - `ownerID`, `viewerIDs` (friends allowed to read it)
  - `latitude`, `longitude`, `accuracy`, `precision` (`precise` or `building`)
  - `placeID`, `placeName`, `placeKind`, `isOnCampus` — campus building resolved on device
  - `updatedAt` (ISO string), `updatedAtServer` (timestamp)
  - `expiresAt` (ISO string or empty), `expiresAtTimestamp` (timestamp or null)
  - `source` (`foreground`, `background`, `visit`, `manual`)

## Rules

Deploy the rules from:

```text
firebase/firestore.rules
```

Deploy the social push function from:

```text
firebase/functions
```

Install and run the Firebase checks before deploying:

```sh
cd firebase/functions
npm ci
npm test
npm run test:rules
```

Deploy the rules and functions together after distributing a compatible app build:

```sh
firebase deploy --only firestore:rules,functions
```

The friendship rules require the new app build to write `acceptedRequestID`. Older
TestFlight builds cannot accept new friend requests after these rules are deployed,
so testers should update first.

## Functions

| Function | Trigger | Purpose |
| --- | --- | --- |
| `sendSocialNotificationPush` | `users/{uid}/socialNotifications` created | Sends social pushes, honoring per-device preferences |
| `deleteSocialAccount` | `accountDeletionRequests/{uid}` created | Deletes a user's social data, shared locations, and auth account |
| `cleanUpEndedFriendship` | `friendships/{id}` deleted | Revokes location access and schedule views in both directions |
| `expireLocationShares` | Every 30 minutes | Deletes shared locations past their end time or abandoned for 14 days |

`expireLocationShares` is a scheduled function, which needs Cloud Scheduler
(Blaze plan). The first deploy enables the Cloud Scheduler API for you.

## Deploying this update

1. Ship the iOS build first (TestFlight). Older builds keep working for reading, but
   the tightened chat rules reject group-chat writes whose member list includes
   someone outside the friend group or class, and poll votes must now update only
   the voter's own entry (`votesByUserID.<uid>`).
2. Deploy rules and functions together. The functions now run on Node 22
   (firebase-admin 14 requires it); `firebase/functions/.nvmrc` pins it, so run
   `nvm use` there first:

   ```sh
   cd firebase/functions && nvm use && npm ci && npm test && npm run test:rules && cd ../..
   firebase deploy --only firestore:rules,functions
   ```

3. Update the web app to read and write `users/{uid}/private/appState` instead of
   the `webAppState*` fields on `users/{uid}`. Until then, web → phone sync still
   works (the phone migrates the old fields), but the web app won't see saves made
   on the phone.

## Local emulators

`firebase/emulator/` seeds the Auth and Firestore emulators with sample friends,
chats, groups, schedules, locations, and plans, and Debug builds can point at
them. See [emulator/README.md](emulator/README.md).

## Moderators and account deletion

Moderator access is controlled by the Firebase Authentication custom claim
`moderator: true`; profile names and usernames never grant moderator authority. Set
the claim from a trusted Admin SDK environment, then have that user sign out and
back in so Firebase refreshes the ID token.

The in-app Delete Account action creates `accountDeletionRequests/{uid}`. The
`deleteSocialAccount` Cloud Function removes the user's social data and Firebase
Authentication account. Do not release the account-deletion UI without deploying
this function.

## Notes

- The app searches users by `usernameLower` and `displayNameLower`.
- Email addresses are kept in Firebase Authentication and are not written to public
  `users/{uid}` profile documents.
- Guest mode uses Firebase anonymous auth.
- Schedule sharing is friend-only and gated by `shareSchedule`. Older builds also
  copied the class schedule onto the public profile (`sharedScheduleLegacy*`); the
  current app deletes those fields.
- Location sharing is opt-in. Only uids in `viewerIDs` can read a location, a viewer
  can remove only themselves, and friends query with
  `where("viewerIDs", "array-contains", uid)`.
- Social push notifications are sent from a Firestore-triggered Firebase Function when a document is created under `users/{uid}/socialNotifications`.
