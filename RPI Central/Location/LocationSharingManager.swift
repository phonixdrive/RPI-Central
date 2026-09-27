//
//  LocationSharingManager.swift
//  RPI Central
//
//  Publishes this user's location to `locationShares/{uid}` for the friends
//  they choose, and listens for friends who share with them.
//
//  Foreground: standard updates, throttled to a write per ~25 m or 3 minutes.
//  Background (opt-in, "Always" permission): significant-change, visits, and
//  campus-zone geofences wake the app for a single fix — the same low-power
//  approach Find My uses — so friends stay current without draining battery.
//

import Combine
import CoreLocation
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
#endif

@MainActor
final class LocationSharingManager: NSObject, ObservableObject {
    static let shared = LocationSharingManager()

    enum PublishTrigger: String {
        case foreground
        case background
        case visit
        case manual
    }

    @Published private(set) var settings: LocationSharingSettings
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var hasFullAccuracy: Bool
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var currentPlace: CampusPlace?
    @Published private(set) var lastPublishedAt: Date?
    @Published private(set) var friendLocations: [String: SharedFriendLocation] = [:]
    @Published var errorMessage: String?

    private let locationManager: CLLocationManager
    private weak var socialManager: SocialManager?
    private var cancellables = Set<AnyCancellable>()
    private var signedInUserID: String?
    private var friendObserverCount = 0
    private var ownLocationObserverCount = 0
    private var isAppActive = false
    private var lastPublishedLocation: CLLocation?
    private var lastPublishedPlaceID: String?
    private var lastPublishedViewerIDs: [String]?
    private var expiryTimer: Timer?
    private var knownFriendIDs: [String]?

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var friendListener: ListenerRegistration?
    private var friendListenerUserID: String?
#endif

    private static let settingsKeyPrefix = "location_sharing_settings_v1."
    private static let viewerIDsKeyPrefix = "location_sharing_viewer_ids_v1."
    private static let regionPrefix = "rpi-campus-zone."
    private static let minimumForegroundMovement: CLLocationDistance = 25
    private static let foregroundHeartbeat: TimeInterval = 3 * 60

    /// Groups of nearby buildings monitored as geofences while background
    /// sharing is on (iOS allows 20 regions per app).
    private static let campusZones: [(id: String, buildingIDs: [String])] = [
        ("academic-core", ["sage", "dcc", "jec", "low", "jrsc", "ricketts", "troy-building", "87-gym", "cbis", "playhouse"]),
        ("library", ["folsom", "vcc", "amos-eaton", "lally", "greene", "walker", "mrc", "empire-state", "cogswell", "carnegie"]),
        ("west", ["west-hall", "pittsburgh", "winslow", "empac"]),
        ("union", ["union", "arc", "mueller", "admissions", "robison-pool", "quad", "sage-dining"]),
        ("freshman-hill", ["commons", "barton", "bray", "cary", "crockett", "davison", "hall-hall", "nason", "nugent", "sharp", "warren"]),
        ("east-campus", ["barh", "rahp-a", "chapel"]),
        ("athletics", ["ecav", "houston"]),
        ("apartments", ["rahp-b", "bryckwyck", "colonie"]),
        ("downtown", ["blitman", "city-station", "gurley"]),
        ("south", ["polytechnic", "academy-hall", "off-campus-commons"]),
        ("north", ["h-building", "j-building", "heffner", "north-hall"]),
    ]

    private override init() {
        let manager = CLLocationManager()
        locationManager = manager
        settings = LocationSharingSettings()
        authorizationStatus = manager.authorizationStatus
        hasFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        super.init()

        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 15

        signedInUserID = Self.firebaseUserID
        settings = Self.loadSettings(for: signedInUserID)
    }

    // MARK: - Lifecycle

    /// Call as early as possible at launch. When iOS relaunches the app for a
    /// location event, restarting monitoring is what delivers that event.
    func handleLaunch() {
        refreshLocationServices()
    }

