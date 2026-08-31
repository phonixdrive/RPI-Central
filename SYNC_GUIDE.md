# Phone and Web Sync Guide

RPI Central uses a local-first data model. The iPhone keeps working from its on-device stores, while signed-in users can explicitly save that state to Firebase and restore it on another supported client.

## User controls

Open **Settings → Phone & Web Sync** in the iOS app to:

- **Save This Phone** — upload the current phone state as the latest shared snapshot.
- **Update This Phone** — replace local state with the latest saved snapshot.
- **Create recovery backup** — save a named point-in-time copy without replacing the latest snapshot.
- **Restore** — replace the phone and shared snapshot with a selected recovery backup.
- **Delete** — remove an unneeded recovery backup.

RPI Central also creates a recovery backup about once every seven days while the user is signed in. It does not silently pull cloud state over newer local work.

## Safety behavior

Before a save, update, or restore can replace data, the sync manager preserves the relevant current phone and/or cloud state as recovery backups. After a cloud snapshot is applied, the app refreshes its local stores and social course/schedule data.

Dashboard layout is included in the shared settings snapshot. It is also saved immediately on device in both `UserDefaults` and an atomic Application Support file, so a force-quit does not normally discard a completed drag or resize.

## Firebase layout

The latest shared snapshot is stored on the signed-in user document:

- `users/{uid}.webAppState`
- `users/{uid}.webAppStateUpdatedAt`
- `users/{uid}.webAppStateVersion`
- `users/{uid}.webAppStateSource`

Recovery snapshots are stored under:

- `users/{uid}/appBackups/{backupID}`

The current snapshot includes calendar settings, dashboard layout, enrolled courses, personal events, grades, notes, meeting and exam overrides, prerequisite assumptions, tasks, GPA overrides, meal-plan state, Flex Dollars state, and study-timer preferences.

## Firestore rules

The repository rules should permit users to access only their own backup documents:

```txt
match /appBackups/{backupID} {
  allow read, create, update, delete: if isSelf(userID);
}
```

Deploy rule changes from an authenticated Firebase CLI session:

```sh
firebase deploy --only firestore:rules
```

Never commit service-account keys, access tokens, or `GoogleService-Info.plist`.

## Troubleshooting

- Confirm the app is signed into the expected Firebase account.
- Refresh the sync screen to reload the latest snapshot and recovery-backup list.
- If a restore was unintended, select the automatically created “Before Restore” backup.
- If cloud controls are unavailable, confirm the build includes Firebase Auth and Firestore and that the Apple app has a valid Firebase configuration.
