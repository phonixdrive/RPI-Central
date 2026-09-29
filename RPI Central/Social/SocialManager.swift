import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
#endif

enum GroupChatUnreadPolicy {
    static func hasUnread(
        latestMessageID: String?,
        latestMessageDate: Date?,
        latestSenderID: String?,
        viewerID: String,
        readMessageID: String?,
        readMessageDate: Date?
    ) -> Bool {
        hasUnread(
            latestMessageID: latestMessageID,
            latestMessageDate: latestMessageDate,
            latestSenderID: latestSenderID,
            viewerID: viewerID,
            readMessageID: readMessageID,
            readMessageDate: readMessageDate,
            latestThreadVersionWasAcknowledged: false
        )
    }

    static func hasUnread(
        latestMessageID: String?,
        latestMessageDate: Date?,
        latestSenderID: String?,
        viewerID: String,
        readMessageID: String?,
        readMessageDate: Date?,
        latestThreadVersionWasAcknowledged: Bool
    ) -> Bool {
        // A thread without an actual last sender has no messages. Messages sent by
        // the viewer are also already read by definition.
        guard let latestSenderID, latestSenderID != viewerID else { return false }
        guard !latestThreadVersionWasAcknowledged else { return false }

        guard let readMessageDate else { return true }

        if let latestMessageID, latestMessageID == readMessageID {
            return false
        }

        if let latestMessageDate {
            if latestMessageDate > readMessageDate { return true }
            if latestMessageDate < readMessageDate { return false }

            // IDs disambiguate distinct messages created during the same second.
            // Stale IDs are handled by the local acknowledged-version ledger.
            if let latestMessageID, let readMessageID {
                return latestMessageID != readMessageID
            }
            return false
        }

        // Malformed legacy timestamps can still use message identity safely.
        if let latestMessageID {
            return latestMessageID != readMessageID
        }
        return false
    }
}

@MainActor
final class SocialManager: ObservableObject {
    static let defaultChatPushRelayBaseURL = "https://rpi-central-web.onrender.com"

    private struct GroupChatThreadState {
        let updatedAt: String
        let latestMessageID: String?
        let lastSenderID: String?
    }

    private struct StoredGroupChatReadReceipt: Codable, Equatable {
        let messageID: String?
        let messageAt: String
        var acknowledgedThreadVersions: [String]? = nil
    }

    @Published private(set) var currentUser: SocialUser? {
        didSet {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let previousUserID = oldValue?.id
            let currentUserID = currentUser?.id
            Task { [weak self] in
                await self?.handleCurrentUserChange(previousUserID: previousUserID, currentUserID: currentUserID)
            }
#endif
        }
    }
    @Published private(set) var overview: SocialOverviewResponse?
    @Published private(set) var friendGroups: [SocialFriendGroup] = []
    @Published private(set) var courseCommunities: [SocialCourseCommunity] = []
    @Published private(set) var courseCommentsByCommunityID: [String: [SocialCourseComment]] = [:]
    @Published private(set) var feedItems: [SocialFeedItem] = []
    @Published private(set) var searchResults: [SocialSearchResult] = []
    @Published private(set) var quickAddSuggestions: [SocialSearchResult] = []
    /// People this user blocked. Their messages, plans, and profiles are hidden.
    @Published private(set) var blockedUserIDs: Set<String> = []
    private var blockedUsersLoadedFor: String?
    @Published private(set) var loadedFriendSchedule: FriendScheduleResponse?
    @Published private var friendScheduleCacheByFriendID: [String: FriendScheduleResponse] = [:]
    @Published private(set) var activeGroupChatID: String?
    @Published private var groupChatThreadStates: [String: GroupChatThreadState] = [:]
    @Published private(set) var canModerateSocialContent = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var isFirebaseAvailable: Bool
    @Published private(set) var setupMessage: String

    private let campusWideGroupThreadID = "campusGroup_all_rpi_students"
    private let receivedSharedEventsStorageKey = "received_shared_calendar_events_v1"
    private let deliveredSocialAlertIDsKey = "social.delivered_alert_ids_v1"
    private let socialFeedNotificationsEnabledKey = "settings_social_feed_notifications_enabled_v1"
    private let socialGroupNotificationsEnabledKey = "settings_social_group_notifications_enabled_v1"
    private let mutedGroupChatIDsKey = "social.muted_group_chat_ids_v1"
    private let groupChatReadReceiptsKey = "social.group_chat_read_receipts_v2"
    private let legacyGroupChatLastSeenKey = "social.group_chat_last_seen_v1"
    private let legacyGroupChatLastSeenMessageIDKey = "social.group_chat_last_seen_message_ids_v1"
    private let chatPushRelayBaseURLKey = "chat_push_relay_base_url_v1"
    private let sharedScheduleFingerprintsKey = "social.shared_schedule_fingerprints_v2"
    private let sharedScheduleCleanupKey = "social.shared_schedule_cleanup_v2"
    private var pushTokenObserver: NSObjectProtocol? = nil

    /// Friends' calendars are republished from this model whenever it changes,
    /// independent of which tab is on screen.
    private weak var scheduleSource: CalendarViewModel?
    private var scheduleSourceCancellable: AnyCancellable?
    private var scheduleSyncInFlight = false
    private var scheduleSyncPending = false
    private var scheduleSyncForceRequested = false
    private var lastKnownFriendIDs: Set<String>?
    private var overviewRefreshTask: Task<Void, Never>?

    /// When this device last published its schedule, and through which date.
    @Published private(set) var lastSchedulePublish: (publishedAt: Date, coverageEnd: Date)?

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var listenerRegistrations: [ListenerRegistration] = []
    private var activeListenerUserID: String?
    private var realtimeMemberGroupChatIDs: Set<String> = []
    private var authStateListenerHandle: AuthStateDidChangeListenerHandle?
    private var permissionRecoveryInFlight = false
#endif

