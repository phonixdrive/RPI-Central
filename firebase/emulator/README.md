# Local Firebase emulators

Run the app's social features against local Auth and Firestore emulators with
sample data, without touching the production project.

1. Start the emulators from the repo root:

   ```sh
   firebase emulators:start --only auth,firestore --project rpi-central
   ```

2. In another terminal, seed sample people, chats, groups, shared schedules,
   locations, and activity posts. This wipes the emulators first. It borrows
   `firebase-admin` from `firebase/functions`, so run `npm ci` there first and
   use Node 22:

   ```sh
   node firebase/emulator/seed.js
   ```

3. Run a Debug build with these environment variables (Xcode: Product → Scheme →
   Edit Scheme → Run → Arguments):

   | Variable | Value |
   | --- | --- |
   | `RPI_FIREBASE_EMULATOR_HOST` | `127.0.0.1` |
   | `RPI_EMULATOR_EMAIL` | `alex@example.com` (optional auto sign-in) |
   | `RPI_EMULATOR_PASSWORD` | the `TEST_PASSWORD` in `seed.js` |

The emulators use the rules in `firebase/firestore.rules`, so the app hits the
same permission checks it would in production. Release builds ignore these
variables.

An emulator sign-in stays in the simulator's keychain. Before switching back to
the real project, launch once with `RPI_FIREBASE_EMULATOR_HOST=127.0.0.1` and
`RPI_EMULATOR_SIGN_OUT=1` (or sign out from the Social profile).
