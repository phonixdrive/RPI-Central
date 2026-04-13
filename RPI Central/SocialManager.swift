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

@MainActor
final class SocialManager: ObservableObject {
    static let defaultChatPushRelayBaseURL = "https://rpi-central-web.onrender.com"

    private struct GroupChatThreadState {
        let updatedAt: String
        let lastSenderID: String?
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
    @Published private(set) var loadedFriendSchedule: FriendScheduleResponse?
    @Published private(set) var activeGroupChatID: String?
    @Published private var groupChatThreadStates: [String: GroupChatThreadState] = [:]
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
    private let groupChatLastSeenKey = "social.group_chat_last_seen_v1"
    private let chatPushRelayBaseURLKey = "chat_push_relay_base_url_v1"
    private var pushTokenObserver: NSObjectProtocol? = nil

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var listenerRegistrations: [ListenerRegistration] = []
    private var activeListenerUserID: String?
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
    }

    var isAuthenticated: Bool {
        currentUser != nil
    }

    var canModerateSocialContent: Bool {
        isModeratorIdentity(currentUser)
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
        activeGroupChatID = nil
        statusMessage = nil
    }

    func loadQuickAddSuggestions() async {
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }

            let incoming = Set(overview?.incomingRequests.compactMap { $0.fromUser?.id } ?? [])
            let outgoing = Set(overview?.outgoingRequests.compactMap { $0.toUser?.id } ?? [])
            let friends = Set(overview?.friends.map(\.id) ?? [])

            let snapshot = try await getDocuments(
                firestore.collection("users")
            )

            quickAddSuggestions = snapshot.documents
                .compactMap(makeUser)
                .filter { user in
                    user.id != viewer.id &&
                    !friends.contains(user.id) &&
                    !incoming.contains(user.id) &&
                    !outgoing.contains(user.id) &&
                    !isDemoUser(user)
                }
                .sorted { lhs, rhs in
                    lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
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
                        areFriends: false,
                        hasPendingIncoming: false,
                        hasPendingOutgoing: false
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
    }

    func markGroupChatSeen(_ reference: SocialGroupChatReference, latestMessageAt: String? = nil) {
        let threadUpdatedAt = groupChatThreadStates[reference.id]?.updatedAt
        let seenValue: String
        if let latestMessageAt,
           let latestDate = isoDate(latestMessageAt),
           let threadUpdatedAt,
           let threadDate = isoDate(threadUpdatedAt) {
            seenValue = threadDate > latestDate ? threadUpdatedAt : latestMessageAt
        } else {
            seenValue = latestMessageAt ?? threadUpdatedAt ?? nowISO()
        }
        var stored = groupChatLastSeenValues
        stored[reference.id] = seenValue
        UserDefaults.standard.set(stored, forKey: groupChatLastSeenKey)
        objectWillChange.send()
    }

    func hasUnreadMessages(in reference: SocialGroupChatReference) -> Bool {
        guard let viewer = currentUser,
              let threadState = groupChatThreadStates[reference.id],
              threadState.lastSenderID != viewer.id,
              let updatedAt = isoDate(threadState.updatedAt) else {
            return false
        }

        guard let lastSeenRaw = groupChatLastSeenValues[reference.id],
              let lastSeen = isoDate(lastSeenRaw) else {
            return true
        }

        return updatedAt > lastSeen
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
                .filter { $0.id != viewer.id }
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

            try await setData([
                "members": [viewer.id, demoFriend.id].sorted(),
                "createdAt": nowISO(),
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
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }

            let uniqueEnrollments = Dictionary(uniqueKeysWithValues: enrollments.map { ($0.id, $0) }).values
            for enrollment in uniqueEnrollments {
                let courseCommunity = makeCourseCommunity(
                    kind: .course,
                    course: enrollment.course,
                    section: nil,
                    semesterCode: nil,
                    viewerID: viewer.id
                )
                try await ensureCourseCommunityMembership(courseCommunity, viewerID: viewer.id)

                let sectionCommunity = makeCourseCommunity(
                    kind: .section,
                    course: enrollment.course,
                    section: enrollment.section,
                    semesterCode: enrollment.semesterCode,
                    viewerID: viewer.id
                )
                try await ensureCourseCommunityMembership(sectionCommunity, viewerID: viewer.id)
            }
            courseCommunities = try await loadCourseCommunities(memberID: viewer.id)
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

            var votes = existing.votesByUserID
            if let optionID, existing.options.contains(where: { $0.id == optionID }) {
                if votes[viewer.id] == optionID {
                    votes.removeValue(forKey: viewer.id)
                } else {
                    votes[viewer.id] = optionID
                }
            } else {
                votes.removeValue(forKey: viewer.id)
            }

            try await updateData(["votesByUserID": votes], at: pollRef)
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
                "lastSenderID": viewer.id,
                "memberIDs": reference.memberIDs,
                "title": reference.title,
                "subtitle": reference.subtitle,
                "sourceKind": reference.sourceKind.rawValue,
            ], at: threadRef)

