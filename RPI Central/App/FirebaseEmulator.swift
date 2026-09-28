//
//  FirebaseEmulator.swift
//  RPI Central
//
//  Debug builds can run against the local Firebase emulators instead of the
//  production project. See firebase/emulator/README.md.
//

#if DEBUG && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
import Foundation

enum FirebaseEmulator {
    /// Call right after `FirebaseApp.configure()`, before anything touches
    /// Auth or Firestore. Does nothing unless the app was launched with
    /// `RPI_FIREBASE_EMULATOR_HOST` set.
    static func configureIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let host = environment["RPI_FIREBASE_EMULATOR_HOST"], !host.isEmpty else { return }

        Auth.auth().useEmulator(withHost: host, port: 9099)
        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings

        // RPI_EMULATOR_SIGN_OUT=1 clears a leftover emulator session.
        if environment["RPI_EMULATOR_SIGN_OUT"] == "1" {
            try? Auth.auth().signOut()
        }

        // Optionally sign in as one of the seeded test users.
        if let email = environment["RPI_EMULATOR_EMAIL"],
           let password = environment["RPI_EMULATOR_PASSWORD"] {
            Auth.auth().signIn(withEmail: email, password: password) { _, error in
                if let error {
                    print("Emulator sign-in failed:", error.localizedDescription)
                }
            }
        }
    }
}
#endif
