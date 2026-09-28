//
//  LocationSharingModels.swift
//  RPI Central
//

import CoreLocation
import Foundation

enum LocationShareAudience: String, Codable, CaseIterable, Identifiable {
    case allFriends
    case selectedFriends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allFriends: return "All friends"
        case .selectedFriends: return "Only friends I choose"
        }
    }
}

enum LocationSharePrecision: String, Codable, CaseIterable, Identifiable {
    /// The exact fix, so friends can see which building you are in.
    case precise
    /// Snapped to the nearest campus building, or rounded to ~100 m.
    case building

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precise: return "Precise"
        case .building: return "Building only"
        }
    }

    var detail: String {
        switch self {
        case .precise:
            return "Friends see your exact spot on the map."
        case .building:
            return "Friends see the building you're in (or a rough area off campus), never your exact spot."
        }
    }
}

enum LocationShareDuration: String, CaseIterable, Identifiable {
    case oneHour
    case untilEndOfDay
    case indefinitely

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: return "For 1 hour"
        case .untilEndOfDay: return "Until end of day"
        case .indefinitely: return "Until I turn it off"
        }
    }

    func expiration(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .untilEndOfDay:
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return startOfTomorrow.addingTimeInterval(-1)
        case .indefinitely:
            return nil
        }
    }
}

struct LocationSharingSettings: Codable, Equatable {
    var isEnabled = false
    var audience: LocationShareAudience = .allFriends
    var selectedFriendIDs: [String] = []
    var precision: LocationSharePrecision = .precise
    /// Keep updating after the app closes (requires "Always" permission).
    var shareInBackground = false
    /// Sharing turns itself off at this moment. `nil` means indefinitely.
    var expiresAt: Date?

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Who may read the location document, given the current friend list.
    func viewerIDs(friendIDs: [String]) -> [String] {
        let friends = Set(friendIDs)
        switch audience {
        case .allFriends:
            return friends.sorted()
        case .selectedFriends:
            return friends.intersection(selectedFriendIDs).sorted()
        }
    }
}

/// A friend's published location, as read from `locationShares/{uid}`.
struct SharedFriendLocation: Identifiable, Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let precision: LocationSharePrecision
    let placeID: String?
    let placeName: String?
    let placeKind: CampusPlace.Kind?
    let isOnCampus: Bool
    let updatedAt: Date
    let expiresAt: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Older than this, the pin is shown faded with its age.
    static let freshInterval: TimeInterval = 20 * 60
    /// Older than this, the location is not shown at all.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    func isVisible(at now: Date = Date()) -> Bool {
        if let expiresAt, expiresAt <= now { return false }
        return now.timeIntervalSince(updatedAt) <= Self.maximumAge
    }

    func isFresh(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) <= Self.freshInterval
    }

    init(
        id: String,
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        precision: LocationSharePrecision,
        placeID: String?,
        placeName: String?,
        placeKind: CampusPlace.Kind?,
        isOnCampus: Bool,
        updatedAt: Date,
        expiresAt: Date?
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.precision = precision
        self.placeID = placeID
        self.placeName = placeName
        self.placeKind = placeKind
        self.isOnCampus = isOnCampus
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    /// Parses a Firestore document; nil if required fields are missing.
    init?(id: String, data: [String: Any]) {
        guard let latitude = (data["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (data["longitude"] as? NSNumber)?.doubleValue,
              let updatedText = data["updatedAt"] as? String,
              let updatedAt = SharedScheduleDates.parse(updatedText) else {
            return nil
        }

        let placeID = (data["placeID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let placeName = (data["placeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = (data["expiresAt"] as? String).flatMap(SharedScheduleDates.parse)

        self.init(
            id: id,
            latitude: latitude,
            longitude: longitude,
            accuracy: (data["accuracy"] as? NSNumber)?.doubleValue ?? 50,
            precision: LocationSharePrecision(rawValue: data["precision"] as? String ?? "") ?? .precise,
            placeID: placeID,
            placeName: placeName,
            placeKind: CampusPlace.Kind(rawValue: data["placeKind"] as? String ?? ""),
            isOnCampus: data["isOnCampus"] as? Bool ?? false,
            updatedAt: updatedAt,
            expiresAt: expiresAt
        )
    }
}

enum RelativeTimeText {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// "Just now", "4 min. ago", "2 hr. ago".
    static func since(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 {
            return "Just now"
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "now", "4m", "2h", "3d" for tight spaces.
    static func compact(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}
