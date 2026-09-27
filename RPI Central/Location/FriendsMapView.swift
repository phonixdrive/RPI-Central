//
//  FriendsMapView.swift
//  RPI Central
//

import CoreLocation
import MapKit
import SwiftUI

// MARK: - Data

/// Presences and map pins for every friend, recomputed on each render. Pins
/// sit at each friend's real position; `FriendMapLayout` spreads them out for
/// the current zoom.
@MainActor
struct FriendsMapSnapshot {
    let presences: [FriendPresence]
    let pins: [FriendMapPinModel]
    let hiddenFriendCount: Int

    init(
        socialManager: SocialManager,
        locationManager: LocationSharingManager,
        now: Date
    ) {
        let friends = socialManager.overview?.friends ?? []
        var presences: [FriendPresence] = []
        for friend in friends {
            let schedule = friend.canViewSchedule
                ? socialManager.anyCachedFriendSchedule(friendID: friend.id)?.schedule
                : nil
            if let presence = FriendPresenceResolver.resolve(
                friend: friend,
                location: locationManager.friendLocations[friend.id],
                schedule: schedule,
                now: now
            ) {
                presences.append(presence)
            }
        }

        self.init(presences: presences, hiddenFriendCount: friends.count - presences.count)
    }

    init(presences: [FriendPresence], hiddenFriendCount: Int) {
        self.presences = presences.sorted(by: Self.displayOrder)
        pins = self.presences.compactMap { presence in
            presence.coordinate.map { FriendMapPinModel(presence: presence, coordinate: $0) }
        }
        self.hiddenFriendCount = hiddenFriendCount
    }

    private static func displayOrder(_ lhs: FriendPresence, _ rhs: FriendPresence) -> Bool {
        func rank(_ presence: FriendPresence) -> Int {
            switch presence.freshness {
            case .live: return 0
            case .scheduled: return presence.isOnMap ? 1 : 3
            case .stale: return 2
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        if let left = lhs.updatedAt, let right = rhs.updatedAt, left != right { return left > right }
        return lhs.friend.displayName.localizedCaseInsensitiveCompare(rhs.friend.displayName) == .orderedAscending
    }
}

struct FriendMapPinModel: Identifiable {
    let presence: FriendPresence
    let coordinate: CLLocationCoordinate2D
    var id: String { presence.id }
}

/// Friends too close together to tell apart at the current zoom.
struct FriendMapGroup: Identifiable {
    let members: [FriendMapPinModel]
    let coordinate: CLLocationCoordinate2D

    var id: String { "group:" + members.map(\.id).joined(separator: ",") }

    /// "Maya, Ava +3"
    var title: String {
        let names = members.prefix(2).map { FriendAvatarStyle.firstName(for: $0.presence.friend.displayName) }
        let remaining = members.count - names.count
        return names.joined(separator: ", ") + (remaining > 0 ? " +\(remaining)" : "")
    }

    /// Distance from the center to the farthest member, in meters.
    var radius: Double {
        members.map { FriendMapLayout.meters(from: coordinate, to: $0.coordinate) }.max() ?? 0
    }
}

/// Places friend pins for the current zoom. Avatars that would overlap spread
/// out around their shared spot, and bigger crowds collapse into one bubble.
enum FriendMapLayout {
    enum Item: Identifiable {
        case friend(FriendMapPinModel, showsName: Bool)
        case group(FriendMapGroup)

        var id: String {
            switch self {
            case .friend(let pin, _): return pin.id
            case .group(let group): return group.id
            }
        }
    }

    /// Pins closer than this many points are treated as overlapping.
    static let minimumSpacing: Double = 56
    /// Distance between neighbors when a small group spreads out, in points.
    static let spreadSpacing: Double = 48
    /// Groups larger than this show as a single bubble.
    static let maximumSpreadCount = 5

    static func items(
        for pins: [FriendMapPinModel],
        metersPerPoint: Double,
        selectedFriendID: String?
    ) -> [Item] {
        let threshold = minimumSpacing * metersPerPoint
        var clusters: [[FriendMapPinModel]] = []
        for pin in pins {
            if let index = clusters.firstIndex(where: { meters(from: $0[0].coordinate, to: pin.coordinate) < threshold }) {
                clusters[index].append(pin)
            } else {
                clusters.append([pin])
            }
        }

        var items: [Item] = []
        for members in clusters {
            if members.count == 1 {
                items.append(.friend(members[0], showsName: true))
                continue
            }

            let center = centroid(of: members.map(\.coordinate))
            if members.count <= maximumSpreadCount {
                let count = Double(members.count)
                let radius = spreadSpacing / (2 * sin(.pi / count)) * metersPerPoint
                for (index, member) in members.enumerated() {
                    // Two friends sit side by side; more form a ring.
                    let angle = Double.pi - 2 * Double.pi * Double(index) / count
                    let coordinate = offset(center, eastMeters: radius * cos(angle), northMeters: radius * sin(angle))
                    items.append(.friend(
                        FriendMapPinModel(presence: member.presence, coordinate: coordinate),
                        showsName: member.id == selectedFriendID
                    ))
                }
            } else {
                // The selected friend stays visible on top of the crowd.
                let others = members.filter { $0.id != selectedFriendID }
                items.append(.group(FriendMapGroup(members: others, coordinate: center)))
                if let selected = members.first(where: { $0.id == selectedFriendID }) {
                    items.append(.friend(selected, showsName: true))
                }
            }
        }
        return items
    }

    static func metersPerPoint(in region: MKCoordinateRegion, width: CGFloat) -> Double {
        let longitudeMeters = region.span.longitudeDelta * 111_320 * cos(region.center.latitude * .pi / 180)
        return longitudeMeters / max(Double(width), 1)
    }

    static func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let north = (a.latitude - b.latitude) * 110_574
        let east = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (north * north + east * east).squareRoot()
    }

    private static func centroid(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let count = Double(max(coordinates.count, 1))
        return CLLocationCoordinate2D(
            latitude: coordinates.map(\.latitude).reduce(0, +) / count,
            longitude: coordinates.map(\.longitude).reduce(0, +) / count
        )
    }

    private static func offset(
        _ coordinate: CLLocationCoordinate2D,
        eastMeters: Double,
        northMeters: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: coordinate.latitude + northMeters / 110_574,
            longitude: coordinate.longitude + eastMeters / (111_320 * cos(coordinate.latitude * .pi / 180))
        )
    }
}