    init() {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        self.isFirebaseAvailable = true
        self.setupMessage = FirebaseApp.app() == nil
            ? "Firebase packages detected. Add GoogleService-Info.plist to finish setup."
            : "Firebase is configured."

        pushTokenObserver = NotificationCenter.default.addObserver(
            forName: NotificationManager.pushTokenDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.syncPushNotificationPreferences()
            }
        }
        UserDefaults.standard.set(Self.defaultChatPushRelayBaseURL, forKey: chatPushRelayBaseURLKey)
        if socialFeedNotificationsEnabled || socialGroupNotificationsEnabled {
            NotificationManager.requestAuthorization()
        }
        NotificationManager.registerForRemoteNotificationsIfAuthorized()
        Task {
            await bootstrapFirebaseSession()
        }
#else
        self.isFirebaseAvailable = false
        self.setupMessage = "Add FirebaseCore, FirebaseAuth, and FirebaseFirestore, then add GoogleService-Info.plist."
#endif
    }

    deinit {
        if let pushTokenObserver {
            NotificationCenter.default.removeObserver(pushTokenObserver)
        }
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        listenerRegistrations.forEach { $0.remove() }
        if let authStateListenerHandle {
            Auth.auth().removeStateDidChangeListener(authStateListenerHandle)
        }
#endif
    }

    var isAuthenticated: Bool {
        currentUser != nil
    }

    /// False when the Firebase SDK is linked but GoogleService-Info.plist is missing.
    var isFirebaseConfigured: Bool {
#if canImport(FirebaseCore)
        isFirebaseAvailable && FirebaseApp.app() != nil
#else
        false
#endif
    }

    func canDeleteGroupChatMessage(_ message: SocialGroupChatMessage) -> Bool {
        currentUser?.id == message.userID || canModerateSocialContent
    }

    func moderationState(for userID: String) async -> SocialModerationState {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        do {
            return try await loadModerationState(for: userID)
        } catch {
            return SocialModerationState(isBanned: false, mutedUntil: nil)
        }
#else
        return SocialModerationState(isBanned: false, mutedUntil: nil)
#endif
    }

    @discardableResult
    func setUserBanned(_ banned: Bool, userID: String) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard canModerateSocialContent else {
                throw SocialError.api("You do not have moderation access.")
            }

            try await updateData([
                "socialBanned": banned
            ], at: firestore.collection("users").document(userID))
            statusMessage = banned ? "User banned from social." : "User unbanned."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func setUserMuted(until: Date?, userID: String) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard canModerateSocialContent else {
                throw SocialError.api("You do not have moderation access.")
            }

            let value: Any = until.map { Timestamp(date: $0) } ?? NSNull()
            try await updateData([
                "socialMutedUntil": value
            ], at: firestore.collection("users").document(userID))

            if let until {
                statusMessage = "User muted until \(DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .short))."
            } else {
                statusMessage = "User unmuted."
            }
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    var campusWideChatReference: SocialGroupChatReference? {
        guard let currentUser else { return nil }
        return SocialGroupChatReference(
            id: campusWideGroupThreadID,
            title: "All RPI Students",
            subtitle: "Campus-wide chat",
            memberDisplayNames: [],
            memberIDs: [currentUser.id],
            sourceKind: .campusGroup
        )
    }

    func logout() {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        let previousUserID = currentUser?.id
        detachRealtimeListeners()
        if let previousUserID {
            Task { [weak self] in
                await self?.unregisterPushRegistration(for: previousUserID)
                // A signed-out phone must not keep a location visible to friends.
                if let locationReference = self?.firestore.collection("locationShares").document(previousUserID) {
                    try? await self?.deleteDocument(locationReference)
                }
                do {
                    try Auth.auth().signOut()
                } catch {
                    await MainActor.run {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
        } else {
            do {
                try Auth.auth().signOut()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
#endif
        clearLocalSharedCalendarEvents()
        currentUser = nil
        overview = nil
        friendGroups = []
        courseCommunities = []
        courseCommentsByCommunityID = [:]
        feedItems = []
        searchResults = []
        quickAddSuggestions = []
        groupChatThreadStates = [:]
        loadedFriendSchedule = nil
        friendScheduleCacheByFriendID = [:]
        activeGroupChatID = nil
        statusMessage = nil
        lastKnownFriendIDs = nil
        lastSchedulePublish = nil
        blockedUserIDs = []
        blockedUsersLoadedFor = nil
        overviewRefreshTask?.cancel()
    }

    @discardableResult
    func requestAccountDeletion() async -> Bool {
        var didRequestDeletion = false
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await setData([
                "requesterID": viewer.id,
                "requestedAt": FieldValue.serverTimestamp(),
            ], at: firestore.collection("accountDeletionRequests").document(viewer.id))
            didRequestDeletion = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        if didRequestDeletion {
            logout()
        }
        return didRequestDeletion
    }

    func loadQuickAddSuggestions() async {
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }

            let incoming = Set(overview?.incomingRequests.compactMap { $0.fromUser?.id } ?? [])
            let outgoing = Set(overview?.outgoingRequests.compactMap { $0.toUser?.id } ?? [])
            let friends = Set(overview?.friends.map(\.id) ?? [])
            let excluded = friends.union(incoming).union(outgoing).union([viewer.id])

            // Suggest classmates: people in your class groups, weighted toward
            // the exact sections you share. This used to download every
            // profile in the database.
            if courseCommunities.isEmpty {
                courseCommunities = (try? await loadCourseCommunities(memberID: viewer.id)) ?? []
            }
            let currentTerm = scheduleSource?.currentSemester.rawValue
            var sharedClassCounts: [String: Int] = [:]
            var scores: [String: Int] = [:]
            for community in courseCommunities {
                let isCurrentSection = community.kind == .section && community.semesterCode == currentTerm
                let weight = community.kind == .section ? (isCurrentSection ? 4 : 2) : 1
                for memberID in community.memberIDs where !excluded.contains(memberID) {
                    scores[memberID, default: 0] += weight
                    if community.kind == .course {
                        sharedClassCounts[memberID, default: 0] += 1
                    }
                }
            }

            let rankedIDs = scores
                .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
                .prefix(24)
                .map(\.key)
            var candidates = try await fetchUsers(ids: rankedIDs)
            var orderedIDs = rankedIDs

            if orderedIDs.count < 8 {
                // Early on there are few classmates in the app; fall back to
                // people who recently joined.
                let recent = try await getDocuments(
                    firestore.collection("users")
                        .order(by: "createdAt", descending: true)
                        .limit(to: 20)
                )
                for document in recent.documents where !excluded.contains(document.documentID) {
                    guard candidates[document.documentID] == nil,
                          let user = makeUser(from: document) else { continue }
                    candidates[document.documentID] = user
                    orderedIDs.append(document.documentID)
                }
            }

            quickAddSuggestions = orderedIDs
                .filter { !blockedUserIDs.contains($0) }
                .compactMap { candidates[$0] }
                .filter { !isDemoUser($0) && !$0.isGuest }
                .map { user in
                    let sharedClasses = sharedClassCounts[user.id] ?? 0
                    return SocialSearchResult(
                        id: user.id,
                        username: user.username,
                        displayName: user.displayName,
                        email: user.email,
                        isGuest: user.isGuest,
                        shareSchedule: user.shareSchedule,
                        shareLocation: user.shareLocation,
                        createdAt: user.createdAt,
                        lastScheduleAt: user.lastScheduleAt,
                        areFriends: false,
                        hasPendingIncoming: false,
                        hasPendingOutgoing: false,
                        reason: sharedClasses > 0
                            ? "\(sharedClasses) shared class\(sharedClasses == 1 ? "" : "es")"
                            : (scores[user.id] != nil ? "In your class groups" : "New to RPI Central")
                    )
                }
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func loadUserProfile(id: String) async -> SocialUser? {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        do {
            return try await fetchUser(id: id)
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    func loadUserProfiles(ids: [String]) async -> [String: SocialUser] {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        do {
            return try await fetchUsers(ids: ids)
        } catch {
            return [:]
        }
#else
        return [:]
#endif
    }

    func setActiveGroupChat(id: String?) {
        activeGroupChatID = id
        NotificationManager.setActiveSocialContextID(id)
        if let id {
            acknowledgeGroupChatThreadState(threadID: id)
        }
    }

    func markGroupChatSeen(
        _ reference: SocialGroupChatReference,
        latestMessageID: String? = nil,
        latestMessageAt: String? = nil
    ) {
        guard let viewerID = currentUser?.id,
              let latestMessageID,
              !latestMessageID.isEmpty,
              let latestMessageAt,
              let latestDate = isoDate(latestMessageAt) else {
            // Never clear an unread badge when loading returned no messages.
            return
        }

        let key = groupChatReadReceiptKey(userID: viewerID, threadID: reference.id)
        let existing = groupChatReadReceipt(storageKey: key, legacyThreadID: reference.id)
        var acknowledgedVersions = existing?.acknowledgedThreadVersions ?? []
        if let threadState = groupChatThreadStates[reference.id],
           let version = groupChatThreadVersionKey(for: threadState) {
            acknowledgedVersions = appendingAcknowledgedThreadVersion(
                version,
                to: acknowledgedVersions
            )
        }
        let actualMessageVersion = groupChatThreadVersionKey(
            latestMessageID: latestMessageID,
            updatedAt: latestMessageAt
        )
        acknowledgedVersions = appendingAcknowledgedThreadVersion(
            actualMessageVersion,
            to: acknowledgedVersions
        )

        let shouldKeepExistingCursor = existing
            .flatMap { isoDate($0.messageAt) }
            .map { $0 > latestDate } ?? false
        let receipt = StoredGroupChatReadReceipt(
            messageID: shouldKeepExistingCursor ? existing?.messageID : latestMessageID,
            messageAt: shouldKeepExistingCursor ? (existing?.messageAt ?? latestMessageAt) : latestMessageAt,
            acknowledgedThreadVersions: acknowledgedVersions
        )

        var receipts = groupChatReadReceipts
        guard receipts[key] != receipt else { return }
        receipts[key] = receipt
        persistGroupChatReadReceipts(receipts)
        objectWillChange.send()
    }

    /// When the chat last had a message, for sorting the chat list.
    func lastActivityDate(in reference: SocialGroupChatReference) -> Date? {
        groupChatThreadStates[reference.id].flatMap { isoDate($0.updatedAt) }
    }

    func hasUnreadMessages(in reference: SocialGroupChatReference) -> Bool {
        guard let viewer = currentUser,
              let threadState = groupChatThreadStates[reference.id],
              let lastSenderID = threadState.lastSenderID else {
            return false
        }

        let key = groupChatReadReceiptKey(userID: viewer.id, threadID: reference.id)
        let receipt = groupChatReadReceipt(
            storageKey: key,
            legacyThreadID: reference.id
        )
        let threadVersion = groupChatThreadVersionKey(for: threadState)
        let latestThreadVersionWasAcknowledged = threadVersion.map {
            receipt?.acknowledgedThreadVersions?.contains($0) == true
        } ?? false
        return GroupChatUnreadPolicy.hasUnread(
            latestMessageID: threadState.latestMessageID,
            latestMessageDate: isoDate(threadState.updatedAt),
            latestSenderID: lastSenderID,
            viewerID: viewer.id,
            readMessageID: receipt?.messageID,
            readMessageDate: receipt.flatMap { isoDate($0.messageAt) },
            latestThreadVersionWasAcknowledged: latestThreadVersionWasAcknowledged
        )
    }

    func isChatMuted(_ reference: SocialGroupChatReference) -> Bool {
        mutedGroupChatIDs.contains(reference.id)
    }

    func setChatMuted(_ muted: Bool, for reference: SocialGroupChatReference) async {
        var updated = mutedGroupChatIDs
        if muted {
            updated.insert(reference.id)
        } else {
            updated.remove(reference.id)
        }

        UserDefaults.standard.set(Array(updated).sorted(), forKey: mutedGroupChatIDsKey)
        objectWillChange.send()
        await syncPushRegistrationIfPossible()
    }

    func syncPushNotificationPreferences() async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        await syncPushRegistrationIfPossible()
#endif
    }

    func register(displayName: String, email: String, password: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let normalizedName = normalizeDisplayName(displayName)
            let normalizedEmail = normalizeEmail(email)
            guard !normalizedName.isEmpty, !normalizedEmail.isEmpty, password.count >= 6 else {
                throw SocialError.api("Display name, email, and a 6+ character password are required.")
            }

            let authResult: AuthDataResult
            if let existing = Auth.auth().currentUser, existing.isAnonymous {
                let credential = EmailAuthProvider.credential(withEmail: normalizedEmail, password: password)
                authResult = try await linkAnonymousUser(existing, credential: credential)
            } else {
                authResult = try await createUser(email: normalizedEmail, password: password)
            }

            let user = try await upsertProfile(
                for: authResult.user,
                displayName: normalizedName,
                email: normalizedEmail,
                isGuest: false
            )
            currentUser = user
            try await refreshOverviewInternal()
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func updateDisplayName(_ displayName: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let normalizedName = normalizeDisplayName(displayName)
            guard !normalizedName.isEmpty else {
                throw SocialError.api("Display name cannot be empty.")
            }

            try await updateData([
                "displayName": normalizedName,
                "displayNameLower": normalizedName.lowercased(),
            ], at: firestore.collection("users").document(viewer.id))

            currentUser = SocialUser(
                id: viewer.id,
                username: viewer.username,
                displayName: normalizedName,
                email: viewer.email,
                isGuest: viewer.isGuest,
                shareSchedule: viewer.shareSchedule,
                shareLocation: viewer.shareLocation,
                createdAt: viewer.createdAt,
                lastScheduleAt: viewer.lastScheduleAt,
                sharedCourseKeys: viewer.sharedCourseKeys,
                sharedSectionKeys: viewer.sharedSectionKeys
            )
            try await refreshOverviewInternal()
            statusMessage = "Display name updated."
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func login(email: String, password: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let normalizedEmail = normalizeEmail(email)
            guard !normalizedEmail.isEmpty, !password.isEmpty else {
                throw SocialError.api("Email and password are required.")
            }

            if Auth.auth().currentUser?.isAnonymous == true {
                try? Auth.auth().signOut()
            }

            let authResult = try await signIn(email: normalizedEmail, password: password)
            let user = try await fetchOrCreateProfile(for: authResult.user)
            currentUser = user
            try await refreshOverviewInternal()
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func continueAsGuest(displayName: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let normalizedName = normalizeDisplayName(displayName.isEmpty ? "Guest" : displayName)
            let firebaseUser: User

            if let existing = Auth.auth().currentUser, existing.isAnonymous {
                firebaseUser = existing
            } else {
                let authResult = try await signInAnonymously()
                firebaseUser = authResult.user
            }

            let user = try await upsertProfile(
                for: firebaseUser,
                displayName: normalizedName,
                email: "",
                isGuest: true
            )
            currentUser = user
            try await refreshOverviewInternal()
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func refreshOverview() async {
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            try await refreshOverviewInternal()
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func searchUsers(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let lower = trimmed.lowercased()
            let usersRef = firestore.collection("users")

            let usernameDocs = try await getDocuments(
                usersRef
                    .order(by: "usernameLower")
                    .start(at: [lower])
                    .end(at: ["\(lower)\u{f8ff}"])
                    .limit(to: 12)
            ).documents

            let displayDocs = try await getDocuments(
                usersRef
                    .order(by: "displayNameLower")
                    .start(at: [lower])
                    .end(at: ["\(lower)\u{f8ff}"])
                    .limit(to: 12)
            ).documents

            let merged = mergeUniqueDocuments(usernameDocs + displayDocs)
            let incoming = Set(overview?.incomingRequests.compactMap { $0.fromUser?.id } ?? [])
            let outgoing = Set(overview?.outgoingRequests.compactMap { $0.toUser?.id } ?? [])
            let friends = Set(overview?.friends.map(\.id) ?? [])

            searchResults = merged
                .compactMap(makeUser)
                .filter { $0.id != viewer.id && !blockedUserIDs.contains($0.id) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { user in
                    SocialSearchResult(
                        id: user.id,
                        username: user.username,
                        displayName: user.displayName,
                        email: user.email,
                        isGuest: user.isGuest,
                        shareSchedule: user.shareSchedule,
                        shareLocation: user.shareLocation,
                        createdAt: user.createdAt,
                        lastScheduleAt: user.lastScheduleAt,
                        areFriends: friends.contains(user.id),
                        hasPendingIncoming: incoming.contains(user.id),
                        hasPendingOutgoing: outgoing.contains(user.id)
                    )
                }
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func seedDemoData(for calendarViewModel: CalendarViewModel) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore) && canImport(FirebaseCore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let context = try makeSecondaryFirebaseContext()

            let searchableUser = try await createDemoUser(
                context: context,
                displayName: "Demo Search \(demoSuffix())",
                shareSchedule: false,
                semesterCode: nil,
                scheduleItems: []
            )

            let requester = try await createDemoUser(
                context: context,
                displayName: "Demo Request \(demoSuffix())",
                shareSchedule: false,
                semesterCode: nil,
                scheduleItems: []
            )

            try await setData([
                "fromUserID": requester.id,
                "toUserID": viewer.id,
                "status": "pending",
                "createdAt": nowISO(),
                "respondedAt": "",
            ], at: context.firestore.collection("friendRequests").document())

            let demoFriend = try await createDemoUser(
                context: context,
                displayName: "Demo Friend \(demoSuffix())",
                shareSchedule: true,
                semesterCode: calendarViewModel.currentSemester.rawValue,
                scheduleItems: demoScheduleItems()
            )

            let demoFriendRequestRef = context.firestore.collection("friendRequests").document()
            try await setData([
                "fromUserID": demoFriend.id,
                "toUserID": viewer.id,
                "status": "pending",
                "createdAt": nowISO(),
                "respondedAt": "",
            ], at: demoFriendRequestRef)
            try await updateData([
                "status": "accepted",
                "respondedAt": nowISO(),
            ], at: firestore.collection("friendRequests").document(demoFriendRequestRef.documentID))

            try await setData([
                "members": [viewer.id, demoFriend.id].sorted(),
                "createdAt": nowISO(),
                "acceptedRequestID": demoFriendRequestRef.documentID,
            ], at: firestore.collection("friendships").document(canonicalFriendshipID(viewer.id, demoFriend.id)))

            try await writeFriendViewSchedule(
                ownerID: demoFriend.id,
                viewerID: viewer.id,
                semesterCode: calendarViewModel.currentSemester.rawValue,
                generatedAt: demoFriend.lastScheduleAt ?? nowISO(),
                items: demoScheduleItems()
            )

            try? context.auth.signOut()

            statusMessage = "Created @\(searchableUser.username), @\(requester.username), and @\(demoFriend.username)."
            try await refreshOverviewInternal()
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func sendFriendRequest(to username: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedUsername.isEmpty else { throw SocialError.api("Username is required.") }

            let targetSnapshot = try await getDocuments(
                firestore.collection("users").whereField("usernameLower", isEqualTo: normalizedUsername).limit(to: 1)
            )
            guard let targetDoc = targetSnapshot.documents.first,
                  let target = makeUser(from: targetDoc) else {
                throw SocialError.api("That user was not found.")
            }

            try await sendFriendRequestInternal(to: target)
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func sendFriendRequest(toUserID userID: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let target = try await fetchUser(id: userID) else {
                throw SocialError.api("That user was not found.")
            }
            try await sendFriendRequestInternal(to: target)
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func respondToFriendRequest(_ requestID: String, action: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            guard action == "accept" || action == "decline" else {
                throw SocialError.api("Invalid action.")
            }

            let requestRef = firestore.collection("friendRequests").document(requestID)
            let snapshot = try await getDocument(requestRef)
            guard let data = snapshot.data(),
                  data["toUserID"] as? String == viewer.id,
                  data["status"] as? String == "pending",
                  let fromUserID = data["fromUserID"] as? String else {
                throw SocialError.api("That friend request is not available.")
            }

            try await updateData([
                "status": action == "accept" ? "accepted" : "declined",
                "respondedAt": nowISO(),
            ], at: requestRef)

            if action == "accept" {
                let friendshipID = canonicalFriendshipID(viewer.id, fromUserID)
                try await setData([
                    "members": [viewer.id, fromUserID].sorted(),
                    "createdAt": nowISO(),
                    "acceptedRequestID": requestID,
                ], at: firestore.collection("friendships").document(friendshipID))
            }

            try await refreshOverviewInternal()
            statusMessage = action == "accept" ? "Friend request accepted." : "Friend request declined."
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    @discardableResult
    func createFriendGroup(name: String, memberIDs: [String]) async -> Bool {
        var didSucceed = false
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanUseSocial()
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw SocialError.api("Group name is required.")
            }

            let validFriendIDs = Set(overview?.friends.map(\.id) ?? [])
            let sanitizedMembers = Array(Set(memberIDs)).filter { validFriendIDs.contains($0) }.sorted()
            guard !sanitizedMembers.isEmpty else {
                throw SocialError.api("Choose at least one friend.")
            }

            var groups = try await loadFriendGroups(ownerID: viewer.id)
            groups.append(
                SocialFriendGroup(
                    id: UUID().uuidString,
                    ownerID: viewer.id,
                    name: normalizedName,
                    createdAt: nowISO(),
                    memberIDs: sanitizedMembers
                )
            )

            try await saveFriendGroups(groups, ownerID: viewer.id)

            try await refreshOverviewInternal()
            statusMessage = "Group created."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func deleteFriendGroup(_ groupID: String) async -> Bool {
        var didSucceed = false
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let groups = try await loadFriendGroups(ownerID: viewer.id)
            guard groups.contains(where: { $0.id == groupID && $0.ownerID == viewer.id }) else {
                throw SocialError.api("That group is not available.")
            }

            let updatedGroups = groups.filter { $0.id != groupID }
            try await saveFriendGroups(updatedGroups, ownerID: viewer.id)
            try await refreshOverviewInternal()
            statusMessage = "Group removed."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func leaveFriendGroup(_ group: SocialFriendGroup) async -> Bool {
        var didSucceed = false
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            guard group.ownerID != viewer.id else {
                throw SocialError.api("Group owners should delete the group instead.")
            }
            guard group.memberIDs.contains(viewer.id) else {
                throw SocialError.api("You are not part of that group.")
            }

            let updatedMemberIDs = group.memberIDs.filter { $0 != viewer.id }
            try await updateData([
                "memberIDs": updatedMemberIDs
            ], at: firestore.collection("friendGroups").document(group.id))

            try await refreshOverviewInternal()
            statusMessage = "You left the group."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func addMembersToFriendGroup(groupID: String, memberIDs: [String]) async -> Bool {
        var didSucceed = false
        let incomingMemberIDs = Array(Set(memberIDs)).sorted()

        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanUseSocial()
            guard !incomingMemberIDs.isEmpty else { throw SocialError.api("Pick at least one person to add.") }

            let groups = try await loadFriendGroups(ownerID: viewer.id)
            guard let existingGroup = groups.first(where: { $0.id == groupID && $0.ownerID == viewer.id }) else {
                throw SocialError.api("Only the group owner can add people.")
            }

            let updatedGroup = SocialFriendGroup(
                id: existingGroup.id,
                ownerID: existingGroup.ownerID,
                name: existingGroup.name,
                createdAt: existingGroup.createdAt,
                memberIDs: Array(Set(existingGroup.memberIDs + incomingMemberIDs)).sorted()
            )

            let updatedGroups = groups.map { $0.id == groupID ? updatedGroup : $0 }
            try await saveFriendGroups(updatedGroups, ownerID: viewer.id)
            try await refreshOverviewInternal()
            statusMessage = "Group updated."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    func overallCourseCommunityID(for course: Course) -> String {
        "course_\(normalizedCourseToken(subject: course.subject, number: course.number))"
    }

    func courseComments(for course: Course) -> [SocialCourseComment] {
        courseCommentsByCommunityID[overallCourseCommunityID(for: course)] ?? []
    }

    func syncCourseCommunities(from calendarViewModel: CalendarViewModel) async {
        await syncCourseCommunities(for: calendarViewModel.enrolledCourses)
    }

    func syncCourseCommunities(for enrollments: [EnrolledCourse]) async {
        guard !enrollments.isEmpty else { return }
        await runOperation(showSpinner: false, quiet: true) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }

            if courseCommunities.isEmpty {
                courseCommunities = try await loadCourseCommunities(memberID: viewer.id)
            }
            // Only write memberships that are missing; this runs on every
            // schedule change and used to rewrite two documents per course.
            let joinedCommunityIDs = Set(
                courseCommunities.filter { $0.memberIDs.contains(viewer.id) }.map(\.id)
            )
            var seenCommunityIDs = Set<String>()
            var didJoin = false

            for enrollment in enrollments {
                let communities = [
                    makeCourseCommunity(
                        kind: .course,
                        course: enrollment.course,
                        section: nil,
                        semesterCode: nil,
                        viewerID: viewer.id
                    ),
                    makeCourseCommunity(
                        kind: .section,
                        course: enrollment.course,
                        section: enrollment.section,
                        semesterCode: enrollment.semesterCode,
                        viewerID: viewer.id
                    ),
                ]
                for community in communities where seenCommunityIDs.insert(community.id).inserted {
                    guard !joinedCommunityIDs.contains(community.id) else { continue }
                    try await ensureCourseCommunityMembership(community, viewerID: viewer.id)
                    didJoin = true
                }
            }

            if didJoin {
                courseCommunities = try await loadCourseCommunities(memberID: viewer.id)
            }
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func refreshCourseComments(for course: Course) async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        let communityID = overallCourseCommunityID(for: course)
        guard let viewer = currentUser else {
            courseCommentsByCommunityID[communityID] = []
            return
        }

        do {
            let community = makeCourseCommunity(
                kind: .course,
                course: course,
                section: nil,
                semesterCode: nil,
                viewerID: viewer.id
            )
            try await ensureCourseCommunityMembership(community, viewerID: viewer.id)
            let communityRef = firestore.collection("courseCommunities").document(communityID)
            courseCommentsByCommunityID[communityID] = try await loadCourseComments(communityRef: communityRef)
            courseCommunities = try await loadCourseCommunities(memberID: viewer.id)
        } catch {
            if isPermissionDenied(error) {
                courseCommentsByCommunityID[communityID] = []
            } else {
                errorMessage = error.localizedDescription
            }
        }
#else
        courseCommentsByCommunityID[overallCourseCommunityID(for: course)] = []
#endif
    }

    @discardableResult
    func postCourseComment(for course: Course, body: String) async -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var didSucceed = false

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanPostSocialContent()
            guard !trimmedBody.isEmpty else {
                throw SocialError.api("Comment cannot be empty.")
            }

            let community = makeCourseCommunity(
                kind: .course,
                course: course,
                section: nil,
                semesterCode: nil,
                viewerID: viewer.id
            )
            try await ensureCourseCommunityMembership(community, viewerID: viewer.id)
            let communityID = community.id
            let communityRef = firestore.collection("courseCommunities").document(communityID)

            let comment = SocialCourseComment(
                id: UUID().uuidString,
                communityID: communityID,
                userID: viewer.id,
                username: viewer.username,
                displayName: viewer.displayName,
                body: trimmedBody,
                createdAt: nowISO()
            )

            try await setData(
                courseCommentData(comment),
                at: communityRef.collection("comments").document(comment.id)
            )
            try await updateData([
                "updatedAt": comment.createdAt,
                "memberIDs": FieldValue.arrayUnion([viewer.id])
            ], at: communityRef)

            courseCommentsByCommunityID[communityID] = try await loadCourseComments(communityRef: communityRef)
            courseCommunities = try await loadCourseCommunities(memberID: viewer.id)
            statusMessage = "Comment posted."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    func canDeleteCourseComment(_ comment: SocialCourseComment) -> Bool {
        currentUser?.id == comment.userID || canModerateSocialContent
    }

    func friendsSharingCourse(
        subject: String,
        number: String,
        semesterCode: String
    ) -> [SocialFriend] {
        let key = sharedCourseKey(subject: subject, number: number, semesterCode: semesterCode)
        return (overview?.friends ?? [])
            .filter { $0.shareSchedule && $0.sharedCourseKeys.contains(key) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func friendsSharingSection(
        course: Course,
        section: CourseSection,
        semesterCode: String
    ) -> [SocialFriend] {
        let key = sharedSectionKey(course: course, section: section, semesterCode: semesterCode)
        return (overview?.friends ?? [])
            .filter { $0.shareSchedule && $0.sharedSectionKeys.contains(key) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    func deleteCourseComment(for course: Course, comment: SocialCourseComment) async -> Bool {
        var didSucceed = false

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard canDeleteCourseComment(comment) else {
                throw SocialError.api("You cannot delete that comment.")
            }

            let communityRef = firestore.collection("courseCommunities").document(overallCourseCommunityID(for: course))
            try await deleteDocument(communityRef.collection("comments").document(comment.id))
            courseCommentsByCommunityID[overallCourseCommunityID(for: course)] = try await loadCourseComments(communityRef: communityRef)
            statusMessage = "Comment removed."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    func loadCourseResources(for community: SocialCourseCommunity) async -> [SocialCourseResource] {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser, community.memberIDs.contains(viewer.id) else { return [] }
        do {
            let snapshot = try await getDocuments(
                firestore.collection("courseCommunities")
                    .document(community.id)
                    .collection("resources")
                    .order(by: "createdAt", descending: false)
            )
            return snapshot.documents.compactMap(makeCourseResource)
        } catch {
            if !isPermissionDenied(error) {
                errorMessage = error.localizedDescription
            }
            return []
        }
#else
        return []
#endif
    }

    @discardableResult
    func addCourseResource(
        to community: SocialCourseCommunity,
        kind: String,
        title: String,
        url: String,
        notes: String
    ) async -> Bool {
        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var didSucceed = false

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanPostSocialContent()
            guard community.memberIDs.contains(viewer.id) else {
                throw SocialError.api("You are not part of that class group.")
            }
            guard !trimmedKind.isEmpty, !trimmedTitle.isEmpty else {
                throw SocialError.api("Pick a resource type and add a title.")
            }

            let resource = SocialCourseResource(
                id: UUID().uuidString,
                communityID: community.id,
                title: trimmedTitle,
                kind: trimmedKind,
                url: trimmedURL,
                notes: trimmedNotes,
                createdAt: nowISO(),
                createdByUserID: viewer.id,
                createdByDisplayName: viewer.displayName
            )

            try await setData(
                courseResourceData(resource),
                at: firestore.collection("courseCommunities")
                    .document(community.id)
                    .collection("resources")
                    .document(resource.id)
            )
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    func canDeleteCourseResource(_ resource: SocialCourseResource) -> Bool {
        currentUser?.id == resource.createdByUserID || canModerateSocialContent
    }

    @discardableResult
    func deleteCourseResource(_ resource: SocialCourseResource) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard canDeleteCourseResource(resource) else {
                throw SocialError.api("You cannot remove that resource.")
            }
            try await deleteDocument(
                firestore.collection("courseCommunities")
                    .document(resource.communityID)
                    .collection("resources")
                    .document(resource.id)
            )
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    func loadPollItems(for reference: SocialGroupChatReference) async -> [SocialGroupPollItem] {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser, reference.memberIDs.contains(viewer.id) else { return [] }
        do {
            try await ensureGroupChat(reference)
            let snapshot = try await getDocuments(
                firestore.collection("groupChats")
                    .document(reference.id)
                    .collection("polls")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 25)
            )
            return snapshot.documents.compactMap(makeGroupPoll).map { poll in
                makeGroupPollItem(poll, viewerID: viewer.id)
            }
        } catch {
            if !isPermissionDenied(error) {
                errorMessage = error.localizedDescription
            }
            return []
        }
#else
        return []
#endif
    }

    @discardableResult
    func createPoll(for reference: SocialGroupChatReference, question: String, options: [String]) async -> Bool {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var didSucceed = false

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanPostSocialContent()
            guard reference.memberIDs.contains(viewer.id) else {
                throw SocialError.api("You are not part of that group.")
            }
            guard !trimmedQuestion.isEmpty else {
                throw SocialError.api("Poll question cannot be empty.")
            }
            guard trimmedOptions.count >= 2 else {
                throw SocialError.api("Add at least two poll options.")
            }

            try await ensureGroupChat(reference)
            let poll = SocialGroupPoll(
                id: UUID().uuidString,
                threadID: reference.id,
                question: trimmedQuestion,
                options: trimmedOptions.map { SocialGroupPollOption(id: UUID().uuidString, title: $0) },
                votesByUserID: [:],
                createdAt: nowISO(),
                createdByUserID: viewer.id,
                createdByDisplayName: viewer.displayName,
                isClosed: false
            )
            try await setData(
                groupPollData(poll),
                at: firestore.collection("groupChats")
                    .document(reference.id)
                    .collection("polls")
                    .document(poll.id)
            )
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    @discardableResult
    func voteOnPoll(
        _ poll: SocialGroupPoll,
        in reference: SocialGroupChatReference,
        optionID: String?
    ) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            guard reference.memberIDs.contains(viewer.id) else {
                throw SocialError.api("You are not part of that group.")
            }

            let pollRef = firestore.collection("groupChats")
                .document(reference.id)
                .collection("polls")
                .document(poll.id)
            let snapshot = try await getDocument(pollRef)
            guard let existing = makeGroupPoll(from: snapshot) else {
                throw SocialError.api("That poll is no longer available.")
            }
            guard !existing.isClosed else {
                throw SocialError.api("That poll has already ended.")
            }

            // Write only this user's entry so concurrent votes never overwrite
            // each other (and so the rules can verify it).
            let voteField = FieldPath(["votesByUserID", viewer.id])
            let newVote: Any
            if let optionID,
               existing.options.contains(where: { $0.id == optionID }),
               existing.votesByUserID[viewer.id] != optionID {
                newVote = optionID
            } else {
                newVote = FieldValue.delete()
            }

            try await updateData([voteField: newVote], at: pollRef)
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    func canClosePoll(_ poll: SocialGroupPoll) -> Bool {
        currentUser?.id == poll.createdByUserID || canModerateSocialContent
    }

    @discardableResult
    func closePoll(_ poll: SocialGroupPoll, in reference: SocialGroupChatReference) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard canClosePoll(poll) else {
                throw SocialError.api("You cannot end that poll.")
            }
            try await updateData([
                "isClosed": true
            ], at: firestore.collection("groupChats")
                .document(reference.id)
                .collection("polls")
                .document(poll.id))
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    func chatReference(for group: SocialFriendGroup) -> SocialGroupChatReference? {
        guard let currentUser else { return nil }
        let memberIDs = Array(Set(group.memberIDs + [group.ownerID])).sorted()
        let friendNames = Dictionary(uniqueKeysWithValues: (overview?.friends ?? []).map { ($0.id, $0.displayName) })
        let memberDisplayNames = memberIDs.compactMap { memberID -> String? in
            if memberID == currentUser.id {
                return currentUser.displayName
            }
            return friendNames[memberID]
        }
        return SocialGroupChatReference(
            id: "manualGroup_\(group.id)",
            title: group.name,
            subtitle: "\(memberIDs.count) members",
            memberDisplayNames: memberDisplayNames,
            memberIDs: memberIDs,
            sourceKind: .manualGroup
        )
    }

    /// Finds the chat a notification refers to.
    func chatReference(forThreadID threadID: String) -> SocialGroupChatReference? {
        if threadID == campusWideGroupThreadID {
            return campusWideChatReference
        }
        if threadID.hasPrefix("manualGroup_") {
            let groupID = String(threadID.dropFirst("manualGroup_".count))
            return friendGroups.first { $0.id == groupID }.flatMap(chatReference(for:))
        }
        if threadID.hasPrefix("classGroup_") {
            let communityID = String(threadID.dropFirst("classGroup_".count))
            return courseCommunities.first { $0.id == communityID }.map(chatReference(for:))
        }
        return (overview?.friends ?? [])
            .lazy
            .compactMap(directMessageReference(with:))
            .first { $0.id == threadID }
    }

    func directMessageReference(with friend: SocialFriend) -> SocialGroupChatReference? {
        guard let currentUser, currentUser.id != friend.id else { return nil }
        let memberIDs = [currentUser.id, friend.id].sorted()
        let stableMembers = memberIDs
            .map { "\($0.utf8.count)-\($0)" }
            .joined(separator: "_")

        return SocialGroupChatReference(
            id: "directMessage_\(stableMembers)",
            title: friend.displayName,
            subtitle: "@\(friend.username)",
            memberDisplayNames: [currentUser.displayName, friend.displayName],
            memberIDs: memberIDs,
            sourceKind: .directMessage
        )
    }

    func chatReference(for community: SocialCourseCommunity) -> SocialGroupChatReference {
        let friendNames = Dictionary(uniqueKeysWithValues: (overview?.friends ?? []).map { ($0.id, $0.displayName) })
        let memberDisplayNames = community.memberIDs.compactMap { memberID -> String? in
            if memberID == currentUser?.id {
                return currentUser?.displayName
            }
            return friendNames[memberID]
        }
        return SocialGroupChatReference(
            id: "classGroup_\(community.id)",
            title: community.kind == .course ? community.courseTitle : "\(community.courseTitle) • \(community.sectionLabel ?? "Section")",
            subtitle: community.kind == .course
                ? "\(community.courseSubject) \(community.courseNumber)"
                : community.sectionLabel ?? "\(community.courseSubject) \(community.courseNumber)",
            memberDisplayNames: memberDisplayNames,
            memberIDs: community.memberIDs,
            sourceKind: .classGroup
        )
    }

    func loadGroupChatMessages(for reference: SocialGroupChatReference) async -> [SocialGroupChatMessage] {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser, reference.memberIDs.contains(viewer.id) else {
            return []
        }

        do {
            try await ensureGroupChat(reference)
            let snapshot = try await getDocuments(
                firestore.collection("groupChats")
                    .document(reference.id)
                    .collection("messages")
                    .order(by: "createdAt", descending: false)
                    .limit(toLast: 200)
            )
            let messages = snapshot.documents.compactMap(makeGroupChatMessage)
            updateGroupChatThreadState(for: reference, messages: messages)
            return messages
        } catch {
            if !isPermissionDenied(error) {
                errorMessage = error.localizedDescription
            }
            return []
        }
#else
        return []
#endif
    }

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    func observeGroupChatMessages(
        for reference: SocialGroupChatReference,
        onChange: @escaping @MainActor ([SocialGroupChatMessage]) -> Void
    ) async -> ListenerRegistration? {
        guard let viewer = currentUser, reference.memberIDs.contains(viewer.id) else {
            return nil
        }

        do {
            try await ensureGroupChat(reference)
            return firestore.collection("groupChats")
                .document(reference.id)
                .collection("messages")
                .order(by: "createdAt", descending: false)
                .limit(toLast: 200)
                .addSnapshotListener { [weak self] snapshot, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error {
                            if !self.isPermissionDenied(error) {
                                self.errorMessage = error.localizedDescription
                            }
                            return
                        }

                        let messages = snapshot?.documents.compactMap(self.makeGroupChatMessage) ?? []
                        self.updateGroupChatThreadState(for: reference, messages: messages)
                        onChange(messages)
                    }
                }
        } catch {
            if !isPermissionDenied(error) {
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }
#endif

    @discardableResult
    func sendGroupChatMessage(for reference: SocialGroupChatReference, body: String) async -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var didSucceed = false

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanPostSocialContent()
            guard !trimmedBody.isEmpty else {
                throw SocialError.api("Message cannot be empty.")
            }
            guard reference.memberIDs.contains(viewer.id) else {
                throw SocialError.api("You are not part of that group.")
            }

            try await ensureGroupChat(reference)
            let message = SocialGroupChatMessage(
                id: UUID().uuidString,
                threadID: reference.id,
                userID: viewer.id,
                username: viewer.username,
                displayName: viewer.displayName,
                body: trimmedBody,
                createdAt: nowISO()
            )

            let threadRef = firestore.collection("groupChats").document(reference.id)
            try await setData(groupChatMessageData(message), at: threadRef.collection("messages").document(message.id))
            try await updateData([
                "updatedAt": message.createdAt,
                "lastMessageID": message.id,
                "lastSenderID": viewer.id,
                "memberIDs": reference.memberIDs,
                "title": reference.title,
                "subtitle": reference.subtitle,
                "sourceKind": reference.sourceKind.rawValue,
            ], at: threadRef)

            groupChatThreadStates[reference.id] = GroupChatThreadState(
                updatedAt: message.createdAt,
                latestMessageID: message.id,
                lastSenderID: viewer.id
            )
            markGroupChatSeen(
                reference,
                latestMessageID: message.id,
                latestMessageAt: message.createdAt
            )

            didSucceed = true

            // The message is saved. Notifying members is best effort and must
            // not delay the send or report it as failed.
            if reference.sourceKind != .campusGroup {
                let senderName = viewer.displayName
                Task { [weak self] in
                    await self?.notifyMembers(of: message, in: reference, senderName: senderName)
                }
            }
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    @discardableResult
    func deleteGroupChatMessage(_ message: SocialGroupChatMessage, in reference: SocialGroupChatReference) async -> Bool {
        var didSucceed = false

        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard canDeleteGroupChatMessage(message) else {
                throw SocialError.api("You cannot delete that message.")
            }

            let threadRef = firestore.collection("groupChats").document(reference.id)
            let messagesRef = threadRef.collection("messages")
            try await deleteDocument(messagesRef.document(message.id))

            let latestSnapshot = try await getDocuments(
                messagesRef
                    .order(by: "createdAt", descending: true)
                    .limit(to: 1)
            )

            if let latestDocument = latestSnapshot.documents.first,
               let latestMessage = makeGroupChatMessage(from: latestDocument) {
                try await updateData([
                    "updatedAt": latestMessage.createdAt,
                    "lastMessageID": latestMessage.id,
                    "lastSenderID": latestMessage.userID,
                ], at: threadRef)
                groupChatThreadStates[reference.id] = GroupChatThreadState(
                    updatedAt: latestMessage.createdAt,
                    latestMessageID: latestMessage.id,
                    lastSenderID: latestMessage.userID
                )
            } else {
                try await updateData([
                    "updatedAt": nowISO(),
                    "lastMessageID": NSNull(),
                    "lastSenderID": NSNull(),
                ], at: threadRef)
                groupChatThreadStates.removeValue(forKey: reference.id)
            }

            statusMessage = "Message removed."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
    }

    /// Pushes a new message through the relay, falling back to a social alert
    /// (delivered by the Cloud Function) when the relay is unavailable.
    private func notifyMembers(
        of message: SocialGroupChatMessage,
        in reference: SocialGroupChatReference,
        senderName: String
    ) async {
        let deliveredViaRelay = (try? await triggerGroupChatPushIfPossible(for: reference, message: message)) ?? false
        guard !deliveredViaRelay else { return }

        do {
            try await sendSocialAlert(
                to: reference.memberIDs,
                type: "groupMessage",
                title: reference.sourceKind == .directMessage ? senderName : reference.title,
                body: reference.sourceKind == .directMessage
                    ? message.body
                    : "\(senderName): \(message.body)",
                eventDate: nil,
                contextID: reference.id
            )
        } catch {
            #if DEBUG
            print("Chat notification failed:", error.localizedDescription)
            #endif
        }
    }

    private func triggerGroupChatPushIfPossible(
        for reference: SocialGroupChatReference,
        message: SocialGroupChatMessage
    ) async throws -> Bool {
        guard let relayEndpoint = chatPushRelayEndpoint else {
            return false
        }

        let idToken = try await currentAuthToken()
        var request = URLRequest(url: relayEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(
            GroupChatPushRelayRequest(
                threadID: reference.id,
                messageID: message.id,
                messageBody: message.body,
                threadTitle: reference.sourceKind == .directMessage
                    ? message.displayName
                    : reference.title
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SocialError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SocialError.api("Push relay request failed.")
        }

        if let relayResponse = try? JSONDecoder().decode(GroupChatPushRelayResponse.self, from: data) {
            return relayResponse.delivered > 0
        }

        return false
    }

    private var chatPushRelayEndpoint: URL? {
        let normalizedBase = Self.defaultChatPushRelayBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: normalizedBase) else {
            return nil
        }

        return baseURL.appendingPathComponent("api/push/group-message")
    }

    private struct GroupChatPushRelayRequest: Encodable {
        let threadID: String
        let messageID: String
        let messageBody: String
        let threadTitle: String
    }

    private struct GroupChatPushRelayResponse: Decodable {
        let delivered: Int
    }

    @discardableResult
    func createFeedPost(
        title: String,
        location: String,
        details: String,
        startsAt: Date,
        visibility: SocialFeedVisibility,
        groupIDs: [String]
    ) async -> Bool {
        var didSucceed = false
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            try await assertCurrentUserCanPostSocialContent()
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty else {
                throw SocialError.api("Give your plan a title.")
            }
            let sanitizedGroupIDs = Array(Set(groupIDs)).sorted()
            if visibility == .groups && sanitizedGroupIDs.isEmpty {
                throw SocialError.api("Choose at least one group.")
            }

            let snapshot = try await getDocument(firestore.collection("users").document(viewer.id))
            let data = snapshot.data() ?? [:]
            var posts = decodeFeedPosts(from: data)
            let createdPost = SocialFeedPost(
                id: UUID().uuidString,
                ownerID: viewer.id,
                ownerUsername: viewer.username,
                ownerDisplayName: viewer.displayName,
                title: normalizedTitle,
                location: normalizedLocation,
                details: normalizedDetails,
                createdAt: nowISO(),
                startsAt: ISO8601DateFormatter().string(from: startsAt),
                endedAt: nil,
                visibility: visibility,
                visibleGroupIDs: sanitizedGroupIDs
            )
            posts.insert(createdPost, at: 0)
            posts = Array(posts.prefix(40))

            try await updateData([
                "feedPosts": posts.map(feedPostData),
                "lastFeedPostAt": posts.first?.createdAt ?? nowISO(),
            ], at: firestore.collection("users").document(viewer.id))

            let recipients = try await recipientIDsForFeedPost(
                ownerID: viewer.id,
                visibility: visibility,
                visibleGroupIDs: sanitizedGroupIDs
            )
            try await sendSocialAlert(
                to: recipients,
                type: "feedPost",
                title: "\(viewer.displayName) posted a plan",
                body: normalizedLocation.isEmpty
                    ? "\(normalizedTitle) is up on the campus feed."
                    : "\(normalizedTitle) at \(normalizedLocation).",
                eventDate: startsAt
            )

            try await refreshOverviewInternal()
            statusMessage = "Plan posted."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func endFeedPost(_ post: SocialFeedPost) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let targetOwnerID = post.ownerID
            guard targetOwnerID == viewer.id || canModerateSocialContent else {
                throw SocialError.api("You can’t end that plan.")
            }

            let snapshot = try await getDocument(firestore.collection("users").document(targetOwnerID))
            let data = snapshot.data() ?? [:]
            let posts = decodeFeedPosts(from: data)
            var didUpdate = false
            let updatedPosts = posts.map { existingPost -> SocialFeedPost in
                guard existingPost.id == post.id, existingPost.ownerID == targetOwnerID, existingPost.endedAt == nil else {
                    return existingPost
                }
                didUpdate = true
                return SocialFeedPost(
                    id: existingPost.id,
                    ownerID: existingPost.ownerID,
                    ownerUsername: existingPost.ownerUsername,
                    ownerDisplayName: existingPost.ownerDisplayName,
                    title: existingPost.title,
                    location: existingPost.location,
                    details: existingPost.details,
                    createdAt: existingPost.createdAt,
                    startsAt: existingPost.startsAt,
                    endedAt: nowISO(),
                    visibility: existingPost.visibility,
                    visibleGroupIDs: existingPost.visibleGroupIDs
                )
            }

            guard didUpdate else {
                throw SocialError.api("That plan isn’t available anymore.")
            }

            try await updateData([
                "feedPosts": updatedPosts.map(feedPostData),
                "lastFeedPostAt": updatedPosts.first?.createdAt ?? "",
            ], at: firestore.collection("users").document(targetOwnerID))

            try await refreshOverviewInternal()
            statusMessage = "Plan ended."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func deleteFeedPost(_ postID: String) async -> Bool {
        var didSucceed = false
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let snapshot = try await getDocument(firestore.collection("users").document(viewer.id))
            let data = snapshot.data() ?? [:]
            let posts = decodeFeedPosts(from: data)
            guard posts.contains(where: { $0.id == postID && $0.ownerID == viewer.id }) else {
                throw SocialError.api("That plan isn’t available anymore.")
            }

            let updatedPosts = posts.filter { $0.id != postID }
            var payload: [AnyHashable: Any] = [
                "feedPosts": updatedPosts.map(feedPostData)
            ]
            if let latest = updatedPosts.first?.createdAt, !latest.isEmpty {
                payload["lastFeedPostAt"] = latest
            } else {
                payload["lastFeedPostAt"] = FieldValue.delete()
            }
            try await updateData(payload, at: firestore.collection("users").document(viewer.id))

            try await refreshOverviewInternal()
            statusMessage = "Plan deleted."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    @discardableResult
    func setFeedPresence(postID: String, status: SocialFeedPresenceStatus?) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let snapshot = try await getDocument(firestore.collection("users").document(viewer.id))
            let data = snapshot.data() ?? [:]
            var responses = decodeFeedResponses(from: data)
            responses.removeAll { $0.postID == postID && $0.userID == viewer.id }

            if let status {
                responses.append(
                    SocialFeedPresence(
                        postID: postID,
                        userID: viewer.id,
                        username: viewer.username,
                        displayName: viewer.displayName,
                        status: status,
                        respondedAt: nowISO()
                    )
                )
            }

            try await updateData([
                "feedResponses": responses.map(feedResponseData)
            ], at: firestore.collection("users").document(viewer.id))

            try await refreshOverviewInternal()
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
    }

    func unfriend(_ friendID: String) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let friendshipRef = firestore.collection("friendships").document(canonicalFriendshipID(viewer.id, friendID))
            try await deleteDocument(friendshipRef)
            friendScheduleCacheByFriendID.removeValue(forKey: friendID)

            // Stop sharing with them right away rather than on the next sync.
            try? await deleteDocument(friendViewReference(ownerID: viewer.id, viewerID: friendID))
            try? await updateData(
                ["viewerIDs": FieldValue.arrayRemove([viewer.id])],
                at: firestore.collection("locationShares").document(friendID)
            )
            try await refreshOverviewInternal()
            statusMessage = "Friend removed."
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func updateShareSettings(shareSchedule: Bool, shareLocation: Bool) async {
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let ref = firestore.collection("users").document(viewer.id)
            try await updateData([
                "shareSchedule": shareSchedule,
                "shareLocation": shareLocation,
            ], at: ref)

            var updated = viewer
            updated = SocialUser(
                id: viewer.id,
                username: viewer.username,
                displayName: viewer.displayName,
                email: viewer.email,
                isGuest: viewer.isGuest,
                shareSchedule: shareSchedule,
                shareLocation: shareLocation,
                createdAt: viewer.createdAt,
                lastScheduleAt: viewer.lastScheduleAt,
                sharedCourseKeys: viewer.sharedCourseKeys,
                sharedSectionKeys: viewer.sharedSectionKeys
            )
            currentUser = updated
            try await refreshOverviewInternal()
            if viewer.shareSchedule != shareSchedule {
                // Publishes the schedule, or removes every published copy.
                try await publishSharedSchedule(force: true)
                statusMessage = shareSchedule ? "Schedule sharing enabled." : "Schedule sharing disabled."
            }
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    /// Mirrors location sharing on the public profile so friends can tell
    /// "not sharing" apart from "no recent update".
    func setShareLocationFlag(_ isSharing: Bool) async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser, viewer.shareLocation != isSharing else { return }
        do {
            try await updateData(["shareLocation": isSharing], at: firestore.collection("users").document(viewer.id))
            currentUser = SocialUser(
                id: viewer.id,
                username: viewer.username,
                displayName: viewer.displayName,
                email: viewer.email,
                isGuest: viewer.isGuest,
                shareSchedule: viewer.shareSchedule,
                shareLocation: isSharing,
                createdAt: viewer.createdAt,
                lastScheduleAt: viewer.lastScheduleAt,
                sharedCourseKeys: viewer.sharedCourseKeys,
                sharedSectionKeys: viewer.sharedSectionKeys
            )
        } catch {
            #if DEBUG
            print("⚠️ Could not update shareLocation:", error)
            #endif
        }
#endif
    }

    func sharePersonalEvents(_ events: [StoredPersonalEvent]) async {
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let filteredEvents = events.filter { $0.shareMode != .none }
            guard !filteredEvents.isEmpty else { return }

            let groups = try await loadFriendGroups(ownerID: viewer.id)
            let recipients = recipientIDsForSharedEvents(filteredEvents, groups: groups)
            guard !recipients.isEmpty else { return }

            for recipientID in recipients {
                for event in filteredEvents {
                    let sharedEvent = makeReceivedSharedCalendarEvent(from: event, owner: viewer)
                    try await setData(
                        sharedCalendarEventData(sharedEvent),
                        at: firestore.collection("users")
                            .document(recipientID)
                            .collection("calendarShares")
                            .document(sharedEvent.id)
                    )
                }
            }

            let summaryBody: String
            if filteredEvents.count == 1, let first = filteredEvents.first {
                let timeText = DateFormatter.localizedString(from: first.startDate, dateStyle: .medium, timeStyle: .short)
                summaryBody = "\(first.title) on \(timeText)."
            } else {
                summaryBody = "\(filteredEvents.count) shared calendar events were sent to you."
            }

            try await sendSocialAlert(
                to: recipients,
                type: "sharedEvent",
                title: "\(viewer.displayName) shared a calendar event",
                body: summaryBody,
                eventDate: filteredEvents.map(\.startDate).min()
            )
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    /// Registers the calendar that friends see. Any change to it is
    /// republished a few seconds later, whichever tab is open.
    func attachScheduleSource(_ calendarViewModel: CalendarViewModel) {
        guard scheduleSource !== calendarViewModel else { return }
        scheduleSource = calendarViewModel
        scheduleSourceCancellable = calendarViewModel.shareableContentDidChange
            .debounce(for: .seconds(4), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.requestScheduleSync()
            }
        requestScheduleSync()
    }

    /// Coalesces publish requests. Unchanged schedules cost no writes, so
    /// callers can ask freely (app launch, foreground, background refresh).
    func requestScheduleSync(force: Bool = false) {
        if force {
            scheduleSyncForceRequested = true
        }
        guard !scheduleSyncInFlight else {
            scheduleSyncPending = true
            return
        }

        scheduleSyncInFlight = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.scheduleSyncPending = false
                let forceNow = self.scheduleSyncForceRequested
                self.scheduleSyncForceRequested = false
                // Class groups follow enrollments whether or not the
                // schedule itself is shared.
                if self.currentUser != nil, let source = self.scheduleSource {
                    await self.syncCourseCommunities(for: source.enrolledCourses)
                }
                await self.publishSharedScheduleIfNeeded(force: forceNow)
            } while self.scheduleSyncPending
            self.scheduleSyncInFlight = false
        }
    }

    /// Kept for explicit "Sync now" actions and older call sites.
    func syncSchedule(from calendarViewModel: CalendarViewModel) async {
        attachScheduleSource(calendarViewModel)
        await runOperation(showSpinner: false) {
            try await publishSharedSchedule(force: true)
        }
    }

    /// Background app refresh: wait for the signed-in session to restore,
    /// then republish the schedule if anything changed or it is due.
    func performBackgroundRefresh() async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard FirebaseApp.app() != nil else { return }
        for _ in 0..<40 where currentUser == nil && Auth.auth().currentUser != nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await publishSharedScheduleIfNeeded()
#endif
    }

    /// Publishes (or clears) this user's friend-visible schedule. Background
    /// callers must not overwrite status messages the user is reading.
    func publishSharedScheduleIfNeeded(force: Bool = false) async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard currentUser != nil, FirebaseApp.app() != nil else { return }
        do {
            try await publishSharedSchedule(force: force)
        } catch {
            #if DEBUG
            print("⚠️ Shared schedule publish failed:", error)
            #endif
        }
#endif
    }

    func cachedFriendSchedule(for friend: SocialFriend) -> FriendScheduleResponse? {
        guard let cached = friendScheduleCacheByFriendID[friend.id],
              cached.owner.lastScheduleAt == friend.lastScheduleAt else {
            return nil
        }
        return cached
    }

    func preloadFriendSchedulesForActivity() async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser else { return }
        let viewerID = viewer.id
        let targets = (overview?.friends ?? []).filter { friend in
            friend.canViewSchedule && friend.shareSchedule && cachedFriendSchedule(for: friend) == nil
        }
        guard !targets.isEmpty else { return }

        // Load in parallel; each friend's document is independent.
        await withTaskGroup(of: (SocialFriend, SharedScheduleSnapshot?).self) { group in
            for friend in targets {
                group.addTask { [weak self] in
                    // Activity is supplementary; a friend's full schedule still has its own retry UI.
                    let schedule = try? await self?.loadScheduleSnapshot(ownerID: friend.id, viewerID: viewerID)
                    return (friend, schedule)
                }
            }

            for await (friend, schedule) in group {
                guard let schedule, !Task.isCancelled else { continue }
                friendScheduleCacheByFriendID[friend.id] = FriendScheduleResponse(
                    owner: socialUser(from: friend),
                    schedule: schedule
                )
            }
        }
#endif
    }

    private func socialUser(from friend: SocialFriend) -> SocialUser {
        SocialUser(
            id: friend.id,
            username: friend.username,
            displayName: friend.displayName,
            email: friend.email,
            isGuest: friend.isGuest,
            shareSchedule: friend.shareSchedule,
            shareLocation: friend.shareLocation,
            createdAt: friend.createdAt,
            lastScheduleAt: friend.lastScheduleAt,
            sharedCourseKeys: friend.sharedCourseKeys,
            sharedSectionKeys: friend.sharedSectionKeys
        )
    }

    /// The cached schedule for a friend regardless of freshness, for places
    /// (like the live map) that can show slightly older data.
    func anyCachedFriendSchedule(friendID: String) -> FriendScheduleResponse? {
        friendScheduleCacheByFriendID[friendID]
    }

    @discardableResult
    func loadFriendSchedule(friendID: String) async -> FriendScheduleResponse? {
        loadedFriendSchedule = nil
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            guard let friend = overview?.friends.first(where: { $0.id == friendID }) else {
                throw SocialError.api("You are not friends with that user.")
            }
            guard friend.canViewSchedule, friend.shareSchedule else {
                throw SocialError.api("That user is not sharing their schedule.")
            }

            if let cached = cachedFriendSchedule(for: friend) {
                loadedFriendSchedule = cached
                return
            }

            let owner = SocialUser(
                id: friend.id,
                username: friend.username,
                displayName: friend.displayName,
                email: friend.email,
                isGuest: friend.isGuest,
                shareSchedule: friend.shareSchedule,
                shareLocation: friend.shareLocation,
                createdAt: friend.createdAt,
                lastScheduleAt: friend.lastScheduleAt,
                sharedCourseKeys: friend.sharedCourseKeys,
                sharedSectionKeys: friend.sharedSectionKeys
            )

            let schedule = try await loadScheduleSnapshot(ownerID: friendID, viewerID: viewer.id)
            let response = FriendScheduleResponse(owner: owner, schedule: schedule)
            friendScheduleCacheByFriendID[friendID] = response
            loadedFriendSchedule = response
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return loadedFriendSchedule
    }

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var firestore: Firestore { Firestore.firestore() }

    #if canImport(FirebaseCore)
    private struct SecondaryFirebaseContext {
        let auth: Auth
        let firestore: Firestore
    }
    #endif

    private func bootstrapFirebaseSession() async {
        // Firebase configuration can land slightly after SocialManager init in the SwiftUI lifecycle.
        if FirebaseApp.app() == nil {
            for _ in 0..<20 where FirebaseApp.app() == nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        guard FirebaseApp.app() != nil else { return }
        setupMessage = "Firebase is configured."
        attachAuthStateListenerIfNeeded()
        try? await refreshAuthTokenIfNeeded()
        await refreshModeratorClaim()
        await restoreSessionIfNeeded()
    }

    private func attachAuthStateListenerIfNeeded() {
        guard authStateListenerHandle == nil else { return }

        authStateListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard user != nil else {
                    self.detachRealtimeListeners()
                    self.clearLocalSharedCalendarEvents()
                    self.canModerateSocialContent = false
                    self.currentUser = nil
                    self.overview = nil
                    self.friendGroups = []
                    self.courseCommunities = []
                    self.courseCommentsByCommunityID = [:]
                    self.feedItems = []
                    self.searchResults = []
                    self.quickAddSuggestions = []
                    self.loadedFriendSchedule = nil
                    return
                }

                await self.refreshModeratorClaim()
                guard self.currentUser == nil || self.overview == nil else { return }

                do {
                    try await self.refreshOverviewInternal()
                } catch {
                    let recovered = await self.handlePermissionErrorIfNeeded(error)
                    if !recovered {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func restoreSessionIfNeeded() async {
        guard Auth.auth().currentUser != nil else { return }
        await runOperation(showSpinner: false) {
            let user = try await fetchOrCreateProfileForCurrentUser()
            currentUser = user
            try await refreshOverviewInternal()
        }
    }

    private func refreshOverviewInternal() async throws {
        guard let viewer = try await fetchOrCreateProfileForCurrentUser() else {
            detachRealtimeListeners()
            throw SocialError.notAuthenticated
        }
        currentUser = viewer
        attachRealtimeListenersIfNeeded(for: viewer.id)
        if blockedUsersLoadedFor != viewer.id {
            await loadBlockedUsers(viewerID: viewer.id)
        }

        let friendshipsSnapshot = try await getDocuments(
            firestore.collection("friendships").whereField("members", arrayContains: viewer.id)
        )
        let friendIDs = friendshipsSnapshot.documents.compactMap { snapshot -> String? in
            let members = snapshot.data()["members"] as? [String] ?? []
            return members.first(where: { $0 != viewer.id })
        }
        let friendSnapshots = try await fetchUserSnapshots(ids: friendIDs)

        let friends = friendSnapshots.values
            .compactMap { snapshot -> (SocialUser, Int)? in
                guard let user = makeUser(from: snapshot) else { return nil }
                let itemCount = snapshot.data()?["sharedScheduleItemCount"] as? Int ?? 0
                return (user, itemCount)
            }
            .sorted { $0.0.displayName.localizedCaseInsensitiveCompare($1.0.displayName) == .orderedAscending }
            .map { user, itemCount in
                SocialFriend(
                    id: user.id,
                    username: user.username,
                    displayName: user.displayName,
                    email: user.email,
                    isGuest: user.isGuest,
                    shareSchedule: user.shareSchedule,
                    shareLocation: user.shareLocation,
                    createdAt: user.createdAt,
                    lastScheduleAt: user.lastScheduleAt,
                    canViewSchedule: user.shareSchedule,
                    schedulePreviewCount: itemCount,
                    sharedCourseKeys: user.sharedCourseKeys,
                    sharedSectionKeys: user.sharedSectionKeys
                )
            }

        // A new friend has no copy of this user's schedule until it is
        // republished, so do that right away instead of on the next edit.
        let currentFriendIDs = Set(friendIDs)
        if let lastKnownFriendIDs, lastKnownFriendIDs != currentFriendIDs {
            requestScheduleSync()
        }
        for friendID in friendScheduleCacheByFriendID.keys where !currentFriendIDs.contains(friendID) {
            friendScheduleCacheByFriendID.removeValue(forKey: friendID)
        }

        let incomingSnapshot = try await getDocuments(
            firestore.collection("friendRequests")
                .whereField("toUserID", isEqualTo: viewer.id)
                .whereField("status", isEqualTo: "pending")
        )
        let outgoingSnapshot = try await getDocuments(
            firestore.collection("friendRequests")
                .whereField("fromUserID", isEqualTo: viewer.id)
                .whereField("status", isEqualTo: "pending")
        )

        let incoming = try await makeRequestSummaries(from: incomingSnapshot.documents)
        let outgoing = try await makeRequestSummaries(from: outgoingSnapshot.documents)

        do {
            var visibleGroups = try await loadVisibleFriendGroups(viewerID: viewer.id)
            if try await migrateLegacyFriendGroupsIfNeeded(
                ownerID: viewer.id,
                visibleGroups: visibleGroups
            ) {
                visibleGroups = try await loadVisibleFriendGroups(viewerID: viewer.id)
            }
            friendGroups = visibleGroups
        } catch {
            if isPermissionDenied(error) {
                friendGroups = []
            } else {
                throw error
            }
        }

        do {
            courseCommunities = try await loadCourseCommunities(memberID: viewer.id)
        } catch {
            if isPermissionDenied(error) {
                courseCommunities = []
            } else {
                throw error
            }
        }

        do {
            feedItems = try await loadFeedItems(friendOwnerIDs: friendIDs)
                .filter { !blockedUserIDs.contains($0.post.ownerID) }
        } catch {
            if isPermissionDenied(error) {
                feedItems = []
            } else {
                throw error
            }
        }

        do {
            groupChatThreadStates = try await loadGroupChatThreadStates(memberID: viewer.id)
        } catch {
            if isPermissionDenied(error) {
                groupChatThreadStates = [:]
            } else {
                throw error
            }
        }

        overview = SocialOverviewResponse(
            viewer: viewer,
            friends: friends,
            incomingRequests: incoming,
            outgoingRequests: outgoing
        )
    }

    private func attachRealtimeListenersIfNeeded(for userID: String) {
        guard activeListenerUserID != userID || listenerRegistrations.isEmpty else { return }

        detachRealtimeListeners()
        activeListenerUserID = userID

        listenerRegistrations = [
            firestore.collection("users").document(userID).addSnapshotListener { [weak self] _, error in
                self?.handleRealtimeEvent(error: error)
            },
            firestore.collection("friendRequests")
                .whereField("toUserID", isEqualTo: userID)
                .whereField("status", isEqualTo: "pending")
                .addSnapshotListener { [weak self] _, error in
                    self?.handleRealtimeEvent(error: error)
                },
            firestore.collection("friendRequests")
                .whereField("fromUserID", isEqualTo: userID)
                .whereField("status", isEqualTo: "pending")
                .addSnapshotListener { [weak self] _, error in
                    self?.handleRealtimeEvent(error: error)
                },
            firestore.collection("friendships")
                .whereField("members", arrayContains: userID)
                .addSnapshotListener { [weak self] _, error in
                    self?.handleRealtimeEvent(error: error)
                },
            firestore.collection("groupChats")
                .whereField("memberIDs", arrayContains: userID)
                .addSnapshotListener { [weak self] snapshot, error in
                    self?.handleGroupChatThreadsListener(snapshot: snapshot, error: error)
                },
            firestore.collection("groupChats")
                .document(campusWideGroupThreadID)
                .addSnapshotListener { [weak self] snapshot, error in
                    self?.handleCampusWideChatThreadListener(snapshot: snapshot, error: error)
                },
            firestore.collection("users")
                .document(userID)
                .collection("calendarShares")
                .addSnapshotListener { [weak self] snapshot, error in
                    self?.handleSharedCalendarListener(snapshot: snapshot, error: error)
                },
            firestore.collection("users")
                .document(userID)
                .collection("socialNotifications")
                .addSnapshotListener { [weak self] snapshot, error in
                    self?.handleSocialAlertsListener(snapshot: snapshot, error: error)
                },
        ]
    }

    private func detachRealtimeListeners() {
        listenerRegistrations.forEach { $0.remove() }
        listenerRegistrations = []
        realtimeMemberGroupChatIDs = []
        activeListenerUserID = nil
    }

    private func handleGroupChatThreadsListener(snapshot: QuerySnapshot?, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                if !self.isPermissionDenied(error) {
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            let documents = snapshot?.documents ?? []
            let incomingIDs = Set(documents.map(\.documentID))
            for removedID in self.realtimeMemberGroupChatIDs.subtracting(incomingIDs)
                where removedID != self.campusWideGroupThreadID {
                self.groupChatThreadStates.removeValue(forKey: removedID)
            }
            self.realtimeMemberGroupChatIDs = incomingIDs

            for document in documents {
                if let state = self.makeGroupChatThreadState(from: document.data()) {
                    self.groupChatThreadStates[document.documentID] = state
                } else {
                    self.groupChatThreadStates.removeValue(forKey: document.documentID)
                }
            }
        }
    }

    private func handleCampusWideChatThreadListener(snapshot: DocumentSnapshot?, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                if !self.isPermissionDenied(error) {
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            if let data = snapshot?.data(),
               let state = self.makeGroupChatThreadState(from: data) {
                self.groupChatThreadStates[self.campusWideGroupThreadID] = state
            } else {
                self.groupChatThreadStates.removeValue(forKey: self.campusWideGroupThreadID)
            }
        }
    }

    private func handleRealtimeEvent(error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                let recovered = await self.handlePermissionErrorIfNeeded(error)
                if !recovered {
                    self.errorMessage = error.localizedDescription
                }
                return
            }
            self.scheduleOverviewRefresh()
        }
    }

    /// Several listeners fire together (sign-in, a new friendship updates
    /// both the request and friendship queries). Coalesce them into one
    /// overview reload.
    private func scheduleOverviewRefresh() {
        overviewRefreshTask?.cancel()
        overviewRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.refreshOverviewInternal()
            } catch {
                let recovered = await self.handlePermissionErrorIfNeeded(error)
                if !recovered {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleSharedCalendarListener(snapshot: QuerySnapshot?, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                if !self.isPermissionDenied(error) {
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            let events = (snapshot?.documents ?? []).compactMap(self.makeReceivedSharedCalendarEvent)
            self.persistReceivedSharedCalendarEvents(events)
        }
    }

    private func handleSocialAlertsListener(snapshot: QuerySnapshot?, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                if !self.isPermissionDenied(error) {
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            let alerts = (snapshot?.documents ?? []).compactMap(self.makeSocialAlert)
            self.processIncomingSocialAlerts(alerts)
        }
    }

    @discardableResult
    private func handlePermissionErrorIfNeeded(_ error: Error) async -> Bool {
        guard isPermissionDenied(error) else { return false }

        if permissionRecoveryInFlight {
            errorMessage = "Social access was denied. Pull to retry or sign in again."
            return true
        }

        detachRealtimeListeners()
        permissionRecoveryInFlight = true
        defer { permissionRecoveryInFlight = false }
        let preservedUser = currentUser
        let preservedOverview = overview
        let preservedGroups = friendGroups
        let preservedCourseCommunities = courseCommunities
        let preservedFeed = feedItems

        do {
            try await refreshAuthTokenIfNeeded(forceRefresh: true)
            try await refreshOverviewInternal()
            errorMessage = nil
            statusMessage = "Social connection restored."
        } catch {
            currentUser = preservedUser ?? currentUser
            overview = preservedOverview
            friendGroups = preservedGroups
            courseCommunities = preservedCourseCommunities
            feedItems = preservedFeed
            errorMessage = "Social access was denied. Pull to retry. If it keeps happening, refresh Firestore rules or sign in again."
        }
        return true
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "FIRFirestoreErrorDomain",
           nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("missing or insufficient permissions") || message.contains("permission denied")
    }

    private func refreshAuthTokenIfNeeded(forceRefresh: Bool = false) async throws {
        _ = try await currentAuthToken(forceRefresh: forceRefresh)
    }

    private func currentAuthToken(forceRefresh: Bool = false) async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw SocialError.notAuthenticated
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            user.getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func handleCurrentUserChange(previousUserID: String?, currentUserID: String?) async {
        guard previousUserID != currentUserID else {
            if currentUserID != nil {
                await syncPushRegistrationIfPossible()
            }
            return
        }

        if let previousUserID {
            await unregisterPushRegistration(for: previousUserID)
        }

        NotificationManager.setActiveSocialContextID(nil)

        guard currentUserID != nil else { return }
        NotificationManager.registerForRemoteNotificationsIfAuthorized()
        await syncPushRegistrationIfPossible()
    }

    private func syncPushRegistrationIfPossible() async {
        guard let viewer = currentUser else { return }
        guard let fcmToken = NotificationManager.currentFCMToken else {
            await unregisterPushRegistration(for: viewer.id)
            return
        }

        let tokenData: [String: Any] = [
            "installationID": NotificationManager.pushInstallationID,
            "fcmToken": fcmToken,
            "platform": "ios",
            "bundleID": Bundle.main.bundleIdentifier ?? "RPI Central",
            "feedNotificationsEnabled": socialFeedNotificationsEnabled,
            "groupNotificationsEnabled": socialGroupNotificationsEnabled,
            "mutedGroupChatIDs": Array(mutedGroupChatIDs).sorted(),
            "remoteNotificationsRegistered": NotificationManager.canReceiveRemotePush,
            "updatedAt": nowISO(),
        ]

        do {
            try await setData(
                tokenData,
                at: firestore.collection("users")
                    .document(viewer.id)
                    .collection("deviceTokens")
                    .document(NotificationManager.pushInstallationID)
            )
        } catch {
            #if DEBUG
            print("❌ Push token sync failed:", error)
            #endif
        }
    }

    private func unregisterPushRegistration(for userID: String) async {
        do {
            try await deleteDocument(
                firestore.collection("users")
                    .document(userID)
                    .collection("deviceTokens")
                    .document(NotificationManager.pushInstallationID)
            )
        } catch {
            #if DEBUG
            print("⚠️ Push token cleanup skipped:", error)
            #endif
        }
    }

    private func fetchOrCreateProfileForCurrentUser() async throws -> SocialUser? {
        guard let firebaseUser = Auth.auth().currentUser else { return nil }
        return try await fetchOrCreateProfile(for: firebaseUser)
    }

    private func fetchOrCreateProfile(for firebaseUser: User) async throws -> SocialUser {
        if let existing = try await fetchUser(id: firebaseUser.uid) {
            return existing
        }

        let isGuest = firebaseUser.isAnonymous
        let email = firebaseUser.email ?? ""
        let displayName = normalizeDisplayName(firebaseUser.displayName ?? (isGuest ? "Guest" : email.components(separatedBy: "@").first ?? "User"))
        return try await upsertProfile(for: firebaseUser, displayName: displayName, email: email, isGuest: isGuest)
    }

    private func upsertProfile(
        for firebaseUser: User,
        displayName: String,
        email: String,
        isGuest: Bool
    ) async throws -> SocialUser {
        let ref = firestore.collection("users").document(firebaseUser.uid)
        let existing = try await fetchUser(id: firebaseUser.uid)
        let username: String
        if let existingUsername = existing?.username {
            username = existingUsername
        } else {
            username = try await nextAvailableUsername(
                base: usernameBase(displayName: displayName, email: email, isGuest: isGuest)
            )
        }
        let createdAt = existing?.createdAt ?? nowISO()
        let shareSchedule = existing?.shareSchedule ?? false
        let shareLocation = existing?.shareLocation ?? false
        let lastScheduleAt = existing?.lastScheduleAt ?? ""

        var profileData: [String: Any] = [
            "displayName": displayName,
            "displayNameLower": displayName.lowercased(),
            "username": username,
            "usernameLower": username.lowercased(),
            "isGuest": isGuest,
            "shareSchedule": shareSchedule,
            "shareLocation": shareLocation,
            "createdAt": createdAt,
            "lastScheduleAt": lastScheduleAt,
            "sharedCourseKeys": existing?.sharedCourseKeys ?? [],
            "sharedSectionKeys": existing?.sharedSectionKeys ?? [],
        ]
        if existing != nil {
            // Authentication owns the private email address. Public profile
            // documents must not expose it to social search queries.
            profileData["email"] = FieldValue.delete()
        }
        try await setData(profileData, at: ref, merge: true)

        return SocialUser(
            id: firebaseUser.uid,
            username: username,
            displayName: displayName,
            email: email,
            isGuest: isGuest,
            shareSchedule: shareSchedule,
            shareLocation: shareLocation,
            createdAt: createdAt,
            lastScheduleAt: lastScheduleAt.isEmpty ? nil : lastScheduleAt,
            sharedCourseKeys: existing?.sharedCourseKeys ?? [],
            sharedSectionKeys: existing?.sharedSectionKeys ?? []
        )
    }

    #if canImport(FirebaseCore)
    private func makeSecondaryFirebaseContext() throws -> SecondaryFirebaseContext {
        let appName = "RPISecondarySeeder"
        if let app = FirebaseApp.app(name: appName) {
            return SecondaryFirebaseContext(
                auth: Auth.auth(app: app),
                firestore: Firestore.firestore(app: app)
            )
        }

        guard let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: filePath) else {
            throw SocialError.api("GoogleService-Info.plist is missing or invalid.")
        }

        FirebaseApp.configure(name: appName, options: options)
        guard let app = FirebaseApp.app(name: appName) else {
            throw SocialError.invalidResponse
        }

        return SecondaryFirebaseContext(
            auth: Auth.auth(app: app),
            firestore: Firestore.firestore(app: app)
        )
    }

    private func createDemoUser(
        context: SecondaryFirebaseContext,
        displayName: String,
        shareSchedule: Bool,
        semesterCode: String?,
        scheduleItems: [SharedScheduleItem]
    ) async throws -> SocialUser {
        let email = "demo.\(UUID().uuidString.lowercased())@rpicentral.app"
        let password = "DemoPass123!"
        let authResult = try await createUser(email: email, password: password, auth: context.auth)
        let username = try await nextAvailableUsername(
            base: usernameBase(displayName: displayName, email: email, isGuest: false),
            firestore: context.firestore
        )
        let createdAt = nowISO()

        let user = SocialUser(
            id: authResult.user.uid,
            username: username,
            displayName: displayName,
            email: email,
            isGuest: false,
            shareSchedule: shareSchedule,
            shareLocation: false,
            createdAt: createdAt,
            lastScheduleAt: shareSchedule ? createdAt : nil,
            sharedCourseKeys: [],
            sharedSectionKeys: []
        )

        var profileData: [String: Any] = [
            "displayName": user.displayName,
            "displayNameLower": user.displayName.lowercased(),
            "username": user.username,
            "usernameLower": user.username.lowercased(),
            "isGuest": user.isGuest,
            "shareSchedule": user.shareSchedule,
            "shareLocation": user.shareLocation,
            "createdAt": user.createdAt,
            "lastScheduleAt": user.lastScheduleAt ?? "",
            "sharedCourseKeys": user.sharedCourseKeys,
            "sharedSectionKeys": user.sharedSectionKeys,
        ]

        if shareSchedule {
            profileData["sharedScheduleItemCount"] = scheduleItems.count
            profileData["sharedScheduleLegacySemesterCode"] = semesterCode ?? ""
            profileData["sharedScheduleLegacyGeneratedAt"] = user.lastScheduleAt ?? createdAt
            profileData["sharedScheduleLegacyItems"] = scheduleItems.map(sharedScheduleItemData)
        }

        try await setData(profileData, at: context.firestore.collection("users").document(user.id))

        if shareSchedule {
            try await setData([
                "ownerID": user.id,
                "semesterCode": semesterCode ?? "",
                "generatedAt": user.lastScheduleAt ?? createdAt,
                "items": scheduleItems.map(sharedScheduleItemData),
            ], at: context.firestore.collection("sharedSchedules").document(user.id))
        }

        return user
    }
    #endif

    private func makeRequestSummaries(from documents: [DocumentSnapshot]) async throws -> [SocialFriendRequest] {
        let userIDs = Set(documents.flatMap { snapshot -> [String] in
            let data = snapshot.data() ?? [:]
            return [data["fromUserID"] as? String, data["toUserID"] as? String].compactMap { $0 }
        })
        let users = try await fetchUsers(ids: Array(userIDs))

        return documents.compactMap { snapshot in
            guard let data = snapshot.data() else { return nil }
            let fromID = data["fromUserID"] as? String ?? ""
            let toID = data["toUserID"] as? String ?? ""
            return SocialFriendRequest(
                id: snapshot.documentID,
                status: data["status"] as? String ?? "",
                createdAt: data["createdAt"] as? String ?? "",
                respondedAt: emptyToNil(data["respondedAt"] as? String),
                fromUser: users[fromID],
                toUser: users[toID]
            )
        }
    }

    /// Loads profiles 30 at a time (Firestore's `in` limit) instead of one
    /// round trip per user.
    private func fetchUserSnapshots(ids: [String]) async throws -> [String: DocumentSnapshot] {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        var result: [String: DocumentSnapshot] = [:]
        var start = 0
        while start < uniqueIDs.count {
            let chunk = Array(uniqueIDs[start..<min(start + 30, uniqueIDs.count)])
            let snapshot = try await getDocuments(
                firestore.collection("users").whereField(FieldPath.documentID(), in: chunk)
            )
            for document in snapshot.documents {
                result[document.documentID] = document
            }
            start += 30
        }
        return result
    }

    private func fetchUsers(ids: [String]) async throws -> [String: SocialUser] {
        try await fetchUserSnapshots(ids: ids).compactMapValues(makeUser)
    }

    private func fetchUser(id: String) async throws -> SocialUser? {
        let snapshot = try await getDocument(firestore.collection("users").document(id))
        return makeUser(from: snapshot)
    }

    /// Older builds kept owned groups only on the public profile document.
    /// Copy them into `friendGroups` once; afterwards that check is skipped.
    private func migrateLegacyFriendGroupsIfNeeded(
        ownerID: String,
        visibleGroups: [SocialFriendGroup]
    ) async throws -> Bool {
        let migrationKey = "social.friend_groups_migrated_v2.\(ownerID)"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return false }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        let ownedIDs = Set(visibleGroups.filter { $0.ownerID == ownerID }.map(\.id))
        let snapshot = try await getDocument(firestore.collection("users").document(ownerID))
        let legacyGroups = decodeFriendGroups(from: snapshot.data() ?? [:])
            .filter { $0.ownerID == ownerID && !ownedIDs.contains($0.id) }
        guard !legacyGroups.isEmpty else { return false }

        for group in legacyGroups {
            try await setData(friendGroupData(group), at: firestore.collection("friendGroups").document(group.id))
        }
        return true
    }

    private func loadFriendGroups(ownerID: String) async throws -> [SocialFriendGroup] {
        do {
            let snapshot = try await getDocuments(
                firestore.collection("friendGroups")
                    .whereField("ownerID", isEqualTo: ownerID)
            )

            let collectionGroups = snapshot.documents
                .compactMap(makeFriendGroup)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !collectionGroups.isEmpty {
                return collectionGroups
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        let userSnapshot = try await getDocument(firestore.collection("users").document(ownerID))
        if let data = userSnapshot.data(), data["friendGroups"] != nil {
            return decodeFriendGroups(from: data)
        }
        return []
    }

    private func saveFriendGroups(_ groups: [SocialFriendGroup], ownerID: String) async throws {
        try await updateData([
            "friendGroups": groups.map(friendGroupData)
        ], at: firestore.collection("users").document(ownerID))
        try await persistOwnedFriendGroupsToCollection(groups, ownerID: ownerID)
    }

    private func loadCourseCommunities(memberID: String) async throws -> [SocialCourseCommunity] {
        let snapshot = try await getDocuments(
            firestore.collection("courseCommunities")
                .whereField("memberIDs", arrayContains: memberID)
        )

        return snapshot.documents
            .compactMap(makeCourseCommunity)
            .sorted { lhs, rhs in
                if lhs.courseTitle == rhs.courseTitle {
                    if lhs.kind == rhs.kind {
                        return (lhs.sectionLabel ?? "") < (rhs.sectionLabel ?? "")
                    }
                    return lhs.kind == .course && rhs.kind == .section
                }
                return lhs.courseTitle.localizedCaseInsensitiveCompare(rhs.courseTitle) == .orderedAscending
            }
    }

    private func loadVisibleFriendGroups(
        viewerID: String,
        fallbackOwnedGroups: [SocialFriendGroup] = []
    ) async throws -> [SocialFriendGroup] {
        let ownedSnapshot = try await getDocuments(
            firestore.collection("friendGroups")
                .whereField("ownerID", isEqualTo: viewerID)
        )
        let memberSnapshot = try await getDocuments(
            firestore.collection("friendGroups")
                .whereField("memberIDs", arrayContains: viewerID)
        )

        let merged = Dictionary(
            uniqueKeysWithValues: (ownedSnapshot.documents + memberSnapshot.documents)
                .compactMap { snapshot in
                    makeFriendGroup(from: snapshot).map { ($0.id, $0) }
                }
        )

        let visibleGroups = Array(merged.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if !visibleGroups.isEmpty {
            return visibleGroups
        }
        return fallbackOwnedGroups
    }

    private func persistOwnedFriendGroupsToCollection(_ groups: [SocialFriendGroup], ownerID: String) async throws {
        let snapshot = try await getDocuments(
            firestore.collection("friendGroups")
                .whereField("ownerID", isEqualTo: ownerID)
        )
        let existingIDs = Set(snapshot.documents.map(\.documentID))
        let targetIDs = Set(groups.map(\.id))

        for group in groups {
            try await setData(friendGroupData(group), at: firestore.collection("friendGroups").document(group.id))
        }

        for removedID in existingIDs.subtracting(targetIDs) {
            try await deleteDocument(firestore.collection("friendGroups").document(removedID))
        }
    }

    private func assertCurrentUserCanUseSocial() async throws {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser else { throw SocialError.notAuthenticated }
        guard !canModerateSocialContent else { return }

        let moderation = try await loadModerationState(for: viewer.id)
        if moderation.isBanned {
            throw SocialError.api("Your social access is currently disabled.")
        }
#endif
    }

    private func assertCurrentUserCanPostSocialContent() async throws {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewer = currentUser else { throw SocialError.notAuthenticated }
        guard !canModerateSocialContent else { return }

        let moderation = try await loadModerationState(for: viewer.id)
        if moderation.isBanned {
            throw SocialError.api("Your social access is currently disabled.")
        }
        if let mutedUntil = moderation.mutedUntil, mutedUntil > Date() {
            let formatted = DateFormatter.localizedString(from: mutedUntil, dateStyle: .medium, timeStyle: .short)
            throw SocialError.api("You are muted until \(formatted).")
        }
#endif
    }

    private func loadModerationState(for userID: String) async throws -> SocialModerationState {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        let snapshot = try await getDocument(firestore.collection("users").document(userID))
        let data = snapshot.data() ?? [:]
        let isBanned = data["socialBanned"] as? Bool ?? false

        let mutedUntil: Date?
        if let timestamp = data["socialMutedUntil"] as? Timestamp {
            mutedUntil = timestamp.dateValue()
        } else if let isoString = data["socialMutedUntil"] as? String {
            mutedUntil = isoDate(isoString)
        } else {
            mutedUntil = nil
        }

        return SocialModerationState(isBanned: isBanned, mutedUntil: mutedUntil)
#else
        return SocialModerationState(isBanned: false, mutedUntil: nil)
#endif
    }

    private func pendingRequestExists(from fromUserID: String, to toUserID: String) async throws -> Bool {
        let snapshot = try await getDocuments(
            firestore.collection("friendRequests")
                .whereField("fromUserID", isEqualTo: fromUserID)
                .whereField("toUserID", isEqualTo: toUserID)
                .whereField("status", isEqualTo: "pending")
                .limit(to: 1)
        )
        return !snapshot.documents.isEmpty
    }

    private func friendshipExists(_ userA: String, _ userB: String) async throws -> Bool {
        let snapshot = try await getDocuments(
            firestore.collection("friendships")
                .whereField("members", arrayContains: userA)
        )
        return snapshot.documents.contains { document in
            let members = document.data()["members"] as? [String] ?? []
            return members.contains(userA) && members.contains(userB)
        }
    }

    private func canonicalFriendshipID(_ userA: String, _ userB: String) -> String {
        [userA, userB].sorted().joined(separator: "_")
    }

    private func friendViewReference(ownerID: String, viewerID: String) -> DocumentReference {
        firestore.collection("sharedSchedules")
            .document(ownerID)
            .collection("friendViews")
            .document(viewerID)
    }

    private func writeFriendViewSchedule(
        ownerID: String,
        viewerID: String,
        semesterCode: String,
        generatedAt: String,
        items: [SharedScheduleItem]
    ) async throws {
        try await setData([
            "ownerID": ownerID,
            "viewerID": viewerID,
            "semesterCode": semesterCode,
            "generatedAt": generatedAt,
            "items": items.map(sharedScheduleItemData),
        ], at: friendViewReference(ownerID: ownerID, viewerID: viewerID))
    }

    // MARK: - Shared schedule publishing

    /// What was last written for one document, so unchanged schedules cost
    /// no Firestore writes. Documents are still refreshed every few days so
    /// friends see a recent "Updated" time.
    private struct SharedScheduleFingerprint: Codable {
        let hash: String
        let writtenAt: Date
    }

    private enum BatchWrite {
        case set(DocumentReference, [String: Any])
        case update(DocumentReference, [AnyHashable: Any])
        case delete(DocumentReference)
    }

    private static let maxSharedScheduleItems = 1_500
    private static let sharedScheduleRefreshInterval: TimeInterval = 3 * 24 * 60 * 60
    private static let legacyPublicScheduleFields = [
        "sharedScheduleLegacyItems",
        "sharedScheduleLegacySemesterCode",
        "sharedScheduleLegacyGeneratedAt",
    ]

    private var sharedScheduleFingerprints: [String: SharedScheduleFingerprint] {
        get {
            guard let data = UserDefaults.standard.data(forKey: sharedScheduleFingerprintsKey),
                  let decoded = try? JSONDecoder().decode([String: SharedScheduleFingerprint].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: sharedScheduleFingerprintsKey)
            }
        }
    }

    private var cleanedScheduleOwnerIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: sharedScheduleCleanupKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: sharedScheduleCleanupKey) }
    }

    private func publishSharedSchedule(force: Bool) async throws {
        guard let viewer = currentUser else { throw SocialError.notAuthenticated }
        guard let source = scheduleSource else { return }

        guard viewer.shareSchedule else {
            try await removePublishedSchedule(ownerID: viewer.id)
            return
        }
        cleanedScheduleOwnerIDs.remove(viewer.id)

        let now = Date()
        let nowText = SharedScheduleDates.string(from: now)
        let window = source.sharedScheduleWindow(now: now)
        let events = source.shareableScheduleEvents(in: window)
        let semesterCode = source.currentSemester.rawValue
        let friendIDs = try await loadFriendIDs(for: viewer.id).sorted()

        if friendGroups.isEmpty {
            friendGroups = (try? await loadVisibleFriendGroups(viewerID: viewer.id)) ?? []
        }
        let groupMembersByID = Dictionary(
            friendGroups.map { ($0.id, Set($0.memberIDs + [$0.ownerID])) },
            uniquingKeysWith: { first, _ in first }
        )

        let baseItems = events
            .filter { $0.kind != .personal }
            .map(sharedScheduleItem(from:))
        let personalEvents = events.filter { $0.kind == .personal }

        var fingerprints = sharedScheduleFingerprints
        var writes: [BatchWrite] = []
        var pendingFingerprints: [String: SharedScheduleFingerprint] = [:]
        var publishedCoverageEnd = window.end

        func stage(
            key: String,
            reference: DocumentReference,
            viewerID: String?,
            items unsortedItems: [SharedScheduleItem]
        ) {
            let (items, coverageEnd) = limitedScheduleItems(unsortedItems, window: window)
            publishedCoverageEnd = min(publishedCoverageEnd, coverageEnd)
            let coverageEndText = SharedScheduleDates.string(from: coverageEnd)
            let hash = scheduleFingerprintHash(
                semesterCode: semesterCode,
                coverageEnd: coverageEndText,
                items: items
            )

            if !force,
               let existing = fingerprints[key],
               existing.hash == hash,
               now.timeIntervalSince(existing.writtenAt) < Self.sharedScheduleRefreshInterval {
                return
            }

            var data: [String: Any] = [
                "ownerID": viewer.id,
                "semesterCode": semesterCode,
                "generatedAt": nowText,
                "schemaVersion": 2,
                "coverageStart": SharedScheduleDates.string(from: window.start),
                "coverageEnd": coverageEndText,
                "timeZone": TimeZone.current.identifier,
                "items": items.map(sharedScheduleItemData),
            ]
            if let viewerID {
                data["viewerID"] = viewerID
            }
            writes.append(.set(reference, data))
            pendingFingerprints[key] = SharedScheduleFingerprint(hash: hash, writtenAt: now)
        }

        // The root document stays class/academic-only; per-friend documents
        // add only the personal events shared with that friend.
        stage(
            key: "\(viewer.id)|root",
            reference: firestore.collection("sharedSchedules").document(viewer.id),
            viewerID: nil,
            items: baseItems
        )

        for friendID in friendIDs {
            let visiblePersonal = personalEvents
                .filter {
                    source.personalEventVisibleToFriend(
                        friendID,
                        event: $0,
                        groupMembersByID: groupMembersByID
                    )
                }
                .map(sharedScheduleItem(from:))
            stage(
                key: "\(viewer.id)|friend|\(friendID)",
                reference: friendViewReference(ownerID: viewer.id, viewerID: friendID),
                viewerID: friendID,
                items: baseItems + visiblePersonal
            )
        }

        // Remove views for people who are no longer friends.
        let friendKeyPrefix = "\(viewer.id)|friend|"
        let currentFriendKeys = Set(friendIDs.map { friendKeyPrefix + $0 })
        var staleViewerIDs = Set(
            fingerprints.keys
                .filter { $0.hasPrefix(friendKeyPrefix) && !currentFriendKeys.contains($0) }
                .map { String($0.dropFirst(friendKeyPrefix.count)) }
        )
        if force || lastKnownFriendIDs.map({ $0 != Set(friendIDs) }) ?? true {
            let existingViews = try? await getDocuments(
                firestore.collection("sharedSchedules").document(viewer.id).collection("friendViews")
            )
            for document in existingViews?.documents ?? [] where !friendIDs.contains(document.documentID) {
                staleViewerIDs.insert(document.documentID)
            }
        }
        for staleViewerID in staleViewerIDs {
            writes.append(.delete(friendViewReference(ownerID: viewer.id, viewerID: staleViewerID)))
        }

        let courseKeys = sharedCourseKeys(from: source)
        let sectionKeys = sharedSectionKeys(from: source)
        var profileUpdate: [AnyHashable: Any] = [:]
        if !pendingFingerprints.isEmpty {
            profileUpdate["lastScheduleAt"] = nowText
            profileUpdate["sharedScheduleItemCount"] = baseItems.count
        }
        if courseKeys != viewer.sharedCourseKeys || sectionKeys != viewer.sharedSectionKeys {
            profileUpdate["sharedCourseKeys"] = courseKeys
            profileUpdate["sharedSectionKeys"] = sectionKeys
        }
        let legacyCleanupKey = "\(viewer.id)|legacy-public-schedule-cleared"
        if fingerprints[legacyCleanupKey] == nil {
            // Older builds copied the class schedule onto the public profile,
            // which any signed-in user can read.
            for field in Self.legacyPublicScheduleFields {
                profileUpdate[field] = FieldValue.delete()
            }
            pendingFingerprints[legacyCleanupKey] = SharedScheduleFingerprint(hash: "", writtenAt: now)
        }
        if !profileUpdate.isEmpty {
            writes.append(.update(firestore.collection("users").document(viewer.id), profileUpdate))
        }

        guard !writes.isEmpty else {
            lastKnownFriendIDs = Set(friendIDs)
            return
        }

        try await commit(writes)

        for staleViewerID in staleViewerIDs {
            fingerprints.removeValue(forKey: friendKeyPrefix + staleViewerID)
        }
        fingerprints.merge(pendingFingerprints) { _, new in new }
        sharedScheduleFingerprints = fingerprints
        lastKnownFriendIDs = Set(friendIDs)

        if let current = currentUser, current.id == viewer.id {
            currentUser = SocialUser(
                id: current.id,
                username: current.username,
                displayName: current.displayName,
                email: current.email,
                isGuest: current.isGuest,
                shareSchedule: current.shareSchedule,
                shareLocation: current.shareLocation,
                createdAt: current.createdAt,
                lastScheduleAt: (profileUpdate["lastScheduleAt"] as? String) ?? current.lastScheduleAt,
                sharedCourseKeys: courseKeys,
                sharedSectionKeys: sectionKeys
            )
        }
        lastSchedulePublish = (now, publishedCoverageEnd)
    }

    /// Deletes this user's published schedule after sharing is turned off.
    /// Runs once per owner rather than on every sync.
    private func removePublishedSchedule(ownerID: String) async throws {
        guard !cleanedScheduleOwnerIDs.contains(ownerID) else { return }

        var writes: [BatchWrite] = [.delete(firestore.collection("sharedSchedules").document(ownerID))]
        let views = try await getDocuments(
            firestore.collection("sharedSchedules").document(ownerID).collection("friendViews")
        )
        writes.append(contentsOf: views.documents.map { .delete($0.reference) })

        var profileUpdate: [AnyHashable: Any] = [
            "sharedCourseKeys": [String](),
            "sharedSectionKeys": [String](),
            "sharedScheduleItemCount": 0,
        ]
        for field in Self.legacyPublicScheduleFields {
            profileUpdate[field] = FieldValue.delete()
        }
        writes.append(.update(firestore.collection("users").document(ownerID), profileUpdate))

        try await commit(writes)

        sharedScheduleFingerprints = sharedScheduleFingerprints.filter { !$0.key.hasPrefix("\(ownerID)|") }
        cleanedScheduleOwnerIDs.insert(ownerID)
        lastSchedulePublish = nil
    }

    private func commit(_ writes: [BatchWrite]) async throws {
        var start = 0
        while start < writes.count {
            let end = min(start + 400, writes.count)
            let batch = firestore.batch()
            for write in writes[start..<end] {
                switch write {
                case .set(let reference, let data):
                    batch.setData(data, forDocument: reference)
                case .update(let reference, let data):
                    batch.updateData(data, forDocument: reference)
                case .delete(let reference):
                    batch.deleteDocument(reference)
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                batch.commit { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            start = end
        }
    }

    /// Keeps documents far below Firestore's 1 MiB limit. When a schedule
    /// is unusually dense, coverage ends at the last day that fit.
    private func limitedScheduleItems(
        _ items: [SharedScheduleItem],
        window: DateInterval
    ) -> (items: [SharedScheduleItem], coverageEnd: Date) {
        let sorted = items.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
        guard sorted.count > Self.maxSharedScheduleItems else {
            return (sorted, window.end)
        }

        let calendar = Calendar.current
        let kept = Array(sorted.prefix(Self.maxSharedScheduleItems))
        let lastStart = kept.last.flatMap { SharedScheduleDates.parse($0.startDate) } ?? window.end
        // Drop the partially included final day so coverage stays truthful.
        let lastFullDay = calendar.startOfDay(for: lastStart)
        let trimmed = kept.filter { (SharedScheduleDates.parse($0.startDate) ?? .distantPast) < lastFullDay }
        let coverageEnd = lastFullDay.addingTimeInterval(-1)
        return (trimmed, max(window.start, coverageEnd))
    }

    private func sharedScheduleItem(from event: ClassEvent) -> SharedScheduleItem {
        SharedScheduleItem(
            id: stableScheduleItemID(for: event),
            title: event.title,
            location: event.location,
            startDate: SharedScheduleDates.string(from: event.startDate),
            endDate: SharedScheduleDates.string(from: event.endDate),
            isAllDay: event.isAllDay,
            kind: event.kind.rawValue,
            badge: event.badge?.rawValue
        )
    }

    private func scheduleFingerprintHash(
        semesterCode: String,
        coverageEnd: String,
        items: [SharedScheduleItem]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(items)) ?? Data()
        return SocialHashing.fnv1a64Hex(Data("\(semesterCode)|\(coverageEnd)|".utf8) + payload)
    }

    private struct SocialAlert: Identifiable, Equatable {
        let id: String
        let senderID: String
        let type: String
        let title: String
        let body: String
        let createdAt: String
        let eventDate: String?
        let contextID: String?
    }

    private func loadFriendIDs(for userID: String) async throws -> [String] {
        let friendshipsSnapshot = try await getDocuments(
            firestore.collection("friendships").whereField("members", arrayContains: userID)
        )
        return friendshipsSnapshot.documents.compactMap { snapshot -> String? in
            let members = snapshot.data()["members"] as? [String] ?? []
            return members.first(where: { $0 != userID })
        }
    }

    private func recipientIDsForFeedPost(
        ownerID: String,
        visibility: SocialFeedVisibility,
        visibleGroupIDs: [String]
    ) async throws -> [String] {
        switch visibility {
        case .everyone:
            return []
        case .friends:
            return Array(Set(try await loadFriendIDs(for: ownerID))).sorted()
        case .groups:
            let groups = try await loadFriendGroups(ownerID: ownerID)
            let selectedIDs = Set(visibleGroupIDs)
            let recipients = groups
                .filter { selectedIDs.contains($0.id) }
                .flatMap(\.memberIDs)
            return Array(Set(recipients)).sorted()
        }
    }

    private func recipientIDsForSharedEvents(
        _ events: [StoredPersonalEvent],
        groups: [SocialFriendGroup]
    ) -> [String] {
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Set($0.memberIDs)) })
        var recipientIDs: Set<String> = []

        for event in events {
            switch event.shareMode {
            case .none:
                continue
            case .friends:
                recipientIDs.formUnion(event.sharedFriendIDs)
            case .groups:
                for groupID in event.sharedGroupIDs {
                    recipientIDs.formUnion(groupsByID[groupID] ?? Set<String>())
                }
            }
        }

        return Array(recipientIDs).sorted()
    }

    private func makeReceivedSharedCalendarEvent(from event: StoredPersonalEvent, owner: SocialUser) -> ReceivedSharedCalendarEvent {
        let formatter = ISO8601DateFormatter()
        return ReceivedSharedCalendarEvent(
            id: "\(owner.id)_\(event.id.uuidString)",
            ownerID: owner.id,
            ownerUsername: owner.username,
            ownerDisplayName: owner.displayName,
            title: event.title,
            location: event.location,
            startDate: formatter.string(from: event.startDate),
            endDate: formatter.string(from: event.endDate),
            createdAt: nowISO()
        )
    }

    private func sharedCalendarEventData(_ event: ReceivedSharedCalendarEvent) -> [String: Any] {
        [
            "id": event.id,
            "ownerID": event.ownerID,
            "ownerUsername": event.ownerUsername,
            "ownerDisplayName": event.ownerDisplayName,
            "title": event.title,
            "location": event.location,
            "startDate": event.startDate,
            "endDate": event.endDate,
            "createdAt": event.createdAt,
        ]
    }

    private func makeReceivedSharedCalendarEvent(from snapshot: DocumentSnapshot) -> ReceivedSharedCalendarEvent? {
        guard let data = snapshot.data(),
              let id = data["id"] as? String,
              let ownerID = data["ownerID"] as? String,
              let ownerUsername = data["ownerUsername"] as? String,
              let ownerDisplayName = data["ownerDisplayName"] as? String,
              let title = data["title"] as? String,
              let location = data["location"] as? String,
              let startDate = data["startDate"] as? String,
              let endDate = data["endDate"] as? String,
              let createdAt = data["createdAt"] as? String else {
            return nil
        }

        return ReceivedSharedCalendarEvent(
            id: id,
            ownerID: ownerID,
            ownerUsername: ownerUsername,
            ownerDisplayName: ownerDisplayName,
            title: title,
            location: location,
            startDate: startDate,
            endDate: endDate,
            createdAt: createdAt
        )
    }

    private func persistReceivedSharedCalendarEvents(_ events: [ReceivedSharedCalendarEvent]) {
        let sorted = events.sorted { lhs, rhs in
            (isoDate(lhs.startDate) ?? .distantFuture) < (isoDate(rhs.startDate) ?? .distantFuture)
        }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(sorted) {
            UserDefaults.standard.set(data, forKey: receivedSharedEventsStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: receivedSharedEventsStorageKey)
        }
        NotificationCenter.default.post(name: .sharedCalendarEventsDidUpdate, object: nil)
    }

    private func clearLocalSharedCalendarEvents() {
        UserDefaults.standard.removeObject(forKey: receivedSharedEventsStorageKey)
        NotificationCenter.default.post(name: .sharedCalendarEventsDidUpdate, object: nil)
    }

    private func makeSocialAlert(from snapshot: DocumentSnapshot) -> SocialAlert? {
        guard let data = snapshot.data(),
              let id = data["id"] as? String,
              let senderID = data["senderID"] as? String,
              let type = data["type"] as? String,
              let title = data["title"] as? String,
              let body = data["body"] as? String,
              let createdAt = data["createdAt"] as? String else {
            return nil
        }

        return SocialAlert(
            id: id,
            senderID: senderID,
            type: type,
            title: title,
            body: body,
            createdAt: createdAt,
            eventDate: emptyToNil(data["eventDate"] as? String),
            contextID: emptyToNil(data["contextID"] as? String)
        )
    }

    private func socialAlertData(
        id: String,
        senderID: String,
        type: String,
        title: String,
        body: String,
        eventDate: Date?,
        contextID: String? = nil
    ) -> [String: Any] {
        [
            "id": id,
            "senderID": senderID,
            "type": type,
            "title": title,
            "body": body,
            "createdAt": nowISO(),
            "eventDate": eventDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "contextID": contextID ?? "",
        ]
    }

    private func sendSocialAlert(
        to recipientIDs: [String],
        type: String,
        title: String,
        body: String,
        eventDate: Date?,
        contextID: String? = nil
    ) async throws {
        guard let senderID = currentUser?.id else { return }
        for recipientID in Set(recipientIDs).sorted() where recipientID != senderID {
            let id = UUID().uuidString
            try await setData(
                socialAlertData(
                    id: id,
                    senderID: senderID,
                    type: type,
                    title: title,
                    body: body,
                    eventDate: eventDate,
                    contextID: contextID
                ),
                at: firestore.collection("users")
                    .document(recipientID)
                    .collection("socialNotifications")
                    .document(id)
            )
        }
    }

    private func processIncomingSocialAlerts(_ alerts: [SocialAlert]) {
        var delivered = Set(UserDefaults.standard.stringArray(forKey: deliveredSocialAlertIDsKey) ?? [])
        for alert in alerts.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard !delivered.contains(alert.id) else { continue }
            if alert.type == "groupMessage", alert.contextID == activeGroupChatID, isAppActive {
                delivered.insert(alert.id)
                continue
            }
            if alert.type == "groupMessage", isMutedChatContext(alert.contextID) {
                delivered.insert(alert.id)
                continue
            }
            guard shouldDeliverSocialAlert(alert) else {
                delivered.insert(alert.id)
                continue
            }

            // The Cloud Function already sends this alert through APNs. Only
            // schedule a local fallback when this installation cannot receive
            // remote push, otherwise one message can produce two banners.
            if NotificationManager.canReceiveRemotePush {
                delivered.insert(alert.id)
                continue
            }

            NotificationManager.requestAuthorization()
            NotificationManager.scheduleSocialNotification(
                identifier: "social.\(alert.id)",
                title: alert.title,
                body: alert.body
            )
            delivered.insert(alert.id)
        }

        let trimmed = Array(delivered.sorted().suffix(400))
        UserDefaults.standard.set(trimmed, forKey: deliveredSocialAlertIDsKey)
    }

    private func shouldDeliverSocialAlert(_ alert: SocialAlert) -> Bool {
        switch alert.type {
        case "groupMessage":
            return socialGroupNotificationsEnabled
        default:
            return socialFeedNotificationsEnabled
        }
    }

    private var socialFeedNotificationsEnabled: Bool {
        if UserDefaults.standard.object(forKey: socialFeedNotificationsEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: socialFeedNotificationsEnabledKey)
    }

    private var socialGroupNotificationsEnabled: Bool {
        if UserDefaults.standard.object(forKey: socialGroupNotificationsEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: socialGroupNotificationsEnabledKey)
    }

    private var mutedGroupChatIDs: Set<String> {
        Set(
            (UserDefaults.standard.stringArray(forKey: mutedGroupChatIDsKey) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func isMutedChatContext(_ contextID: String?) -> Bool {
        guard let contextID, !contextID.isEmpty else { return false }
        return mutedGroupChatIDs.contains(contextID)
    }

    private var isAppActive: Bool {
#if canImport(UIKit)
        UIApplication.shared.applicationState == .active
#else
        true
#endif
    }

    private func nextAvailableUsername(base: String, firestore: Firestore? = nil) async throws -> String {
        let store = firestore ?? self.firestore
        var candidate = base.isEmpty ? "user" : base
        var attempt = 1
        while true {
            let snapshot = try await getDocuments(
                store.collection("users")
                    .whereField("usernameLower", isEqualTo: candidate.lowercased())
                    .limit(to: 1)
            )
            if snapshot.documents.isEmpty {
                return candidate
            }
            candidate = "\(base)\(attempt)"
            attempt += 1
        }
    }

    private func usernameBase(displayName: String, email: String, isGuest: Bool) -> String {
        let raw: String
        if isGuest {
            raw = displayName
        } else if !email.isEmpty {
            raw = email.components(separatedBy: "@").first ?? displayName
        } else {
            raw = displayName
        }
        let cleaned = raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return String(cleaned.prefix(20)).isEmpty ? "user" : String(cleaned.prefix(20))
    }

    private func mergeUniqueDocuments(_ documents: [DocumentSnapshot]) -> [DocumentSnapshot] {
        var seen: Set<String> = []
        return documents.filter { snapshot in
            seen.insert(snapshot.documentID).inserted
        }
    }

    private func markPendingOutgoingSearchResult(for userID: String) {
        searchResults = searchResults.map { result in
            guard result.id == userID else { return result }
            return SocialSearchResult(
                id: result.id,
                username: result.username,
                displayName: result.displayName,
                email: result.email,
                isGuest: result.isGuest,
                shareSchedule: result.shareSchedule,
                shareLocation: result.shareLocation,
                createdAt: result.createdAt,
                lastScheduleAt: result.lastScheduleAt,
                areFriends: result.areFriends,
                hasPendingIncoming: result.hasPendingIncoming,
                hasPendingOutgoing: true,
                reason: result.reason
            )
        }

        quickAddSuggestions = quickAddSuggestions.map { result in
            guard result.id == userID else { return result }
            return SocialSearchResult(
                id: result.id,
                username: result.username,
                displayName: result.displayName,
                email: result.email,
                isGuest: result.isGuest,
                shareSchedule: result.shareSchedule,
                shareLocation: result.shareLocation,
                createdAt: result.createdAt,
                lastScheduleAt: result.lastScheduleAt,
                areFriends: result.areFriends,
                hasPendingIncoming: result.hasPendingIncoming,
                hasPendingOutgoing: true,
                reason: result.reason
            )
        }
    }

    private func sendFriendRequestInternal(to target: SocialUser) async throws {
        guard let viewer = currentUser else { throw SocialError.notAuthenticated }
        try await assertCurrentUserCanUseSocial()
        guard target.id != viewer.id else { throw SocialError.api("You cannot friend yourself.") }
        guard !(try await friendshipExists(viewer.id, target.id)) else {
            throw SocialError.api("You are already friends.")
        }
        guard !(try await pendingRequestExists(from: viewer.id, to: target.id)),
              !(try await pendingRequestExists(from: target.id, to: viewer.id)) else {
            throw SocialError.api("A pending friend request already exists.")
        }

        try await setData([
            "fromUserID": viewer.id,
            "toUserID": target.id,
            "status": "pending",
            "createdAt": nowISO(),
            "respondedAt": "",
        ], at: firestore.collection("friendRequests").document())

        try await refreshOverviewInternal()
        markPendingOutgoingSearchResult(for: target.id)
        statusMessage = "Friend request sent to @\(target.username)."
    }

    private func isDemoUser(_ user: SocialUser) -> Bool {
        user.email.lowercased().hasSuffix("@rpicentral.app") ||
        user.displayName.lowercased().hasPrefix("demo ") ||
        user.username.lowercased().hasPrefix("demo")
    }

    private func makeUser(from snapshot: DocumentSnapshot) -> SocialUser? {
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        let privateEmail = snapshot.documentID == Auth.auth().currentUser?.uid
            ? Auth.auth().currentUser?.email ?? ""
            : ""
        return SocialUser(
            id: snapshot.documentID,
            username: data["username"] as? String ?? "",
            displayName: data["displayName"] as? String ?? "",
            email: privateEmail,
            isGuest: data["isGuest"] as? Bool ?? false,
            shareSchedule: data["shareSchedule"] as? Bool ?? false,
            shareLocation: data["shareLocation"] as? Bool ?? false,
            createdAt: data["createdAt"] as? String ?? "",
            lastScheduleAt: emptyToNil(data["lastScheduleAt"] as? String),
            sharedCourseKeys: (data["sharedCourseKeys"] as? [String] ?? []).sorted(),
            sharedSectionKeys: (data["sharedSectionKeys"] as? [String] ?? []).sorted()
        )
    }

    private func makeFriendGroup(from snapshot: DocumentSnapshot) -> SocialFriendGroup? {
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return SocialFriendGroup(
            id: snapshot.documentID,
            ownerID: data["ownerID"] as? String ?? "",
            name: data["name"] as? String ?? "",
            createdAt: data["createdAt"] as? String ?? "",
            memberIDs: (data["memberIDs"] as? [String] ?? []).sorted()
        )
    }

    private func decodeFriendGroups(from data: [String: Any]) -> [SocialFriendGroup] {
        let rawGroups = data["friendGroups"] as? [[String: Any]] ?? []
        return rawGroups.compactMap { item in
            guard let id = item["id"] as? String,
                  let ownerID = item["ownerID"] as? String,
                  let name = item["name"] as? String,
                  let createdAt = item["createdAt"] as? String else {
                return nil
            }

            return SocialFriendGroup(
                id: id,
                ownerID: ownerID,
                name: name,
                createdAt: createdAt,
                memberIDs: (item["memberIDs"] as? [String] ?? []).sorted()
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func friendGroupData(_ group: SocialFriendGroup) -> [String: Any] {
        [
            "id": group.id,
            "ownerID": group.ownerID,
            "name": group.name,
            "createdAt": group.createdAt,
            "memberIDs": group.memberIDs.sorted(),
        ]
    }

    private func makeCourseCommunity(
        kind: SocialCourseCommunityKind,
        course: Course,
        section: CourseSection?,
        semesterCode: String?,
        viewerID: String
    ) -> SocialCourseCommunity {
        let now = nowISO()

        return SocialCourseCommunity(
            id: courseCommunityID(kind: kind, course: course, section: section, semesterCode: semesterCode),
            kind: kind,
            courseSubject: course.subject.uppercased(),
            courseNumber: course.number,
            courseTitle: course.title,
            semesterCode: semesterCode,
            sectionLabel: section.map { sectionCommunityLabel(section: $0, semesterCode: semesterCode) },
            memberIDs: [viewerID],
            createdAt: now,
            updatedAt: now
        )
    }

    private func ensureCourseCommunityMembership(_ community: SocialCourseCommunity, viewerID: String) async throws {
        let ref = firestore.collection("courseCommunities").document(community.id)
        do {
            try await updateData([
                "kind": community.kind.rawValue,
                "courseSubject": community.courseSubject,
                "courseNumber": community.courseNumber,
                "courseTitle": community.courseTitle,
                "semesterCode": community.semesterCode ?? "",
                "sectionLabel": community.sectionLabel ?? "",
                "memberIDs": FieldValue.arrayUnion([viewerID]),
                "updatedAt": nowISO(),
            ], at: ref)
        } catch {
            // Updating a class group that doesn't exist yet fails the rules
            // (there is no member list to check), which Firestore reports as
            // permission denied rather than not found. Either way, create it.
            if isDocumentMissing(error) || isPermissionDenied(error) {
                try await setData(courseCommunityData(community), at: ref)
            } else {
                throw error
            }
        }
    }

    private func makeCourseCommunity(from snapshot: DocumentSnapshot) -> SocialCourseCommunity? {
        guard let data = snapshot.data(),
              let kindRaw = data["kind"] as? String,
              let kind = SocialCourseCommunityKind(rawValue: kindRaw),
              let courseSubject = data["courseSubject"] as? String,
              let courseNumber = data["courseNumber"] as? String,
              let courseTitle = data["courseTitle"] as? String,
              let createdAt = data["createdAt"] as? String,
              let updatedAt = data["updatedAt"] as? String else {
            return nil
        }

        return SocialCourseCommunity(
            id: snapshot.documentID,
            kind: kind,
            courseSubject: courseSubject,
            courseNumber: courseNumber,
            courseTitle: courseTitle,
            semesterCode: emptyToNil(data["semesterCode"] as? String),
            sectionLabel: emptyToNil(data["sectionLabel"] as? String),
            memberIDs: (data["memberIDs"] as? [String] ?? []).sorted(),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func isDocumentMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "FIRFirestoreErrorDomain",
           nsError.code == FirestoreErrorCode.notFound.rawValue {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("no document to update") || message.contains("not found")
    }
    

    private func loadCourseComments(communityRef: DocumentReference) async throws -> [SocialCourseComment] {
        let snapshot = try await getDocuments(
            communityRef.collection("comments")
                .order(by: "createdAt", descending: true)
                .limit(to: 80)
        )

        return snapshot.documents.compactMap(makeCourseComment)
    }

    private func courseCommunityID(
        kind: SocialCourseCommunityKind,
        course: Course,
        section: CourseSection?,
        semesterCode: String?
    ) -> String {
        switch kind {
        case .course:
            return overallCourseCommunityID(for: course)
        case .section:
            let sectionToken = normalizedSectionToken(section, semesterCode: semesterCode)
            return "section_\(normalizedCourseToken(subject: course.subject, number: course.number))_\(sectionToken)"
        }
    }

    private func normalizedCourseToken(subject: String, number: String) -> String {
        let raw = "\(subject)_\(number)"
        return String(raw.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private func normalizedSectionToken(_ section: CourseSection?, semesterCode: String?) -> String {
        let raw = [
            semesterCode ?? "none",
            section?.section ?? "NA",
            section?.crn.map(String.init) ?? "NA"
        ].joined(separator: "_")

        return String(raw.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private func sectionCommunityLabel(section: CourseSection, semesterCode: String?) -> String {
        let semesterName = semesterCode.flatMap(Semester.init(rawValue:))?.displayName ?? semesterCode ?? "Unknown Term"
        return "\(semesterName) • Sec \(section.section)"
    }

    private func courseCommunityData(_ community: SocialCourseCommunity) -> [String: Any] {
        [
            "kind": community.kind.rawValue,
            "courseSubject": community.courseSubject,
            "courseNumber": community.courseNumber,
            "courseTitle": community.courseTitle,
            "semesterCode": community.semesterCode ?? "",
            "sectionLabel": community.sectionLabel ?? "",
            "memberIDs": community.memberIDs,
            "createdAt": community.createdAt,
            "updatedAt": community.updatedAt,
        ]
    }

    private func courseCommentData(_ comment: SocialCourseComment) -> [String: Any] {
        [
            "communityID": comment.communityID,
            "userID": comment.userID,
            "username": comment.username,
            "displayName": comment.displayName,
            "body": comment.body,
            "createdAt": comment.createdAt,
        ]
    }

    private func makeCourseComment(from snapshot: DocumentSnapshot) -> SocialCourseComment? {
        guard let data = snapshot.data(),
              let communityID = data["communityID"] as? String,
              let userID = data["userID"] as? String,
              let username = data["username"] as? String,
              let displayName = data["displayName"] as? String,
              let body = data["body"] as? String,
              let createdAt = data["createdAt"] as? String else {
            return nil
        }

        return SocialCourseComment(
            id: snapshot.documentID,
            communityID: communityID,
            userID: userID,
            username: username,
            displayName: displayName,
            body: body,
            createdAt: createdAt
        )
    }

    private func courseResourceData(_ resource: SocialCourseResource) -> [String: Any] {
        [
            "communityID": resource.communityID,
            "title": resource.title,
            "kind": resource.kind,
            "url": resource.url,
            "notes": resource.notes,
            "createdAt": resource.createdAt,
            "createdByUserID": resource.createdByUserID,
            "createdByDisplayName": resource.createdByDisplayName,
        ]
    }

    private func makeCourseResource(from snapshot: DocumentSnapshot) -> SocialCourseResource? {
        guard let data = snapshot.data(),
              let communityID = data["communityID"] as? String,
              let title = data["title"] as? String,
              let kind = data["kind"] as? String,
              let url = data["url"] as? String,
              let notes = data["notes"] as? String,
              let createdAt = data["createdAt"] as? String,
              let createdByUserID = data["createdByUserID"] as? String,
              let createdByDisplayName = data["createdByDisplayName"] as? String else {
            return nil
        }

        return SocialCourseResource(
            id: snapshot.documentID,
            communityID: communityID,
            title: title,
            kind: kind,
            url: url,
            notes: notes,
            createdAt: createdAt,
            createdByUserID: createdByUserID,
            createdByDisplayName: createdByDisplayName
        )
    }

    private func groupPollData(_ poll: SocialGroupPoll) -> [String: Any] {
        [
            "threadID": poll.threadID,
            "question": poll.question,
            "options": poll.options.map(groupPollOptionData),
            "votesByUserID": poll.votesByUserID,
            "createdAt": poll.createdAt,
            "createdByUserID": poll.createdByUserID,
            "createdByDisplayName": poll.createdByDisplayName,
            "isClosed": poll.isClosed,
        ]
    }

    private func groupPollOptionData(_ option: SocialGroupPollOption) -> [String: Any] {
        [
            "id": option.id,
            "title": option.title,
        ]
    }

    private func makeGroupPoll(from snapshot: DocumentSnapshot) -> SocialGroupPoll? {
        guard let data = snapshot.data(),
              let threadID = data["threadID"] as? String,
              let question = data["question"] as? String,
              let rawOptions = data["options"] as? [[String: Any]],
              let createdAt = data["createdAt"] as? String,
              let createdByUserID = data["createdByUserID"] as? String,
              let createdByDisplayName = data["createdByDisplayName"] as? String else {
            return nil
        }

        let options = rawOptions.compactMap { raw -> SocialGroupPollOption? in
            guard let id = raw["id"] as? String,
                  let title = raw["title"] as? String else {
                return nil
            }
            return SocialGroupPollOption(id: id, title: title)
        }

        return SocialGroupPoll(
            id: snapshot.documentID,
            threadID: threadID,
            question: question,
            options: options,
            votesByUserID: data["votesByUserID"] as? [String: String] ?? [:],
            createdAt: createdAt,
            createdByUserID: createdByUserID,
            createdByDisplayName: createdByDisplayName,
            isClosed: data["isClosed"] as? Bool ?? false
        )
    }

    private func makeGroupPollItem(_ poll: SocialGroupPoll, viewerID: String) -> SocialGroupPollItem {
        var voteCounts: [String: Int] = [:]
        for option in poll.options {
            voteCounts[option.id] = poll.votesByUserID.values.filter { $0 == option.id }.count
        }

        return SocialGroupPollItem(
            poll: poll,
            voteCounts: voteCounts,
            selectedOptionID: poll.votesByUserID[viewerID]
        )
    }

    private func sharedCourseKey(subject: String, number: String, semesterCode: String) -> String {
        "\(semesterCode)|\(normalizedCourseToken(subject: subject, number: number))"
    }

    private func sharedSectionKey(course: Course, section: CourseSection, semesterCode: String) -> String {
        "\(semesterCode)|\(normalizedCourseToken(subject: course.subject, number: course.number))|\(normalizedSectionToken(section, semesterCode: semesterCode))"
    }

    private func sharedCourseKeys(from viewModel: CalendarViewModel) -> [String] {
        Array(
            Set(
                viewModel.enrolledCourses.map {
                    sharedCourseKey(subject: $0.course.subject, number: $0.course.number, semesterCode: $0.semesterCode)
                }
            )
        )
        .sorted()
    }

    private func sharedSectionKeys(from viewModel: CalendarViewModel) -> [String] {
        Array(
            Set(
                viewModel.enrolledCourses.map {
                    sharedSectionKey(course: $0.course, section: $0.section, semesterCode: $0.semesterCode)
                }
            )
        )
        .sorted()
    }

    private func ensureGroupChat(_ reference: SocialGroupChatReference) async throws {
        let ref = firestore.collection("groupChats").document(reference.id)
        do {
            var metadata: [AnyHashable: Any] = [
                "title": reference.title,
                "subtitle": reference.subtitle,
                "sourceKind": reference.sourceKind.rawValue,
                "isCampusWide": reference.sourceKind == .campusGroup,
            ]
            metadata["memberIDs"] = reference.sourceKind == .campusGroup
                ? FieldValue.arrayUnion(reference.memberIDs)
                : reference.memberIDs
            try await updateData(metadata, at: ref)
        } catch {
            if isDocumentMissing(error) {
                try await setData(groupChatThreadData(reference), at: ref)
            } else {
                throw error
            }
        }
    }

    private func groupChatThreadData(_ reference: SocialGroupChatReference) -> [String: Any] {
        [
            "title": reference.title,
            "subtitle": reference.subtitle,
            "sourceKind": reference.sourceKind.rawValue,
            "memberIDs": reference.memberIDs,
            "isCampusWide": reference.sourceKind == .campusGroup,
            "createdAt": nowISO(),
            "updatedAt": nowISO(),
        ]
    }

    private func groupChatMessageData(_ message: SocialGroupChatMessage) -> [String: Any] {
        [
            "threadID": message.threadID,
            "userID": message.userID,
            "username": message.username,
            "displayName": message.displayName,
            "body": message.body,
            "createdAt": message.createdAt,
        ]
    }

    private func makeGroupChatMessage(from snapshot: DocumentSnapshot) -> SocialGroupChatMessage? {
        guard let data = snapshot.data(),
              let threadID = data["threadID"] as? String,
              let userID = data["userID"] as? String,
              let username = data["username"] as? String,
              let displayName = data["displayName"] as? String,
              let body = data["body"] as? String,
              let createdAt = data["createdAt"] as? String else {
            return nil
        }

        return SocialGroupChatMessage(
            id: snapshot.documentID,
            threadID: threadID,
            userID: userID,
            username: username,
            displayName: displayName,
            body: body,
            createdAt: createdAt
        )
    }

    private func loadFeedItems(friendOwnerIDs: [String]) async throws -> [SocialFeedItem] {
        guard let viewer = currentUser else { return [] }
        let friendOwnerIDSet = Set(friendOwnerIDs)
        var ownerSnapshots: [String: DocumentSnapshot] = [:]

        do {
            let publicUsersSnapshot = try await getDocuments(
                firestore.collection("users")
                    .order(by: "lastFeedPostAt", descending: true)
                    .limit(to: 60)
            )
            for document in publicUsersSnapshot.documents {
                ownerSnapshots[document.documentID] = document
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        // The recent-posters query already returned those documents; only
        // fetch friends (and this user) who were not in it.
        let missingOwnerIDs = friendOwnerIDSet.union([viewer.id]).subtracting(ownerSnapshots.keys)
        if !missingOwnerIDs.isEmpty {
            do {
                ownerSnapshots.merge(try await fetchUserSnapshots(ids: Array(missingOwnerIDs))) { current, _ in current }
            } catch {
                if !isPermissionDenied(error) {
                    throw error
                }
            }
        }

        var posts: [SocialFeedPost] = []
        var responsesByPostID: [String: [SocialFeedPresence]] = [:]

        for (ownerID, snapshot) in ownerSnapshots {
            let data = snapshot.data() ?? [:]
            let ownerGroups = decodeFriendGroups(from: data)

            posts.append(
                contentsOf: decodeFeedPosts(from: data).filter { post in
                    canViewerSeeFeedPost(
                        post,
                        ownerID: ownerID,
                        viewerID: viewer.id,
                        friendOwnerIDs: friendOwnerIDSet,
                        ownerGroups: ownerGroups
                    )
                }
            )
            for response in decodeFeedResponses(from: data) {
                responsesByPostID[response.postID, default: []].append(response)
            }
        }

        let now = Date()
        return posts
            .filter { shouldIncludeFeedPost($0, now: now) }
            .sorted { lhs, rhs in
                (isoDate(lhs.createdAt) ?? .distantPast) > (isoDate(rhs.createdAt) ?? .distantPast)
            }
            .map { post in
                let responses = (responsesByPostID[post.id] ?? [])
                    .sorted { lhs, rhs in
                        (isoDate(lhs.respondedAt) ?? .distantPast) > (isoDate(rhs.respondedAt) ?? .distantPast)
                    }
                return SocialFeedItem(post: post, responses: responses)
            }
    }

    private func shouldIncludeFeedPost(_ post: SocialFeedPost, now: Date) -> Bool {
        if let endedAt = effectiveFeedEndDate(for: post) {
            return endedAt >= now.addingTimeInterval(-12 * 60 * 60)
        }

        return true
    }

    private func effectiveFeedEndDate(for post: SocialFeedPost) -> Date? {
        if let endedAt = isoDate(post.endedAt) {
            return endedAt
        }
        guard let startsAt = isoDate(post.startsAt) else { return nil }
        let autoExpireDate = startsAt.addingTimeInterval(6 * 60 * 60)
        return autoExpireDate <= Date() ? autoExpireDate : nil
    }

    private func canViewerSeeFeedPost(
        _ post: SocialFeedPost,
        ownerID: String,
        viewerID: String,
        friendOwnerIDs: Set<String>,
        ownerGroups: [SocialFriendGroup]
    ) -> Bool {
        if ownerID == viewerID {
            return true
        }

        switch post.visibility {
        case .everyone:
            return true
        case .friends:
            return friendOwnerIDs.contains(ownerID)
        case .groups:
            guard friendOwnerIDs.contains(ownerID) else { return false }
            let visibleGroupIDs = Set(post.visibleGroupIDs)
            return ownerGroups.contains { group in
                visibleGroupIDs.contains(group.id) && group.memberIDs.contains(viewerID)
            }
        }
    }

    private func decodeFeedPosts(from data: [String: Any]) -> [SocialFeedPost] {
        let rawPosts = data["feedPosts"] as? [[String: Any]] ?? []
        return rawPosts.compactMap { item in
            guard let id = item["id"] as? String,
                  let ownerID = item["ownerID"] as? String,
                  let ownerUsername = item["ownerUsername"] as? String,
                  let ownerDisplayName = item["ownerDisplayName"] as? String,
                  let title = item["title"] as? String,
                  let location = item["location"] as? String,
                  let details = item["details"] as? String,
                  let createdAt = item["createdAt"] as? String else {
                return nil
            }

            let visibility = SocialFeedVisibility(rawValue: item["visibility"] as? String ?? "") ?? .friends
            let startsAt = item["startsAt"] as? String ?? createdAt
            let endedAt = emptyToNil(item["endedAt"] as? String) ?? emptyToNil(item["endsAt"] as? String)

            return SocialFeedPost(
                id: id,
                ownerID: ownerID,
                ownerUsername: ownerUsername,
                ownerDisplayName: ownerDisplayName,
                title: title,
                location: location,
                details: details,
                createdAt: createdAt,
                startsAt: startsAt,
                endedAt: endedAt,
                visibility: visibility,
                visibleGroupIDs: (item["visibleGroupIDs"] as? [String] ?? []).sorted()
            )
        }
    }

    private func feedPostData(_ post: SocialFeedPost) -> [String: Any] {
        [
            "id": post.id,
            "ownerID": post.ownerID,
            "ownerUsername": post.ownerUsername,
            "ownerDisplayName": post.ownerDisplayName,
            "title": post.title,
            "location": post.location,
            "details": post.details,
            "createdAt": post.createdAt,
            "startsAt": post.startsAt,
            "endedAt": post.endedAt ?? "",
            "visibility": post.visibility.rawValue,
            "visibleGroupIDs": post.visibleGroupIDs.sorted(),
        ]
    }

    private func decodeFeedResponses(from data: [String: Any]) -> [SocialFeedPresence] {
        let rawResponses = data["feedResponses"] as? [[String: Any]] ?? []
        return rawResponses.compactMap { item in
            guard let postID = item["postID"] as? String,
                  let userID = item["userID"] as? String,
                  let username = item["username"] as? String,
                  let displayName = item["displayName"] as? String,
                  let rawStatus = item["status"] as? String,
                  let status = SocialFeedPresenceStatus(rawValue: rawStatus),
                  let respondedAt = item["respondedAt"] as? String else {
                return nil
            }

            return SocialFeedPresence(
                postID: postID,
                userID: userID,
                username: username,
                displayName: displayName,
                status: status,
                respondedAt: respondedAt
            )
        }
    }

    private func feedResponseData(_ response: SocialFeedPresence) -> [String: Any] {
        [
            "postID": response.postID,
            "userID": response.userID,
            "username": response.username,
            "displayName": response.displayName,
            "status": response.status.rawValue,
            "respondedAt": response.respondedAt,
        ]
    }

    private func makeScheduleSnapshot(from data: [String: Any]?) -> SharedScheduleSnapshot? {
        guard let data else { return nil }
        let items = (data["items"] as? [[String: Any]] ?? []).map { item in
            SharedScheduleItem(
                id: item["id"] as? String ?? UUID().uuidString,
                title: item["title"] as? String ?? "",
                location: item["location"] as? String ?? "",
                startDate: item["startDate"] as? String ?? "",
                endDate: item["endDate"] as? String ?? "",
                isAllDay: item["isAllDay"] as? Bool ?? false,
                kind: item["kind"] as? String ?? "",
                badge: item["badge"] as? String
            )
        }
        return SharedScheduleSnapshot(
            semesterCode: data["semesterCode"] as? String ?? "",
            generatedAt: emptyToNil(data["generatedAt"] as? String),
            items: items,
            coverageStart: emptyToNil(data["coverageStart"] as? String),
            coverageEnd: emptyToNil(data["coverageEnd"] as? String)
        )
    }

    private func loadScheduleSnapshot(ownerID: String, viewerID: String) async throws -> SharedScheduleSnapshot {
        do {
            let friendViewSnapshot = try await getDocument(friendViewReference(ownerID: ownerID, viewerID: viewerID))
            if friendViewSnapshot.exists,
               let data = friendViewSnapshot.data(),
               data["items"] != nil,
               let currentSnapshot = makeScheduleSnapshot(from: data) {
                // Per-friend views are the canonical format. Returning immediately
                // avoids extra legacy document reads on every calendar open.
                return currentSnapshot
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        let userLegacySnapshot = try await loadUserDocLegacyScheduleSnapshot(ownerID: ownerID)
        if let userLegacySnapshot, !userLegacySnapshot.items.isEmpty {
            return userLegacySnapshot
        }

        do {
            let legacySnapshot = try await getDocument(firestore.collection("sharedSchedules").document(ownerID))
            let rootSnapshot = makeScheduleSnapshot(from: legacySnapshot.data())
            if let merged = mergeScheduleSnapshots(
                primary: userLegacySnapshot,
                fallback: rootSnapshot
            ) {
                return merged
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        return userLegacySnapshot ?? SharedScheduleSnapshot(
            semesterCode: "",
            generatedAt: nil,
            items: []
        )
    }

    private func mergeScheduleSnapshots(
        primary: SharedScheduleSnapshot?,
        fallback: SharedScheduleSnapshot?
    ) -> SharedScheduleSnapshot? {
        guard primary != nil || fallback != nil else { return nil }

        var mergedByID: [String: SharedScheduleItem] = [:]
        let primaryItems = primary?.items ?? []
        let fallbackItems = fallback?.items ?? []

        for item in fallbackItems {
            mergedByID[scheduleMergeKey(for: item)] = item
        }

        for item in primaryItems {
            mergedByID[scheduleMergeKey(for: item)] = item
        }

        let mergedItems = mergedByID.values.sorted { lhs, rhs in
            let lhsDate = isoDate(lhs.startDate) ?? .distantFuture
            let rhsDate = isoDate(rhs.startDate) ?? .distantFuture
            if lhsDate == rhsDate {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhsDate < rhsDate
        }

        return SharedScheduleSnapshot(
            semesterCode: emptyToNil(primary?.semesterCode) ?? fallback?.semesterCode ?? "",
            generatedAt: primary?.generatedAt ?? fallback?.generatedAt,
            items: mergedItems,
            coverageStart: primary?.coverageStart ?? fallback?.coverageStart,
            coverageEnd: primary?.coverageEnd ?? fallback?.coverageEnd
        )
    }

    private func loadUserDocLegacyScheduleSnapshot(ownerID: String) async throws -> SharedScheduleSnapshot? {
        let snapshot = try await getDocument(firestore.collection("users").document(ownerID))
        guard let data = snapshot.data(),
              let items = data["sharedScheduleLegacyItems"] as? [[String: Any]] else {
            return nil
        }

        return SharedScheduleSnapshot(
            semesterCode: data["sharedScheduleLegacySemesterCode"] as? String ?? "",
            generatedAt: emptyToNil(data["sharedScheduleLegacyGeneratedAt"] as? String),
            items: items.map { item in
                SharedScheduleItem(
                    id: item["id"] as? String ?? UUID().uuidString,
                    title: item["title"] as? String ?? "",
                    location: item["location"] as? String ?? "",
                    startDate: item["startDate"] as? String ?? "",
                    endDate: item["endDate"] as? String ?? "",
                    isAllDay: item["isAllDay"] as? Bool ?? false,
                    kind: item["kind"] as? String ?? "",
                    badge: item["badge"] as? String
                )
            }
        )
    }

    private func sharedScheduleItemData(_ item: SharedScheduleItem) -> [String: Any] {
        [
            "id": item.id,
            "title": item.title,
            "location": item.location,
            "startDate": item.startDate,
            "endDate": item.endDate,
            "isAllDay": item.isAllDay,
            "kind": item.kind,
            "badge": item.badge ?? "",
        ]
    }

    private func demoSuffix() -> String {
        String(UUID().uuidString.prefix(4)).uppercased()
    }

    private func demoScheduleItems() -> [SharedScheduleItem] {
        let calendar = Calendar.current
        let firstDay = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let secondDay = calendar.date(byAdding: .day, value: 2, to: firstDay) ?? firstDay
        let thirdDay = calendar.date(byAdding: .day, value: 4, to: firstDay) ?? firstDay
        let formatter = ISO8601DateFormatter()

        return [
            SharedScheduleItem(
                id: UUID().uuidString,
                title: "Demo Algorithms",
                location: "DCC 308",
                startDate: formatter.string(from: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: firstDay) ?? firstDay),
                endDate: formatter.string(from: calendar.date(bySettingHour: 11, minute: 50, second: 0, of: firstDay) ?? firstDay),
                isAllDay: false,
                kind: "classMeeting",
                badge: nil
            ),
            SharedScheduleItem(
                id: UUID().uuidString,
                title: "Demo Office Hours",
                location: "Amos Eaton 214",
                startDate: formatter.string(from: calendar.date(bySettingHour: 14, minute: 0, second: 0, of: secondDay) ?? secondDay),
                endDate: formatter.string(from: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: secondDay) ?? secondDay),
                isAllDay: false,
                kind: "personal",
                badge: nil
            ),
            SharedScheduleItem(
                id: UUID().uuidString,
                title: "Demo Exam Review",
                location: "Low 4050",
                startDate: formatter.string(from: calendar.date(bySettingHour: 18, minute: 0, second: 0, of: thirdDay) ?? thirdDay),
                endDate: formatter.string(from: calendar.date(bySettingHour: 19, minute: 15, second: 0, of: thirdDay) ?? thirdDay),
                isAllDay: false,
                kind: "classMeeting",
                badge: "exam"
            ),
        ]
    }

    private func signIn(email: String, password: String) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func createUser(email: String, password: String, auth: Auth) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            auth.createUser(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func createUser(email: String, password: String) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().createUser(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func signInAnonymously() async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signInAnonymously { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func linkAnonymousUser(_ user: User, credential: AuthCredential) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            user.link(with: credential) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func getDocument(_ reference: DocumentReference) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            reference.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func getDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: SocialError.invalidResponse)
                }
            }
        }
    }

    private func refreshModeratorClaim() async {
        guard let user = Auth.auth().currentUser else {
            canModerateSocialContent = false
            return
        }

        canModerateSocialContent = await withCheckedContinuation { continuation in
            user.getIDTokenResult { result, _ in
                continuation.resume(returning: result?.claims["moderator"] as? Bool == true)
            }
        }
    }

    private func setData(
        _ data: [String: Any],
        at reference: DocumentReference,
        merge: Bool = false
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data, merge: merge) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func updateData(_ data: [AnyHashable: Any], at reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.updateData(data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func deleteDocument(_ reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
#endif

    /// `quiet` operations run in the background: they neither clear the
    /// message the user is reading nor replace it with their own errors.
    private func runOperation(
        showSpinner: Bool = true,
        quiet: Bool = false,
        _ operation: () async throws -> Void
    ) async {
#if canImport(FirebaseCore)
        if isFirebaseAvailable, FirebaseApp.app() == nil {
            if !quiet {
                errorMessage = "Firebase is not configured yet. Add GoogleService-Info.plist to the app target."
            }
            isLoading = false
            return
        }
#endif
        if showSpinner {
            isLoading = true
        }
        if !quiet {
            errorMessage = nil
            statusMessage = nil
        }
        defer {
            if showSpinner {
                isLoading = false
            }
        }

        do {
            try await operation()
        } catch {
            let recovered = await handlePermissionErrorIfNeeded(error)
            if !recovered && !quiet {
                errorMessage = error.localizedDescription
            }
            #if DEBUG
            if quiet {
                print("⚠️ Background social operation failed:", error)
            }
            #endif
        }
    }

    private func loadGroupChatThreadStates(memberID: String) async throws -> [String: GroupChatThreadState] {
        let snapshot = try await getDocuments(
            firestore.collection("groupChats")
                .whereField("memberIDs", arrayContains: memberID)
        )

        var states = Dictionary(uniqueKeysWithValues: snapshot.documents.compactMap { document in
            makeGroupChatThreadState(from: document.data()).map { (document.documentID, $0) }
        })

        let campusSnapshot = try await getDocument(
            firestore.collection("groupChats").document(campusWideGroupThreadID)
        )
        if let data = campusSnapshot.data(),
           let campusState = makeGroupChatThreadState(from: data) {
            states[campusWideGroupThreadID] = campusState
        }
        return states
    }

    private func makeGroupChatThreadState(from data: [String: Any]) -> GroupChatThreadState? {
        let updatedAt = data["updatedAt"] as? String ?? ""
        guard !updatedAt.isEmpty else { return nil }
        return GroupChatThreadState(
            updatedAt: updatedAt,
            latestMessageID: emptyToNil(data["lastMessageID"] as? String),
            lastSenderID: emptyToNil(data["lastSenderID"] as? String)
        )
    }

    private var groupChatReadReceipts: [String: StoredGroupChatReadReceipt] {
        guard let data = UserDefaults.standard.data(forKey: groupChatReadReceiptsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: StoredGroupChatReadReceipt].self, from: data)) ?? [:]
    }

    private func persistGroupChatReadReceipts(_ receipts: [String: StoredGroupChatReadReceipt]) {
        guard let data = try? JSONEncoder().encode(receipts) else { return }
        UserDefaults.standard.set(data, forKey: groupChatReadReceiptsKey)
    }

    private func groupChatReadReceipt(
        storageKey: String,
        legacyThreadID: String
    ) -> StoredGroupChatReadReceipt? {
        var receipts = groupChatReadReceipts
        if let receipt = receipts[storageKey] {
            return receipt
        }

        let legacyDates = UserDefaults.standard.dictionary(forKey: legacyGroupChatLastSeenKey) as? [String: String] ?? [:]
        guard let legacyMessageAt = legacyDates[legacyThreadID],
              isoDate(legacyMessageAt) != nil else {
            return nil
        }
        let legacyMessageIDs = UserDefaults.standard.dictionary(forKey: legacyGroupChatLastSeenMessageIDKey) as? [String: String] ?? [:]
        let migrated = StoredGroupChatReadReceipt(
            messageID: legacyMessageIDs[legacyThreadID],
            messageAt: legacyMessageAt
        )
        receipts[storageKey] = migrated
        persistGroupChatReadReceipts(receipts)
        return migrated
    }

    private func groupChatReadReceiptKey(userID: String, threadID: String) -> String {
        "\(userID)|\(threadID)"
    }

    private func acknowledgeGroupChatThreadState(threadID: String) {
        guard let viewerID = currentUser?.id,
              let threadState = groupChatThreadStates[threadID],
              let version = groupChatThreadVersionKey(for: threadState)
        else {
            return
        }

        let key = groupChatReadReceiptKey(userID: viewerID, threadID: threadID)
        let existing = groupChatReadReceipt(storageKey: key, legacyThreadID: threadID)
        let acknowledgedVersions = appendingAcknowledgedThreadVersion(
            version,
            to: existing?.acknowledgedThreadVersions ?? []
        )
        let receipt = StoredGroupChatReadReceipt(
            messageID: existing?.messageID ?? threadState.latestMessageID,
            messageAt: existing?.messageAt ?? threadState.updatedAt,
            acknowledgedThreadVersions: acknowledgedVersions
        )

        var receipts = groupChatReadReceipts
        guard receipts[key] != receipt else { return }
        receipts[key] = receipt
        persistGroupChatReadReceipts(receipts)
        objectWillChange.send()
    }

    private func groupChatThreadVersionKey(for state: GroupChatThreadState) -> String? {
        groupChatThreadVersionKey(
            latestMessageID: state.latestMessageID,
            updatedAt: state.updatedAt
        )
    }

    private func groupChatThreadVersionKey(
        latestMessageID: String?,
        updatedAt: String
    ) -> String {
        if let latestMessageID, !latestMessageID.isEmpty {
            return "message:\(latestMessageID)"
        }
        return "legacy-date:\(updatedAt)"
    }

    private func appendingAcknowledgedThreadVersion(
        _ version: String,
        to existingVersions: [String]
    ) -> [String] {
        var updated = existingVersions.filter { $0 != version }
        updated.append(version)
        return Array(updated.suffix(64))
    }

    private func updateGroupChatThreadState(
        for reference: SocialGroupChatReference,
        messages: [SocialGroupChatMessage]
    ) {
        guard let lastMessage = messages.last else { return }
        groupChatThreadStates[reference.id] = GroupChatThreadState(
            updatedAt: lastMessage.createdAt,
            latestMessageID: lastMessage.id,
            lastSenderID: lastMessage.userID
        )
    }

    private func scheduleMergeKey(for item: SharedScheduleItem) -> String {
        [
            item.title,
            item.location,
            item.startDate,
            item.endDate,
            String(item.isAllDay),
            item.kind,
            item.badge ?? ""
        ].joined(separator: "|")
    }

    private func stableScheduleItemID(for event: ClassEvent) -> String {
        SocialHashing.fnv1a64Hex(Data(event.interactionKey.utf8))
    }

    private func normalizeDisplayName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func isoDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    // MARK: - Blocking and reporting

    func isBlocked(_ userID: String) -> Bool {
        blockedUserIDs.contains(userID)
    }

    /// Hides the person everywhere and ends the friendship, if any.
    func blockUser(_ userID: String) async {
        guard let viewerID = currentUser?.id, userID != viewerID else { return }
        blockedUserIDs.insert(userID)
        feedItems.removeAll { $0.post.ownerID == userID }
        searchResults.removeAll { $0.id == userID }
        quickAddSuggestions.removeAll { $0.id == userID }
        await saveBlockedUsers(viewerID: viewerID)
        if overview?.friends.contains(where: { $0.id == userID }) == true {
            await unfriend(userID)
        }
        statusMessage = "Blocked. You won’t see their messages or plans."
    }

    func unblockUser(_ userID: String) async {
        guard let viewerID = currentUser?.id else { return }
        blockedUserIDs.remove(userID)
        await saveBlockedUsers(viewerID: viewerID)
        statusMessage = "Unblocked."
    }

    @discardableResult
    func report(
        userID: String,
        kind: SocialReportKind,
        contextID: String?,
        excerpt: String?,
        reason: SocialReportReason
    ) async -> Bool {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let viewerID = currentUser?.id else { return false }
        do {
            try await setData([
                "reporterID": viewerID,
                "reportedUserID": userID,
                "kind": kind.rawValue,
                "contextID": contextID ?? "",
                "excerpt": String((excerpt ?? "").prefix(500)),
                "reason": reason.rawValue,
                "createdAt": FieldValue.serverTimestamp(),
            ], at: firestore.collection("reports").document())
            statusMessage = "Thanks. The report was sent for review."
            return true
        } catch {
            errorMessage = "Couldn’t send the report. Try again."
            return false
        }
#else
        return false
#endif
    }

    private func loadBlockedUsers(viewerID: String) async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let snapshot = try? await getDocument(blockedUsersReference(viewerID: viewerID)) else { return }
        blockedUserIDs = Set(snapshot.data()?["userIDs"] as? [String] ?? [])
        blockedUsersLoadedFor = viewerID
#endif
    }

    private func saveBlockedUsers(viewerID: String) async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        do {
            try await setData([
                "userIDs": Array(blockedUserIDs).sorted(),
                "updatedAt": nowISO(),
            ], at: blockedUsersReference(viewerID: viewerID))
        } catch {
            errorMessage = "Couldn’t save your block list."
        }
#endif
    }

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private func blockedUsersReference(viewerID: String) -> DocumentReference {
        firestore.collection("users").document(viewerID).collection("private").document("blocks")
    }
#endif
}

enum SocialReportKind: String {
    case message
    case user
    case plan
}

enum SocialReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case sexual
    case violence
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam: return "Spam or scam"
        case .harassment: return "Harassment or bullying"
        case .hate: return "Hate speech"
        case .sexual: return "Sexual content"
        case .violence: return "Violence or threats"
        case .other: return "Something else"
        }
    }
}

enum SocialError: LocalizedError {
    case firebaseNotLinked
    case invalidResponse
    case notAuthenticated
    case api(String)

    var errorDescription: String? {
        switch self {
        case .firebaseNotLinked:
            return "Firebase is not linked yet. Add FirebaseCore, FirebaseAuth, FirebaseFirestore, and GoogleService-Info.plist."
        case .invalidResponse:
            return "Firebase returned an invalid response."
        case .notAuthenticated:
            return "You need to sign in first."
        case .api(let message):
            return message
        }
    }
}
