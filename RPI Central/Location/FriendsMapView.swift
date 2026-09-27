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

enum FriendAvatarStyle {
    /// A stable color per friend so the same person looks the same everywhere.
    static func color(for id: String) -> Color {
        let hash = SocialHashing.fnv1a64Hex(Data(id.utf8))
        let value = UInt64(hash.prefix(8), radix: 16) ?? 0
        return Color(hue: Double(value % 360) / 360, saturation: 0.62, brightness: 0.82)
    }

    static func initials(for name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    static func firstName(for name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }
}

enum DistanceText {
    private static let formatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()

    static func between(_ origin: CLLocation?, _ coordinate: CLLocationCoordinate2D?) -> String? {
        guard let origin, let coordinate else { return nil }
        let meters = origin.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard meters.isFinite else { return nil }
        if meters < 40 { return "Nearby" }
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }
}

// MARK: - Map

struct FriendsMapCanvas: View {
    let pins: [FriendMapPinModel]
    let highlightedBuilding: CampusBuilding?
    let accent: Color
    let showsUserLocation: Bool
    @Binding var position: MapCameraPosition
    @Binding var selectedFriendID: String?
    @State private var metersPerPoint: Double?
    @State private var listedGroup: FriendMapGroup?

    var body: some View {
        GeometryReader { proxy in
            let items = FriendMapLayout.items(
                for: pins,
                metersPerPoint: metersPerPoint ?? FriendMapLayout.metersPerPoint(
                    in: position.region ?? CampusDirectory.campusRegion,
                    width: proxy.size.width
                ),
                selectedFriendID: selectedFriendID
            )

            Map(position: $position) {
                if showsUserLocation {
                    UserAnnotation()
                }

                if let highlightedBuilding {
                    ForEach(Array(highlightedBuilding.polygons.enumerated()), id: \.offset) { _, ring in
                        MapPolygon(coordinates: ring)
                            .foregroundStyle(accent.opacity(0.18))
                            .stroke(accent, lineWidth: 2)
                    }
                }

                ForEach(items) { item in
                    switch item {
                    case .friend(let pin, let showsName):
                        Annotation(pin.presence.friend.displayName, coordinate: pin.coordinate, anchor: .bottom) {
                            FriendMapPin(presence: pin.presence, isSelected: selectedFriendID == pin.id, showsName: showsName)
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        selectedFriendID = selectedFriendID == pin.id ? nil : pin.id
                                    }
                                }
                        }
                        .annotationTitles(.hidden)
                    case .group(let group):
                        Annotation(group.title, coordinate: group.coordinate, anchor: .bottom) {
                            FriendGroupPin(group: group)
                                .onTapGesture { open(group) }
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let value = FriendMapLayout.metersPerPoint(in: context.region, width: proxy.size.width)
                withAnimation(.snappy(duration: 0.3)) {
                    metersPerPoint = value
                }
            }
        }
        .confirmationDialog(
            listedGroup.map { "\($0.members.count) friends here" } ?? "",
            isPresented: Binding(
                get: { listedGroup != nil },
                set: { if !$0 { listedGroup = nil } }
            ),
            titleVisibility: .visible,
            presenting: listedGroup
        ) { group in
            ForEach(group.members) { member in
                Button(member.presence.friend.displayName) {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedFriendID = member.id
                    }
                }
            }
        }
    }

    private func open(_ group: FriendMapGroup) {
        // Zooming can't separate a crowd inside one building; list it instead.
        guard group.radius > 40 else {
            listedGroup = group
            return
        }
        let span = max(group.radius * 3, 150)
        withAnimation(.snappy(duration: 0.4)) {
            position = .region(MKCoordinateRegion(
                center: group.coordinate,
                latitudinalMeters: span,
                longitudinalMeters: span
            ))
        }
    }
}

struct FriendMapPin: View {
    let presence: FriendPresence
    let isSelected: Bool
    var showsName = true