            groupChatThreadStates[reference.id] = GroupChatThreadState(
                updatedAt: message.createdAt,
                lastSenderID: viewer.id
            )

            if reference.sourceKind != .campusGroup {
                let deliveredViaRelay = try await triggerGroupChatPushIfPossible(
                    for: reference,
                    message: message
                )

                if !deliveredViaRelay {
                    try await sendSocialAlert(
                        to: reference.memberIDs,
                        type: "groupMessage",
                        title: reference.title,
                        body: "\(viewer.displayName): \(trimmedBody)",
                        eventDate: nil,
                        contextID: reference.id
                    )
                }
            }

            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }

        return didSucceed
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
                threadTitle: reference.title
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
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty else {
                throw SocialError.api("Activity title is required.")
            }
            let sanitizedGroupIDs = Array(Set(groupIDs)).sorted()
            if visibility == .groups && sanitizedGroupIDs.isEmpty {
                throw SocialError.api("Choose at least one group for a group-only activity.")
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
                title: "\(viewer.displayName) posted an activity",
                body: normalizedLocation.isEmpty
                    ? "\(normalizedTitle) is up on the campus feed."
                    : "\(normalizedTitle) at \(normalizedLocation).",
                eventDate: startsAt
            )

            try await refreshOverviewInternal()
            statusMessage = "Activity posted."
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
                throw SocialError.api("You cannot end that activity.")
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
                throw SocialError.api("That activity is not available.")
            }

            try await updateData([
                "feedPosts": updatedPosts.map(feedPostData),
                "lastFeedPostAt": updatedPosts.first?.createdAt ?? "",
            ], at: firestore.collection("users").document(targetOwnerID))

            try await refreshOverviewInternal()
            statusMessage = "Activity ended."
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
                throw SocialError.api("That activity is not available.")
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
            statusMessage = "Activity removed."
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
            statusMessage = shareSchedule ? "Schedule sharing enabled." : "Schedule sharing disabled."
#else
            throw SocialError.firebaseNotLinked
