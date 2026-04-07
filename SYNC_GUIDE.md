# Web and iPhone Sync Guide

The web app now supports manual sync with backups.

Cloud locations:

- `users/{uid}.webAppState`
- `users/{uid}.webAppStateUpdatedAt`
- `users/{uid}.webAppStateVersion`
- `users/{uid}.webAppStateSource`
- `users/{uid}/appBackups/{backupID}`

What is inside `webAppState`:

- calendar and personal events
- enrolled courses
- grades and grade breakdown data
- semester GPA overrides
- notes
- meeting overrides and exam dates
- prerequisite assumptions
- tasks
- meal plan state
- flex dollar state
- pomodoro preset
- settings that the web app stores in `AppState`

What the web app can do now:

- pull cloud state into the browser
- push browser state to the cloud
- create backup snapshots before pull, push, restore, and import
- restore older cloud backups
- download a portable JSON backup file
- import a portable JSON backup file

Important safety behavior:

- sync is manual on the web right now
- the web app does not silently overwrite local or cloud state

Why the iPhone app still needs changes:

The iPhone app currently keeps most of this data in local `UserDefaults`, not in Firestore. That means the web app cannot see the phone's existing calendar, GPA, tasks, or prerequisite state until the iPhone app also reads and writes the shared sync payload.

Main iPhone files to update:

- `RPI Central-reference/RPI Central/CalenderViewModel.swift`
  - app settings and semester GPA overrides
  - enrolled courses
  - grades and notes
  - personal events
  - meeting overrides
  - exam dates
  - prerequisite assumptions
  - hidden LMS and calendar state
- `RPI Central-reference/RPI Central/GPACalculator.swift`
  - `GradeBreakdownStore` is still local-only
- `RPI Central-reference/RPI Central/HomeView.swift`
  - `TasksManager`
  - `MealPlanManager`
  - `PomodoroPresetManager`
- `RPI Central-reference/RPI Central/FlexDollars.swift`
  - flex balance state is still local-only

Recommended iPhone plan:

1. Keep local saves exactly as they are.
2. Add a sync service that builds one combined app-state payload from those local stores.
3. Use the existing Firebase session in `SocialManager.swift` to read and write `users/{uid}.webAppState`.
4. Before pull, push, or restore, save a backup document in `users/{uid}/appBackups/{backupID}`.
5. Add manual buttons in the iPhone settings screen for pull, push, backup, and restore so behavior matches the web app.

Recommended restore order on iPhone:

1. Save a backup of current local state.
2. Pull the selected cloud snapshot or backup.
3. Write the imported values back into the existing local stores.
4. Refresh the relevant view models.

Portable backup file shape:

```json
{
  "schemaVersion": 1,
  "exportedAt": "ISO-8601 date",
  "source": "web-portable-export",
  "label": "Web backup",
  "appStateUpdatedAt": "ISO-8601 date",
  "appState": {}
}
```

Firebase rules:

You also need the `appBackups` rule added under `users/{userID}` and then deployed to Firebase:

```txt
match /appBackups/{backupID} {
  allow read, create, update, delete: if isSelf(userID);
}
```
