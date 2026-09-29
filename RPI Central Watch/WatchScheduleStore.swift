//
//  WatchScheduleStore.swift
//  RPI Central Watch
//
//  Receives the schedule snapshot from the iPhone and keeps it in the watch's
//  app group so complications can read it too.
//

import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchScheduleStore: NSObject, ObservableObject {
    static let shared = WatchScheduleStore()
    private static let contextKey = "widgetSnapshot"

    @Published private(set) var snapshot: WidgetSnapshot?

    override init() {
        super.init()
        snapshot = Self.loadStored()
        #if DEBUG
        if ProcessInfo.processInfo.environment["RPI_WATCH_DEMO"] == "1" {
            store(WidgetSnapshot.sample(now: Date()))
        }
        #endif
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func apply(context: [String: Any]) {
        guard let data = context[Self.contextKey] as? Data,
              let decoded = Self.decode(data) else { return }
        store(decoded)
    }

    private func store(_ snapshot: WidgetSnapshot) {
        self.snapshot = snapshot
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            UserDefaults(suiteName: RPICentralWidgetShared.appGroup)?.set(data, forKey: RPICentralWidgetShared.snapshotKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    nonisolated static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    nonisolated static func loadStored() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: RPICentralWidgetShared.appGroup)?.data(forKey: RPICentralWidgetShared.snapshotKey) else {
            return nil
        }
        return decode(data)
    }
}

extension WatchScheduleStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        Task { @MainActor in self.apply(context: context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(context: applicationContext) }
    }
}