#endif
        }
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

    func syncSchedule(from calendarViewModel: CalendarViewModel) async {
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let now = nowISO()
            let friendshipsSnapshot = try await getDocuments(
                firestore.collection("friendships").whereField("members", arrayContains: viewer.id)
            )
            let friendIDs = friendshipsSnapshot.documents.compactMap { snapshot -> String? in
                let members = snapshot.data()["members"] as? [String] ?? []
                return members.first(where: { $0 != viewer.id })
            }
            let groups = try await loadFriendGroups(ownerID: viewer.id)
            let groupMembersByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Set($0.memberIDs)) })
            let rootRef = firestore.collection("sharedSchedules").document(viewer.id)
            let legacyItems = makeLegacyScheduleSnapshot(from: calendarViewModel)

            try await setData([
                "ownerID": viewer.id,
                "semesterCode": calendarViewModel.currentSemester.rawValue,
                "generatedAt": now,
                "items": legacyItems.map(sharedScheduleItemData),
            ], at: rootRef)

            for friendID in friendIDs {
                let visibleItems = makeScheduleSnapshot(
                    from: calendarViewModel,
                    visibleToFriendID: friendID,
                    groupMembersByID: groupMembersByID
                )
                try await writeFriendViewSchedule(
                    ownerID: viewer.id,
                    viewerID: friendID,
                    semesterCode: calendarViewModel.currentSemester.rawValue,
                    generatedAt: now,
                    items: visibleItems
                )
            }

            try await updateData([
                "lastScheduleAt": now,
                "sharedScheduleItemCount": legacyItems.count,
                "sharedScheduleLegacySemesterCode": calendarViewModel.currentSemester.rawValue,
                "sharedScheduleLegacyGeneratedAt": now,
                "sharedScheduleLegacyItems": legacyItems.map(sharedScheduleItemData),
                "sharedCourseKeys": sharedCourseKeys(from: calendarViewModel),
                "sharedSectionKeys": sharedSectionKeys(from: calendarViewModel),
            ], at: firestore.collection("users").document(viewer.id))

            if var current = currentUser {
                current = SocialUser(
                    id: current.id,
                    username: current.username,
                    displayName: current.displayName,
                    email: current.email,
                    isGuest: current.isGuest,
                    shareSchedule: current.shareSchedule,
                    shareLocation: current.shareLocation,
                    createdAt: current.createdAt,
                    lastScheduleAt: now,
                    sharedCourseKeys: sharedCourseKeys(from: calendarViewModel),
                    sharedSectionKeys: sharedSectionKeys(from: calendarViewModel)
                )
                currentUser = current
            }
            try await refreshOverviewInternal()
#else
            throw SocialError.firebaseNotLinked
