//
//  AppBackgroundRefresh.swift
//  RPI Central
//
//  Periodic background refresh. iOS decides when it runs (typically a few
//  times a day for apps people use); each run republishes the shared
//  schedule so friends keep an up-to-date copy even if this phone rarely
//  opens the app.
//

import BackgroundTasks
import Foundation

enum AppBackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in the Info.plist.
    static let identifier = "phonix.RPI-Central.refresh"

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            // Expected in the simulator, which does not run app refresh.
            print("ℹ️ Background refresh not scheduled:", error.localizedDescription)
            #endif
        }
    }

    @MainActor
    static func run(calendarViewModel: CalendarViewModel, socialManager: SocialManager) async {
        scheduleNext()
        socialManager.attachScheduleSource(calendarViewModel)
        await socialManager.performBackgroundRefresh()
        await LocationSharingManager.shared.handleBackgroundRefresh()
    }
}
