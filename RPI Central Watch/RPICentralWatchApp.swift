//
//  RPICentralWatchApp.swift
//  RPI Central Watch
//

import SwiftUI

@main
struct RPICentralWatchApp: App {
    @StateObject private var store = WatchScheduleStore.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
        }
    }
}