#endif
        }
    }

    func loadFriendSchedule(friendID: String) async {
        loadedFriendSchedule = nil
        await runOperation {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            guard try await friendshipExists(viewer.id, friendID) else {
                throw SocialError.api("You are not friends with that user.")
            }

            guard let owner = try await fetchUser(id: friendID) else {
                throw SocialError.api("That user was not found.")
            }
            guard owner.shareSchedule else {
                throw SocialError.api("That user is not sharing their schedule.")
            }

            let schedule = try await loadScheduleSnapshot(ownerID: friendID, viewerID: viewer.id)
            loadedFriendSchedule = FriendScheduleResponse(owner: owner, schedule: schedule)
#else
            throw SocialError.firebaseNotLinked
#endif
        }
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

        let friendshipsSnapshot = try await getDocuments(
            firestore.collection("friendships").whereField("members", arrayContains: viewer.id)
        )
        let friendIDs = friendshipsSnapshot.documents.compactMap { snapshot -> String? in
            let members = snapshot.data()["members"] as? [String] ?? []
            return members.first(where: { $0 != viewer.id })
        }
        let friendUsers = try await fetchUsers(ids: friendIDs)
        let scheduleCounts = await fetchScheduleCounts(for: Array(friendUsers.values))

        let friends = friendUsers.values
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { user in
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
                    schedulePreviewCount: scheduleCounts[user.id] ?? 0,
                    sharedCourseKeys: user.sharedCourseKeys,
                    sharedSectionKeys: user.sharedSectionKeys
                )
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
            let ownedGroups = try await loadFriendGroups(ownerID: viewer.id)
            try await persistOwnedFriendGroupsToCollection(ownedGroups, ownerID: viewer.id)
            friendGroups = try await loadVisibleFriendGroups(viewerID: viewer.id, fallbackOwnedGroups: ownedGroups)
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
        activeListenerUserID = nil
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

        try await setData([
            "displayName": displayName,
            "displayNameLower": displayName.lowercased(),
            "username": username,
            "usernameLower": username.lowercased(),
            "email": email,
            "isGuest": isGuest,
            "shareSchedule": shareSchedule,
            "shareLocation": shareLocation,
            "createdAt": createdAt,
            "lastScheduleAt": lastScheduleAt,
            "sharedCourseKeys": existing?.sharedCourseKeys ?? [],
            "sharedSectionKeys": existing?.sharedSectionKeys ?? [],
        ], at: ref)

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
            "email": user.email,
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

    private func fetchUsers(ids: [String]) async throws -> [String: SocialUser] {
        var result: [String: SocialUser] = [:]
        for id in ids where result[id] == nil {
            if let user = try await fetchUser(id: id) {
                result[id] = user
            }
        }
        return result
    }

    private func fetchUser(id: String) async throws -> SocialUser? {
        let snapshot = try await getDocument(firestore.collection("users").document(id))
        return makeUser(from: snapshot)
    }

    private func fetchScheduleCounts(for users: [SocialUser]) async -> [String: Int] {
        var counts: [String: Int] = [:]
        guard let viewerID = currentUser?.id else { return counts }
        for user in users where user.shareSchedule {
            do {
                let schedule = try await loadScheduleSnapshot(ownerID: user.id, viewerID: viewerID)
                if !schedule.items.isEmpty {
                    counts[user.id] = schedule.items.count
                    continue
                }
                if let legacySnapshot = try await loadUserDocLegacyScheduleSnapshot(ownerID: user.id),
                   !legacySnapshot.items.isEmpty {
                    counts[user.id] = legacySnapshot.items.count
                    continue
                }
                counts[user.id] = 0
            } catch {
                // Preview counts are cosmetic. A missing or denied schedule should not break the entire social hub.
                counts[user.id] = 0
            }
        }
        return counts
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

    private func isModeratorIdentity(_ user: SocialUser?) -> Bool {
        let username = normalizedModeratorHandle(user?.username)
        let displayName = user?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return username == "neilshrestha20061" || displayName == "phonixdrive"
    }

    private func normalizedModeratorHandle(_ username: String?) -> String {
        (username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
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
                hasPendingOutgoing: true
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
                hasPendingOutgoing: true
            )
        }
    }

    private func sendFriendRequestInternal(to target: SocialUser) async throws {
        guard let viewer = currentUser else { throw SocialError.notAuthenticated }
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
        return SocialUser(
            id: snapshot.documentID,
            username: data["username"] as? String ?? "",
            displayName: data["displayName"] as? String ?? "",
            email: data["email"] as? String ?? "",
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
            if isDocumentMissing(error) {
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
            try await updateData([
                "title": reference.title,
                "subtitle": reference.subtitle,
                "sourceKind": reference.sourceKind.rawValue,
                "memberIDs": reference.memberIDs,
                "isCampusWide": reference.sourceKind == .campusGroup,
            ], at: ref)
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
        var ownerIDs = friendOwnerIDSet
        ownerIDs.insert(viewer.id)

        do {
            let publicUsersSnapshot = try await getDocuments(
                firestore.collection("users")
                    .order(by: "lastFeedPostAt", descending: true)
                    .limit(to: 60)
            )
            for document in publicUsersSnapshot.documents {
                ownerIDs.insert(document.documentID)
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        var posts: [SocialFeedPost] = []
        var responsesByPostID: [String: [SocialFeedPresence]] = [:]

        for ownerID in ownerIDs {
            let snapshot: DocumentSnapshot
            do {
                snapshot = try await getDocument(firestore.collection("users").document(ownerID))
            } catch {
                if isPermissionDenied(error) {
                    continue
                }
                throw error
            }
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
            items: items
        )
    }

    private func loadScheduleSnapshot(ownerID: String, viewerID: String) async throws -> SharedScheduleSnapshot {
        var friendViewResult: SharedScheduleSnapshot?
        do {
            let friendViewSnapshot = try await getDocument(friendViewReference(ownerID: ownerID, viewerID: viewerID))
            if friendViewSnapshot.exists,
               let data = friendViewSnapshot.data(),
               data["items"] != nil {
                friendViewResult = makeScheduleSnapshot(from: data)
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        let userLegacySnapshot = try await loadUserDocLegacyScheduleSnapshot(ownerID: ownerID)
        if let merged = mergeScheduleSnapshots(primary: friendViewResult, fallback: userLegacySnapshot),
           !merged.items.isEmpty {
            return merged
        }

        do {
            let legacySnapshot = try await getDocument(firestore.collection("sharedSchedules").document(ownerID))
            let rootSnapshot = makeScheduleSnapshot(from: legacySnapshot.data())
            if let merged = mergeScheduleSnapshots(
                primary: mergeScheduleSnapshots(primary: friendViewResult, fallback: userLegacySnapshot),
                fallback: rootSnapshot
            ) {
                return merged
            }
        } catch {
            if !isPermissionDenied(error) {
                throw error
            }
        }

        return friendViewResult ?? userLegacySnapshot ?? SharedScheduleSnapshot(
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
            items: mergedItems
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

    private func makeLegacyScheduleSnapshot(from viewModel: CalendarViewModel) -> [SharedScheduleItem] {
        makeScheduleSnapshot(from: viewModel)
            .filter { $0.kind != CalendarEventKind.personal.rawValue }
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

    private func setData(_ data: [String: Any], at reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data) { error in
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

    private func runOperation(
        showSpinner: Bool = true,
        _ operation: () async throws -> Void
    ) async {
#if canImport(FirebaseCore)
        if isFirebaseAvailable, FirebaseApp.app() == nil {
            errorMessage = "Firebase is not configured yet. Add GoogleService-Info.plist to the app target."
            isLoading = false
            return
        }
#endif
        if showSpinner {
            isLoading = true
        }
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }

        do {
            try await operation()
        } catch {
            let recovered = await handlePermissionErrorIfNeeded(error)
            if !recovered {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeScheduleSnapshot(
        from viewModel: CalendarViewModel,
        visibleToFriendID: String? = nil,
        groupMembersByID: [String: Set<String>] = [:]
    ) -> [SharedScheduleItem] {
        let now = Date()
        let calendar = Calendar.current
        let startWindow = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -7, to: now) ?? now
        )
        let endWindow = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: 7, to: now) ?? now
        )
        let dayCount = calendar.dateComponents([.day], from: startWindow, to: endWindow).day ?? 14

        var seenInteractionKeys: Set<String> = []
        var collectedEvents: [ClassEvent] = []

        for offset in 0...max(dayCount, 0) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startWindow) else { continue }
            for event in viewModel.events(on: day) {
                if let visibleToFriendID, event.kind == .personal {
                    guard viewModel.personalEventVisibleToFriend(
                        visibleToFriendID,
                        event: event,
                        groupMembersByID: groupMembersByID
                    ) else {
                        continue
                    }
                }

                let key = event.interactionKey
                guard seenInteractionKeys.insert(key).inserted else { continue }
                collectedEvents.append(event)
            }
        }

        return collectedEvents
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                SharedScheduleItem(
                    id: stableScheduleItemID(for: event),
                    title: event.title,
                    location: event.location,
                    startDate: ISO8601DateFormatter().string(from: event.startDate),
                    endDate: ISO8601DateFormatter().string(from: event.endDate),
                    isAllDay: event.isAllDay,
                    kind: event.kind.rawValue,
                    badge: event.badge?.rawValue
                )
            }
    }

    private func loadGroupChatThreadStates(memberID: String) async throws -> [String: GroupChatThreadState] {
        let snapshot = try await getDocuments(
            firestore.collection("groupChats")
                .whereField("memberIDs", arrayContains: memberID)
        )

        return Dictionary(uniqueKeysWithValues: snapshot.documents.compactMap { document in
            let data = document.data()
            let updatedAt = data["updatedAt"] as? String ?? ""
            guard !updatedAt.isEmpty else { return nil }
            return (
                document.documentID,
                GroupChatThreadState(
                    updatedAt: updatedAt,
                    lastSenderID: emptyToNil(data["lastSenderID"] as? String)
                )
            )
        })
    }

    private var groupChatLastSeenValues: [String: String] {
        UserDefaults.standard.dictionary(forKey: groupChatLastSeenKey) as? [String: String] ?? [:]
    }

    private func updateGroupChatThreadState(
        for reference: SocialGroupChatReference,
        messages: [SocialGroupChatMessage]
    ) {
        guard let lastMessage = messages.last else { return }
        groupChatThreadStates[reference.id] = GroupChatThreadState(
            updatedAt: lastMessage.createdAt,
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
        event.interactionKey
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
