//
//  WatchSync.swift
//  RPI Central
//
//  Sends the same snapshot the widgets use to the Apple Watch app. Only the
//  latest snapshot matters, so it goes out as the application context.
//

import Foundation
import WatchConnectivity

final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()
    static let snapshotContextKey = "widgetSnapshot"

    private var pendingSnapshot: Data?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Call with the encoded WidgetSnapshot whenever it changes.
    func send(snapshot data: Data) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            pendingSnapshot = data
            return
        }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext([Self.snapshotContextKey: data])
        } catch {
            #if DEBUG
            print("⌚️ Watch sync failed:", error.localizedDescription)
            #endif
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated, let pendingSnapshot else { return }
        self.pendingSnapshot = nil
        send(snapshot: pendingSnapshot)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Switching watches: reactivate for the new one.
        session.activate()
    }
}
