# Chat Push Notifications Manual

This is a plain-language reference for the chat notification setup used by the iPhone app and web app.

It is intentionally written without secrets, private keys, or full credential values.

## What this covers

This setup is for **group chat** and **class group chat** notifications that should arrive even when the iPhone app is in the background.

This does **not** describe every notification in the app. It is mainly the external push path for chat.

## High-level flow

1. A user sends a message in a normal group or class group.
2. The app or web client writes the message to Firestore.
3. The sender client also calls the external push relay.
4. The push relay verifies the request and checks who should receive the alert.
5. The push relay sends the message through Firebase Cloud Messaging.
6. APNs delivers the notification to iPhones.

## Main pieces

### iPhone app

Important files:

- [`/Users/phonixdrive/Documents/XCode projects/RPI Central/RPI Central/SocialManager.swift`](/Users/phonixdrive/Documents/XCode%20projects/RPI%20Central/RPI%20Central/SocialManager.swift)
- [`/Users/phonixdrive/Documents/XCode projects/RPI Central/RPI Central/NotificationManager.swift`](/Users/phonixdrive/Documents/XCode%20projects/RPI%20Central/RPI%20Central/NotificationManager.swift)
- [`/Users/phonixdrive/Documents/XCode projects/RPI Central/RPI Central/FirebaseAppDelegate.swift`](/Users/phonixdrive/Documents/XCode%20projects/RPI%20Central/RPI%20Central/FirebaseAppDelegate.swift)
- [`/Users/phonixdrive/Documents/XCode projects/RPI Central/RPI Central/SettingsView.swift`](/Users/phonixdrive/Documents/XCode%20projects/RPI%20Central/RPI%20Central/SettingsView.swift)

What the phone app does:

- stores device push tokens in Firebase
- lets the user enable or disable chat alerts
- suppresses the banner if the exact chat thread is already open in the foreground
- sends group chat notifications through the external relay instead of relying only on in-app listeners

The phone settings screen includes a relay URL field, but the app now has a built-in default:

- `https://rpi-central-web.onrender.com`

That means a fresh install should already know where to send chat push requests.

### Push relay

The relay is a small Node service hosted outside the iPhone app.

Current hosted URL:

- `https://rpi-central-web.onrender.com`

Important routes:

- `GET /health`
- `POST /api/push/group-message`

Important note:

- opening the base URL `/` can show `Cannot GET /`
- that is normal
- use `/health` if you want a quick check that the relay is alive

### Web app

Important files in the web repo:

- [`/Users/phonixdrive/Documents/Projects/RPI Central Web/push-relay/server.mjs`](/Users/phonixdrive/Documents/Projects/RPI%20Central%20Web/push-relay/server.mjs)
- [`/Users/phonixdrive/Documents/Projects/RPI Central Web/src/lib/pushRelay.ts`](/Users/phonixdrive/Documents/Projects/RPI%20Central%20Web/src/lib/pushRelay.ts)
- [`/Users/phonixdrive/Documents/Projects/RPI Central Web/src/context/SocialContext.tsx`](/Users/phonixdrive/Documents/Projects/RPI%20Central%20Web/src/context/SocialContext.tsx)

The web app can also send group chat pushes through the same relay.

## Things that must stay configured

### Apple side

The iOS app needs:

- Push Notifications capability enabled
- Background Modes with Remote notifications enabled
- APNs auth key uploaded in Firebase Cloud Messaging

### Firebase side

The Firebase project needs:

- Firestore
- Firebase Authentication
- Firebase Cloud Messaging
- device tokens stored for signed-in users

### Relay hosting side

The relay host needs:

- the Firebase project ID
- a Firebase service account configured as an environment variable
- allowed origins for the web app

Do not store service account files in the repo.

## Current behavior

- normal groups and class groups can send remote chat notifications
- the campus-wide `All RPI Students` group intentionally does **not** send push notifications
- if the exact chat is already open in the foreground, the app suppresses the banner
- if the relay is unavailable, the app still has a fallback path so chat itself does not break

## Why this exists

We originally tried app-only chat notifications, but they only appeared reliably after reopening the app because there was no trusted external sender.

The relay fixes that by providing a proper server-side push sender without using Firebase Cloud Functions.

## Settings users may see

The phone app now uses the hosted relay URL internally by default.

Normally:

- users do not need to configure anything
- the relay URL is intentionally not exposed in normal settings

## If notifications stop working

Check these in order:

1. Confirm the relay health endpoint works:
   - `https://rpi-central-web.onrender.com/health`
2. Confirm the iPhone has notifications allowed for the app.
3. Confirm the user is signed in and the device has written a push token to Firebase.
4. Confirm the app’s chat alert toggle is enabled.
5. Confirm the APNs setup is still valid in Firebase.
6. Confirm the relay host still has valid Firebase service account credentials.

## Security note

If any service account key is ever pasted into chat, committed, or exposed accidentally, rotate it immediately and update the relay host with a new one.

## Good test case

Use two accounts:

1. Put account A’s phone in the background.
2. Send a message from account B in a normal group or class group.
3. Account A should receive the push without reopening the app.

If that works, the end-to-end path is healthy.
