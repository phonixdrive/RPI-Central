import EventKit
import Foundation

struct ExternalCalendarOption: Identifiable, Equatable {
    let id: String
    let title: String
    let accountName: String
    let accountType: String
}

struct ImportedSystemCalendarEvent: Equatable {
    let sourceID: String
    let title: String
    let location: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

@MainActor
final class ExternalCalendarSyncManager: ObservableObject {
    private let selectedCalendarIDsKey = "external_calendars.selected_ids.v1"
    private let autoSyncEnabledKey = "external_calendars.auto_sync_enabled.v1"
    private let lastSyncAtKey = "external_calendars.last_sync_at.v1"
    private let minimumAutoSyncInterval: TimeInterval = 15 * 60
    private let eventStore = EKEventStore()

    @Published private(set) var availableCalendars: [ExternalCalendarOption] = []
    @Published private(set) var selectedCalendarIDs: Set<String>
    @Published private(set) var isSyncing = false
    @Published private(set) var statusText: String?
    @Published private(set) var lastSyncAt: Date?

    @Published var autoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSyncEnabled, forKey: autoSyncEnabledKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        selectedCalendarIDs = Set(defaults.stringArray(forKey: selectedCalendarIDsKey) ?? [])
        lastSyncAt = defaults.object(forKey: lastSyncAtKey) as? Date
        if defaults.object(forKey: autoSyncEnabledKey) == nil {
            autoSyncEnabled = true
        } else {
            autoSyncEnabled = defaults.bool(forKey: autoSyncEnabledKey)
        }

        reloadAvailableCalendars()
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var hasFullAccess: Bool {
        authorizationStatus == .fullAccess
    }

    var needsPermission: Bool {
        !hasFullAccess
    }

    func requestAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            statusText = granted ? "Calendar access granted. Choose the calendars to mirror." : "Calendar access was not granted."
            reloadAvailableCalendars()
        } catch {
            statusText = error.localizedDescription
        }
    }

    func reloadAvailableCalendars() {
        guard hasFullAccess else {
            availableCalendars = []
            return
        }

        availableCalendars = eventStore.calendars(for: .event)
            .map { calendar in
                ExternalCalendarOption(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    accountName: calendar.source.title,
                    accountType: Self.accountTypeName(calendar.source.sourceType)
                )
            }
            .sorted { lhs, rhs in
                if lhs.accountName != rhs.accountName {
                    return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func isSelected(_ calendarID: String) -> Bool {
        selectedCalendarIDs.contains(calendarID)
    }

    func setSelected(_ selected: Bool, calendarID: String) {
        if selected {
            selectedCalendarIDs.insert(calendarID)
        } else {
            selectedCalendarIDs.remove(calendarID)
        }
        UserDefaults.standard.set(Array(selectedCalendarIDs).sorted(), forKey: selectedCalendarIDsKey)
    }

    func autoSyncIfNeeded(into calendarViewModel: CalendarViewModel) async {
        guard autoSyncEnabled, hasFullAccess, !selectedCalendarIDs.isEmpty else { return }
        if let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < minimumAutoSyncInterval {
            return
        }
        await sync(into: calendarViewModel, force: false)
    }

    func sync(into calendarViewModel: CalendarViewModel, force: Bool = true) async {
        guard !isSyncing else { return }
        guard hasFullAccess else {
            statusText = "Allow full calendar access before syncing."
            return
        }
        guard !selectedCalendarIDs.isEmpty else {
            calendarViewModel.replaceSystemCalendarEvents([])
            statusText = "Choose at least one calendar to mirror."
            return
        }

        if !force, let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < minimumAutoSyncInterval {
            return
        }

        isSyncing = true
        statusText = "Syncing selected calendars…"

        let selectedIDs = selectedCalendarIDs
        let store = eventStore
        let now = Date()
        let calendar = Calendar.current
        let rangeStart = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        let rangeEnd = calendar.date(byAdding: .day, value: 550, to: now) ?? now

        let importedEvents = await Task.detached(priority: .utility) {
            let selectedCalendars = store.calendars(for: .event).filter {
                selectedIDs.contains($0.calendarIdentifier)
            }
            guard !selectedCalendars.isEmpty else { return [ImportedSystemCalendarEvent]() }

            let predicate = store.predicateForEvents(
                withStart: rangeStart,
                end: rangeEnd,
                calendars: selectedCalendars
            )

            return store.events(matching: predicate).compactMap { event in
                guard let startDate = event.startDate,
                      let rawEndDate = event.endDate else {
                    return nil
                }

                let externalID = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
                let occurrence = Int(startDate.timeIntervalSince1970)
                let sourceID = "\(event.calendar.calendarIdentifier)|\(externalID)|\(occurrence)"
                let endDate: Date
                if event.isAllDay {
                    endDate = rawEndDate.addingTimeInterval(-1)
                } else {
                    endDate = max(rawEndDate, startDate.addingTimeInterval(60))
                }

                return ImportedSystemCalendarEvent(
                    sourceID: sourceID,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Calendar Event",
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: event.isAllDay
                )
            }
        }.value

        calendarViewModel.replaceSystemCalendarEvents(importedEvents)
        let completedAt = Date()
        lastSyncAt = completedAt
        UserDefaults.standard.set(completedAt, forKey: lastSyncAtKey)
        statusText = "Synced \(importedEvents.count) event\(importedEvents.count == 1 ? "" : "s")."
        isSyncing = false
    }

    private static func accountTypeName(_ sourceType: EKSourceType) -> String {
        switch sourceType {
        case .exchange: return "Outlook / Exchange"
        case .calDAV: return "Google / CalDAV"
        case .mobileMe: return "iCloud"
        case .local: return "On My iPhone"
        case .subscribed: return "Subscribed"
        case .birthdays: return "Birthdays"
        @unknown default: return "Calendar Account"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