    var body: some View {
        let color = FriendAvatarStyle.color(for: presence.friend.id)
        let size: CGFloat = isSelected ? 46 : 38

        VStack(spacing: 3) {
            ZStack {
                Circle().fill(color.gradient)
                Text(FriendAvatarStyle.initials(for: presence.friend.displayName))
                    .font(.system(size: isSelected ? 16 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(.white, lineWidth: 2.5)
            }
            .overlay {
                if presence.freshness == .scheduled {
                    // Dashed ring: position comes from their schedule, not GPS.
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                        .foregroundStyle(color)
                        .padding(-5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if presence.freshness == .live {
                    Circle()
                        .fill(.green)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .opacity(presence.freshness == .stale ? 0.6 : 1)

            if showsName {
                Text(FriendAvatarStyle.firstName(for: presence.friend.displayName))
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .animation(.snappy(duration: 0.25), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presence.friend.displayName), \(presence.headline)")
        .accessibilityAddTraits(.isButton)
    }
}

struct FriendGroupPin: View {
    let group: FriendMapGroup

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: -10) {
                ForEach(group.members.prefix(3)) { member in
                    ZStack {
                        Circle().fill(FriendAvatarStyle.color(for: member.id).gradient)
                        Text(FriendAvatarStyle.initials(for: member.presence.friend.displayName))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                }

                if group.members.count > 3 {
                    Text("+\(group.members.count - 3)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .padding(.leading, 16)
                        .padding(.trailing, 6)
                }
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

            Text(group.title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.members.count) friends: " + group.members.map(\.presence.friend.displayName).joined(separator: ", "))
        .accessibilityHint("Shows who is here")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Rows

struct FriendPresenceRow: View {
    let presence: FriendPresence
    let distanceText: String?
    let isSelected: Bool
    let accent: Color
    let now: Date
    let onFocus: () -> Void
    let onMessage: () -> Void
    let onViewSchedule: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(FriendAvatarStyle.color(for: presence.friend.id).gradient)
                Text(FriendAvatarStyle.initials(for: presence.friend.displayName))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .overlay(alignment: .bottomTrailing) {
                if presence.freshness == .live {
                    Circle()
                        .fill(.green)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(.secondarySystemBackground), lineWidth: 2))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(presence.friend.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(freshnessText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(presence.freshness == .live ? Color.green : Color.secondary)
                }

                Text(presence.headline)
                    .font(.subheadline)
                    .lineLimit(2)

                if let detail = presence.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let distanceText, presence.isOnMap {
                    Label(distanceText, systemImage: "figure.walk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Menu {
                if presence.isOnMap {
                    Button {
                        onFocus()
                    } label: {
                        Label("Show on map", systemImage: "scope")
                    }
                    Button {
                        openDirections()
                    } label: {
                        Label("Walking directions", systemImage: "figure.walk")
                    }
                }
                Button {
                    onMessage()
                } label: {
                    Label("Message", systemImage: "message")
                }
                if let onViewSchedule {
                    Button {
                        onViewSchedule()
                    } label: {
                        Label("View schedule", systemImage: "calendar")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(presence.friend.displayName)")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? accent.opacity(0.14) : Color(.secondarySystemBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if presence.isOnMap { onFocus() }
        }
    }

    private var freshnessText: String {
        switch presence.freshness {
        case .live:
            return presence.updatedAt.map { RelativeTimeText.since($0, now: now) } ?? "Live"
        case .stale:
            return presence.updatedAt.map { RelativeTimeText.since($0, now: now) } ?? "Earlier"
        case .scheduled:
            return "Schedule"
        }
    }

    private func openDirections() {
        guard let coordinate = presence.coordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = presence.building?.name ?? presence.friend.displayName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

// MARK: - Social tab section

struct FriendsMapSection: View {
    let onMessage: (SocialFriend) -> Void
    let onViewSchedule: (SocialFriend) -> Void

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @EnvironmentObject private var locationManager: LocationSharingManager

    @State private var cameraPosition: MapCameraPosition = .region(CampusDirectory.campusRegion)
    @State private var selectedFriendID: String?
    @State private var showSharingSettings = false
    @State private var showFullScreenMap = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snapshot = FriendsMapSnapshot(
                socialManager: socialManager,
                locationManager: locationManager,
                now: context.date
            )

            VStack(spacing: 16) {
                mapCard(snapshot)
                LocationSharingStatusCard(showSettings: $showSharingSettings, now: context.date)
                friendsCard(snapshot, now: context.date)
            }
        }
        .onAppear {
            locationManager.beginObservingFriends()
            locationManager.beginShowingOwnLocation()
        }
        .onDisappear {
            locationManager.endObservingFriends()
            locationManager.endShowingOwnLocation()
        }
        .task(id: socialManager.overview?.friends.map(\.id).joined(separator: "|") ?? "") {
            await socialManager.preloadFriendSchedulesForActivity()
        }
        .sheet(isPresented: $showSharingSettings) {
            LocationSharingSettingsView()
                .environmentObject(socialManager)
                .environmentObject(locationManager)
                .environmentObject(calendarViewModel)
        }
        .fullScreenCover(isPresented: $showFullScreenMap) {
            FriendsMapFullScreen(
                onMessage: { friend in
                    showFullScreenMap = false
                    onMessage(friend)
                },
                onViewSchedule: { friend in
                    showFullScreenMap = false
                    onViewSchedule(friend)
                }
            )
            .environmentObject(socialManager)
            .environmentObject(locationManager)
            .environmentObject(calendarViewModel)
        }
    }

    private func mapCard(_ snapshot: FriendsMapSnapshot) -> some View {
        let selected = snapshot.presences.first { $0.id == selectedFriendID }
        let liveCount = snapshot.presences.filter { $0.freshness == .live }.count

        return SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Friends Map", systemImage: "map.fill")
                        .font(.headline)
                    Spacer()
                    Text(liveCount == 1 ? "1 friend live" : "\(liveCount) friends live")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.green.opacity(liveCount > 0 ? 0.16 : 0.06)))
                        .foregroundStyle(liveCount > 0 ? Color.green : Color.secondary)
                }

                FriendsMapCanvas(
                    pins: snapshot.pins,
                    highlightedBuilding: selected?.building,
                    accent: calendarViewModel.themeColor,
                    showsUserLocation: locationManager.isAuthorized,
                    position: $cameraPosition,
                    selectedFriendID: $selectedFriendID
                )
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        mapButton("arrow.up.left.and.arrow.down.right", label: "Expand map") {
                            showFullScreenMap = true
                        }
                        mapButton("building.columns", label: "Show all of campus") {
                            withAnimation(.snappy) {
                                selectedFriendID = nil
                                cameraPosition = .region(CampusDirectory.campusRegion)
                            }
                        }
                    }
                    .padding(10)
                }

                if let selected {
                    FriendPresenceRow(
                        presence: selected,
                        distanceText: DistanceText.between(locationManager.lastLocation, selected.coordinate),
                        isSelected: true,
                        accent: calendarViewModel.themeColor,
                        now: Date(),
                        onFocus: { focus(on: selected) },
                        onMessage: { onMessage(selected.friend) },
                        onViewSchedule: selected.friend.canViewSchedule ? { onViewSchedule(selected.friend) } : nil
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Text("Dashed rings show where a friend's class is, from their shared schedule. \(CampusDirectory.shared.attribution)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: selectedFriendID) { _, newValue in
            guard let newValue, let presence = snapshot.presences.first(where: { $0.id == newValue }) else { return }
            focus(on: presence)
        }
    }

    private func friendsCard(_ snapshot: FriendsMapSnapshot, now: Date) -> some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Where friends are", systemImage: "person.2.wave.2.fill")
                    .font(.headline)

                if snapshot.presences.isEmpty {
                    Text(
                        (socialManager.overview?.friends.isEmpty ?? true)
                            ? "Add friends to see who's around campus."
                            : "No friends are sharing right now. Friends who share their location, or whose schedule shows a class, appear here."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(snapshot.presences) { presence in
                            FriendPresenceRow(
                                presence: presence,
                                distanceText: DistanceText.between(locationManager.lastLocation, presence.coordinate),
                                isSelected: presence.id == selectedFriendID,
                                accent: calendarViewModel.themeColor,
                                now: now,
                                onFocus: {
                                    withAnimation(.snappy) { selectedFriendID = presence.id }
                                },
                                onMessage: { onMessage(presence.friend) },
                                onViewSchedule: presence.friend.canViewSchedule ? { onViewSchedule(presence.friend) } : nil
                            )
                        }
                    }
                }

                if snapshot.hiddenFriendCount > 0 {
                    Text(
                        snapshot.hiddenFriendCount == 1
                            ? "1 friend isn't sharing a location or class right now."
                            : "\(snapshot.hiddenFriendCount) friends aren't sharing a location or class right now."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func focus(on presence: FriendPresence) {
        guard let coordinate = presence.coordinate else { return }
        withAnimation(.snappy(duration: 0.4)) {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 320,
                longitudinalMeters: 320
            ))
        }
    }

    private func mapButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Full screen

struct FriendsMapFullScreen: View {
    let onMessage: (SocialFriend) -> Void
    let onViewSchedule: (SocialFriend) -> Void

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @EnvironmentObject private var locationManager: LocationSharingManager
    @Environment(\.dismiss) private var dismiss

    @State private var cameraPosition: MapCameraPosition = .region(CampusDirectory.campusRegion)
    @State private var selectedFriendID: String?
    @State private var showSharingSettings = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snapshot = FriendsMapSnapshot(
                socialManager: socialManager,
                locationManager: locationManager,
                now: context.date
            )
            let selected = snapshot.presences.first { $0.id == selectedFriendID }

            ZStack(alignment: .bottom) {
                FriendsMapCanvas(
                    pins: snapshot.pins,
                    highlightedBuilding: selected?.building,
                    accent: calendarViewModel.themeColor,
                    showsUserLocation: locationManager.isAuthorized,
                    position: $cameraPosition,
                    selectedFriendID: $selectedFriendID
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    friendCarousel(snapshot, now: context.date)
                }
            }
            .onChange(of: selectedFriendID) { _, newValue in
                guard let newValue,
                      let coordinate = snapshot.presences.first(where: { $0.id == newValue })?.coordinate else { return }
                withAnimation(.snappy(duration: 0.4)) {
                    cameraPosition = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 300, longitudinalMeters: 300))
                }
            }
        }
        .onAppear {
            locationManager.beginObservingFriends()
            locationManager.beginShowingOwnLocation()
        }
        .onDisappear {
            locationManager.endObservingFriends()
            locationManager.endShowingOwnLocation()
        }
        .sheet(isPresented: $showSharingSettings) {
            LocationSharingSettingsView()
                .environmentObject(socialManager)
                .environmentObject(locationManager)
                .environmentObject(calendarViewModel)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close map")

            Spacer()

            Button {
                showSharingSettings = true
            } label: {
                Label(
                    locationManager.isSharingActive ? "Sharing" : "Ghost mode",
                    systemImage: locationManager.isSharingActive ? "location.fill" : "location.slash.fill"
                )
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(locationManager.isSharingActive ? calendarViewModel.themeColor : Color.primary)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.snappy) {
                    selectedFriendID = nil
                    cameraPosition = .region(CampusDirectory.campusRegion)
                }
            } label: {
                Image(systemName: "building.columns")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all of campus")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func friendCarousel(_ snapshot: FriendsMapSnapshot, now: Date) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if snapshot.presences.isEmpty {
                    Text("No friends are sharing right now.")
                        .font(.subheadline)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    ForEach(snapshot.presences) { presence in
                        FriendPresenceRow(
                            presence: presence,
                            distanceText: DistanceText.between(locationManager.lastLocation, presence.coordinate),
                            isSelected: presence.id == selectedFriendID,
                            accent: calendarViewModel.themeColor,
                            now: now,
                            onFocus: {
                                withAnimation(.snappy) { selectedFriendID = presence.id }
                            },
                            onMessage: { onMessage(presence.friend) },
                            onViewSchedule: presence.friend.canViewSchedule ? { onViewSchedule(presence.friend) } : nil
                        )
                        .frame(width: 290)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Sharing status

struct LocationSharingStatusCard: View {
    @Binding var showSettings: Bool
    let now: Date

    @EnvironmentObject private var locationManager: LocationSharingManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel

    var body: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: locationManager.isSharingActive ? "location.fill" : "location.slash.fill")
                        .font(.title3)
                        .foregroundStyle(locationManager.isSharingActive ? calendarViewModel.themeColor : Color.secondary)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(locationManager.isSharingActive ? "Sharing your location" : "Ghost mode")
                            .font(.headline)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Toggle(
                        "Share my location",
                        isOn: Binding(
                            get: { locationManager.isSharingActive },
                            set: { newValue in
                                Task { await locationManager.setSharingEnabled(newValue) }
                            }
                        )
                    )
                    .labelsHidden()
                    .disabled(!locationManager.isSignedIn)
                }

                if locationManager.isSharingActive, let place = locationManager.currentPlace {
                    Label(
                        [place.label, locationManager.lastPublishedAt.map { "updated \(RelativeTimeText.since($0, now: now).lowercased())" }]
                            .compactMap { $0 }
                            .joined(separator: " · "),
                        systemImage: "mappin.circle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                if locationManager.isAuthorizationDenied {
                    Button {
                        locationManager.openSystemSettings()
                    } label: {
                        Label("Location access is off. Open Settings", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(.orange)
                }

                if let error = locationManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    showSettings = true
                } label: {
                    Label("Sharing options", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var summary: String {
        guard locationManager.isSignedIn else { return "Sign in to share your location with friends." }
        guard locationManager.isSharingActive else { return "Friends can't see where you are." }

        let settings = locationManager.settings
        let count = locationManager.viewerCount
        let audience = settings.audience == .allFriends
            ? (count == 1 ? "1 friend" : "\(count) friends")
            : (count == 1 ? "1 chosen friend" : "\(count) chosen friends")
        let until: String
        if let expiresAt = settings.expiresAt {
            until = "until \(expiresAt.formatted(date: .omitted, time: .shortened))"
        } else {
            until = "until you turn it off"
        }
        return "Visible to \(audience) · \(settings.precision.title.lowercased()) · \(until)"
    }
}

#if DEBUG
// MARK: - Demo (debug builds only)

/// Sample friends for checking the map without a signed-in account.
struct FriendsMapDemoView: View {
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @State private var position: MapCameraPosition = .region(CampusDirectory.campusRegion)
    @State private var selectedFriendID: String?

    var body: some View {
        let snapshot = FriendsMapSnapshot(presences: Self.samplePresences(now: Date()), hiddenFriendCount: 2)
        let selected = snapshot.presences.first { $0.id == selectedFriendID }

        ScrollView {
            VStack(spacing: 12) {
                FriendsMapCanvas(
                    pins: snapshot.pins,
                    highlightedBuilding: selected?.building,
                    accent: calendarViewModel.themeColor,
                    showsUserLocation: false,
                    position: $position,
                    selectedFriendID: $selectedFriendID
                )
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                ForEach(snapshot.presences) { presence in
                    FriendPresenceRow(
                        presence: presence,
                        distanceText: presence.isOnMap ? "0.2 mi" : nil,
                        isSelected: presence.id == selectedFriendID,
                        accent: calendarViewModel.themeColor,
                        now: Date(),
                        onFocus: { selectedFriendID = presence.id },
                        onMessage: {},
                        onViewSchedule: {}
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle("Friends Map Demo")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func samplePresences(now: Date) -> [FriendPresence] {
        let directory = CampusDirectory.shared

        func friend(_ id: String, _ name: String) -> SocialFriend {
            SocialFriend(
                id: id, username: id, displayName: name, email: "", isGuest: false,
                shareSchedule: true, shareLocation: true, createdAt: "", lastScheduleAt: nil,
                canViewSchedule: true, schedulePreviewCount: 0, sharedCourseKeys: [], sharedSectionKeys: []
            )
        }

        func location(_ id: String, building buildingID: String, minutesAgo: Double) -> SharedFriendLocation? {
            guard let building = directory.building(id: buildingID) else { return nil }
            return SharedFriendLocation(
                id: id, latitude: building.center.latitude, longitude: building.center.longitude,
                accuracy: 10, precision: .precise, placeID: building.id, placeName: building.name,
                placeKind: .inside, isOnCampus: true,
                updatedAt: now.addingTimeInterval(-minutesAgo * 60), expiresAt: nil
            )
        }

        func schedule(_ title: String, at room: String) -> SharedScheduleSnapshot {
            SharedScheduleSnapshot(semesterCode: "202609", generatedAt: nil, items: [
                SharedScheduleItem(
                    id: title, title: title, location: room,
                    startDate: SharedScheduleDates.string(from: now.addingTimeInterval(-25 * 60)),
                    endDate: SharedScheduleDates.string(from: now.addingTimeInterval(35 * 60)),
                    isAllDay: false, kind: CalendarEventKind.classMeeting.rawValue, badge: nil
                ),
            ])
        }

        return [
            FriendPresenceResolver.resolve(
                friend: friend("maya", "Maya Patel"),
                location: location("maya", building: "dcc", minutesAgo: 2),
                schedule: schedule("Data Structures", at: "Darrin Communications Center 308"),
                now: now
            ),
            FriendPresenceResolver.resolve(
                friend: friend("jordan", "Jordan Lee"),
                location: location("jordan", building: "folsom", minutesAgo: 6),
                schedule: nil,
                now: now
            ),
            FriendPresenceResolver.resolve(
                friend: friend("sam", "Sam Rivera"),
                location: location("sam", building: "commons", minutesAgo: 95),
                schedule: nil,
                now: now
            ),
            FriendPresenceResolver.resolve(
                friend: friend("chris", "Chris Nguyen"),
                location: nil,
                schedule: schedule("Calculus II", at: "Jonsson Engineering Center 3117"),
                now: now
            ),
            FriendPresenceResolver.resolve(
                friend: friend("ava", "Ava Brooks"),
                location: location("ava", building: "dcc", minutesAgo: 4),
                schedule: nil,
                now: now
            ),
        ].compactMap { $0 }
    }
}
#endif