    func configure(socialManager: SocialManager) {
        guard self.socialManager !== socialManager else { return }
        self.socialManager = socialManager
        cancellables.removeAll()

        socialManager.$currentUser
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] userID in
                self?.handleSignedInUserChange(userID)
            }
            .store(in: &cancellables)

        socialManager.$overview
            .compactMap { $0?.friends.map(\.id).sorted() }
            .removeDuplicates()
            .sink { [weak self] friendIDs in
                self?.handleFriendListChange(friendIDs)
            }
            .store(in: &cancellables)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        isAppActive = phase == .active
        if isAppActive {
            authorizationStatus = locationManager.authorizationStatus
            hasFullAccuracy = locationManager.accuracyAuthorization == .fullAccuracy
            expireSharingIfNeeded()
        }
        refreshLocationServices()
    }

    // MARK: - Observers (views)

    func beginObservingFriends() {
        friendObserverCount += 1
        attachFriendListenerIfNeeded()
    }

    func endObservingFriends() {
        friendObserverCount = max(0, friendObserverCount - 1)
        if friendObserverCount == 0 {
            detachFriendListener(clearLocations: false)
        }
    }

    /// Shows the user's own position on the map even while not sharing.
    func beginShowingOwnLocation() {
        ownLocationObserverCount += 1
        refreshLocationServices()
    }

    func endShowingOwnLocation() {
        ownLocationObserverCount = max(0, ownLocationObserverCount - 1)
        refreshLocationServices()
    }

    // MARK: - Settings

    var isSignedIn: Bool { signedInUserID != nil }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isAuthorizationDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var isSharingActive: Bool {
        settings.isEnabled && !settings.isExpired() && signedInUserID != nil
    }

    /// Number of friends who can currently see this user.
    var viewerCount: Int {
        currentViewerIDs().count
    }

    func setSharingEnabled(_ enabled: Bool, duration: LocationShareDuration = .indefinitely) async {
        guard let userID = signedInUserID else {
            errorMessage = "Sign in on the Social tab to share your location."
            return
        }

        if enabled {
            if isAuthorizationDenied {
                errorMessage = "Location access is off for RPI Central. Turn it on in Settings to share your location."
                return
            }
            if authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
            errorMessage = nil
            settings.isEnabled = true
            settings.expiresAt = duration.expiration()
            saveSettings()
            lastPublishedLocation = nil
            refreshLocationServices()
            if isAuthorized {
                locationManager.requestLocation()
            }
            await socialManager?.setShareLocationFlag(true)
        } else {
            settings.isEnabled = false
            settings.expiresAt = nil
            saveSettings()
            refreshLocationServices()
            await deletePublishedLocation(userID: userID)
            await socialManager?.setShareLocationFlag(false)
        }
    }

    func setDuration(_ duration: LocationShareDuration) {
        settings.expiresAt = duration.expiration()
        saveSettings()
        republishWithCurrentFix()
    }

    func setAudience(_ audience: LocationShareAudience) {
        guard settings.audience != audience else { return }
        settings.audience = audience
        saveSettings()
        republishWithCurrentFix()
    }

    func setFriend(_ friendID: String, selected: Bool) {
        var selectedIDs = Set(settings.selectedFriendIDs)
        if selected {
            selectedIDs.insert(friendID)
        } else {
            selectedIDs.remove(friendID)
        }
        settings.selectedFriendIDs = selectedIDs.sorted()
        saveSettings()
        republishWithCurrentFix()
    }

    func setPrecision(_ precision: LocationSharePrecision) {
        guard settings.precision != precision else { return }
        settings.precision = precision
        saveSettings()
        republishWithCurrentFix()
    }

    func setShareInBackground(_ enabled: Bool) {
        settings.shareInBackground = enabled
        saveSettings()
        if enabled, authorizationStatus != .authorizedAlways {
            // iOS may defer this prompt until the app is in the background.
            locationManager.requestAlwaysAuthorization()
        }
        refreshLocationServices()
    }

    func requestPermission() {
        if authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if isAuthorizationDenied {
            openSystemSettings()
        }
    }

    func requestPreciseAccuracy() {
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "FriendsMap")
    }

    func openSystemSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    /// Called by a background app refresh so friends see a recent time even
    /// when the device has not moved.
    func handleBackgroundRefresh() async {
        guard isSharingActive, settings.shareInBackground, authorizationStatus == .authorizedAlways else {
            expireSharingIfNeeded()
            return
        }
        locationManager.requestLocation()
        // Give the one-shot request a moment to arrive before iOS suspends us.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
    }

    // MARK: - Location services

    private func refreshLocationServices() {
        let sharing = isSharingActive
        let wantsForegroundUpdates = isAppActive && isAuthorized && (sharing || ownLocationObserverCount > 0)
        if wantsForegroundUpdates {
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 15
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
        }

        let wantsBackgroundMonitoring = sharing && settings.shareInBackground && authorizationStatus == .authorizedAlways
        if wantsBackgroundMonitoring {
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.startMonitoringVisits()
            startMonitoringCampusZones()
        } else {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            stopMonitoringCampusZones()
        }

        scheduleExpiryTimer()
    }

    private func startMonitoringCampusZones() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let monitored = Set(locationManager.monitoredRegions.map(\.identifier))
        for region in Self.campusZoneRegions() where !monitored.contains(region.identifier) {
            locationManager.startMonitoring(for: region)
        }
    }

    private func stopMonitoringCampusZones() {
        for region in locationManager.monitoredRegions where region.identifier.hasPrefix(Self.regionPrefix) {
            locationManager.stopMonitoring(for: region)
        }
    }

    private static func campusZoneRegions() -> [CLCircularRegion] {
        let directory = CampusDirectory.shared
        return campusZones.compactMap { zone in
            let centers = zone.buildingIDs.compactMap { directory.building(id: $0)?.center }
            guard !centers.isEmpty else { return nil }
            let center = CLLocationCoordinate2D(
                latitude: centers.map(\.latitude).reduce(0, +) / Double(centers.count),
                longitude: centers.map(\.longitude).reduce(0, +) / Double(centers.count)
            )
            let spread = centers.map { CampusDirectory.meters(from: center, to: $0) }.max() ?? 0
            let region = CLCircularRegion(
                center: center,
                radius: min(350, max(120, spread + 60)),
                identifier: regionPrefix + zone.id
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            return region
        }
    }

    private func scheduleExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard isAppActive, settings.isEnabled, let expiresAt = settings.expiresAt else { return }

        let interval = max(1, expiresAt.timeIntervalSinceNow)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.expireSharingIfNeeded()
            }
        }
    }

    private func expireSharingIfNeeded() {
        guard settings.isEnabled, settings.isExpired() else { return }
        Task { await setSharingEnabled(false) }
    }

    // MARK: - Handling fixes

    fileprivate func handle(location: CLLocation, trigger: PublishTrigger) {
        guard location.horizontalAccuracy >= 0 else { return }
        lastLocation = location
        let place = CampusDirectory.shared.place(
            for: location.coordinate,
            horizontalAccuracy: location.horizontalAccuracy
        )
        currentPlace = place

        guard isSharingActive else {
            expireSharingIfNeeded()
            return
        }
        guard location.horizontalAccuracy <= 1_000 else { return }
        guard shouldPublish(location, place: place, trigger: trigger) else { return }

        Task { await publish(location: location, place: place, trigger: trigger) }
    }

    private func shouldPublish(_ location: CLLocation, place: CampusPlace, trigger: PublishTrigger) -> Bool {
        guard let previous = lastPublishedLocation else { return true }
        // Background wake-ups are rare and each is worth reporting.
        guard trigger == .foreground else { return true }
        if place.building?.id != lastPublishedPlaceID { return true }
        if currentViewerIDs() != lastPublishedViewerIDs { return true }
        return location.distance(from: previous) >= Self.minimumForegroundMovement ||
            location.timestamp.timeIntervalSince(previous.timestamp) >= Self.foregroundHeartbeat
    }

    private func republishWithCurrentFix() {
        guard isSharingActive else { return }
        lastPublishedLocation = nil
        if let lastLocation, Date().timeIntervalSince(lastLocation.timestamp) < 5 * 60 {
            handle(location: lastLocation, trigger: .manual)
        } else if isAuthorized {
            locationManager.requestLocation()
        }
    }

    /// Coordinates as they will be published for the chosen precision.
    private func publishedCoordinate(
        for location: CLLocation,
        place: CampusPlace
    ) -> (coordinate: CLLocationCoordinate2D, accuracy: Double) {
        switch settings.precision {
        case .precise:
            return (location.coordinate, location.horizontalAccuracy)
        case .building:
            if let building = place.building {
                return (building.center, max(location.horizontalAccuracy, 40))
            }
            // About 110 m of rounding off campus.
            let rounded = CLLocationCoordinate2D(
                latitude: (location.coordinate.latitude * 1_000).rounded() / 1_000,
                longitude: (location.coordinate.longitude * 1_000).rounded() / 1_000
            )
            return (rounded, max(location.horizontalAccuracy, 120))
        }
    }

    private func publish(location: CLLocation, place: CampusPlace, trigger: PublishTrigger) async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let userID = signedInUserID else { return }
        let backgroundTask = beginBackgroundTask()
        defer { endBackgroundTask(backgroundTask) }

        let viewerIDs = currentViewerIDs()
        let published = publishedCoordinate(for: location, place: place)
        let now = Date()

        let data: [String: Any] = [
            "ownerID": userID,
            "viewerIDs": viewerIDs,
            "latitude": published.coordinate.latitude,
            "longitude": published.coordinate.longitude,
            "accuracy": (published.accuracy * 10).rounded() / 10,
            "precision": settings.precision.rawValue,
            "placeID": place.building?.id ?? "",
            "placeName": place.building?.name ?? "",
            "placeKind": place.kind.rawValue,
            "isOnCampus": place.isOnCampus,
            "updatedAt": SharedScheduleDates.string(from: now),
            "updatedAtServer": FieldValue.serverTimestamp(),
            "expiresAt": settings.expiresAt.map(SharedScheduleDates.string(from:)) ?? "",
            "expiresAtTimestamp": settings.expiresAt.map { Timestamp(date: $0) } ?? NSNull(),
            "source": trigger.rawValue,
        ]

        do {
            try await setDocument(data, at: Firestore.firestore().collection("locationShares").document(userID))
            lastPublishedLocation = location
            lastPublishedPlaceID = place.building?.id
            lastPublishedViewerIDs = viewerIDs
            lastPublishedAt = now
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update your shared location: \(error.localizedDescription)"
        }
