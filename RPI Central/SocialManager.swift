import Foundation
import SwiftUI

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
#endif

@MainActor
final class SocialManager: ObservableObject {
    @Published private(set) var currentUser: SocialUser?
    @Published private(set) var overview: SocialOverviewResponse?
    @Published private(set) var friendGroups: [SocialFriendGroup] = []
    @Published private(set) var feedItems: [SocialFeedItem] = []
    @Published private(set) var searchResults: [SocialSearchResult] = []
    @Published private(set) var loadedFriendSchedule: FriendScheduleResponse?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var isFirebaseAvailable: Bool
    @Published private(set) var setupMessage: String

    private let receivedSharedEventsStorageKey = "received_shared_calendar_events_v1"
    private let deliveredSocialAlertIDsKey = "social.delivered_alert_ids_v1"
    private let socialNotificationsEnabledKey = "settings_social_notifications_enabled_v1"

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
        Task {
            await bootstrapFirebaseSession()
        }
#else
        self.isFirebaseAvailable = false
        self.setupMessage = "Add FirebaseCore, FirebaseAuth, and FirebaseFirestore, then add GoogleService-Info.plist."
#endif
    }

    var isAuthenticated: Bool {
        currentUser != nil
    }

    func logout() {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        detachRealtimeListeners()
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
#endif
        clearLocalSharedCalendarEvents()
        currentUser = nil
        overview = nil
        friendGroups = []
        feedItems = []
        searchResults = []
        loadedFriendSchedule = nil
        statusMessage = nil
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
                lastScheduleAt: viewer.lastScheduleAt
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
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedUsername.isEmpty else { throw SocialError.api("Username is required.") }

            let targetSnapshot = try await getDocuments(
                firestore.collection("users").whereField("usernameLower", isEqualTo: normalizedUsername).limit(to: 1)
            )
            guard let targetDoc = targetSnapshot.documents.first,
                  let target = makeUser(from: targetDoc) else {
                throw SocialError.api("That user was not found.")
            }

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
            statusMessage = "Friend group created."
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
            statusMessage = "Friend group removed."
            didSucceed = true
#else
            throw SocialError.firebaseNotLinked
#endif
        }
        return didSucceed
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
    func endFeedPost(_ postID: String) async -> Bool {
        var didSucceed = false
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let snapshot = try await getDocument(firestore.collection("users").document(viewer.id))
            let data = snapshot.data() ?? [:]
            let posts = decodeFeedPosts(from: data)
            var didUpdate = false
            let updatedPosts = posts.map { post -> SocialFeedPost in
                guard post.id == postID, post.ownerID == viewer.id, post.endedAt == nil else {
                    return post
                }
                didUpdate = true
                return SocialFeedPost(
                    id: post.id,
                    ownerID: post.ownerID,
                    ownerUsername: post.ownerUsername,
                    ownerDisplayName: post.ownerDisplayName,
                    title: post.title,
                    location: post.location,
                    details: post.details,
                    createdAt: post.createdAt,
                    startsAt: post.startsAt,
                    endedAt: nowISO(),
                    visibility: post.visibility,
                    visibleGroupIDs: post.visibleGroupIDs
                )
            }

            guard didUpdate else {
                throw SocialError.api("That activity is not available.")
            }

            try await updateData([
                "feedPosts": updatedPosts.map(feedPostData),
                "lastFeedPostAt": updatedPosts.first?.createdAt ?? "",
            ], at: firestore.collection("users").document(viewer.id))

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
                lastScheduleAt: viewer.lastScheduleAt
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
                    lastScheduleAt: now
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
                    self.feedItems = []
                    self.searchResults = []
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
                    schedulePreviewCount: scheduleCounts[user.id] ?? 0
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
            friendGroups = try await loadFriendGroups(ownerID: viewer.id)
        } catch {
            if isPermissionDenied(error) {
                friendGroups = []
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
        guard let user = Auth.auth().currentUser else { return }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
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
            lastScheduleAt: lastScheduleAt.isEmpty ? nil : lastScheduleAt
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
            lastScheduleAt: shareSchedule ? createdAt : nil
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
        let userSnapshot = try await getDocument(firestore.collection("users").document(ownerID))
        if let data = userSnapshot.data(), data["friendGroups"] != nil {
            return decodeFriendGroups(from: data)
        }

        do {
            let snapshot = try await getDocuments(
                firestore.collection("friendGroups")
                    .whereField("ownerID", isEqualTo: ownerID)
            )

            return snapshot.documents
                .compactMap(makeFriendGroup)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            if isPermissionDenied(error) {
                return []
            }
            throw error
        }
    }

    private func saveFriendGroups(_ groups: [SocialFriendGroup], ownerID: String) async throws {
        try await updateData([
            "friendGroups": groups.map(friendGroupData)
        ], at: firestore.collection("users").document(ownerID))
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
            eventDate: emptyToNil(data["eventDate"] as? String)
        )
    }

    private func socialAlertData(
        id: String,
        senderID: String,
        type: String,
        title: String,
        body: String,
        eventDate: Date?
    ) -> [String: Any] {
        [
            "id": id,
            "senderID": senderID,
            "type": type,
            "title": title,
            "body": body,
            "createdAt": nowISO(),
            "eventDate": eventDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
        ]
    }

    private func sendSocialAlert(
        to recipientIDs: [String],
        type: String,
        title: String,
        body: String,
        eventDate: Date?
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
                    eventDate: eventDate
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
        guard socialNotificationsEnabled else {
            delivered.formUnion(alerts.map(\.id))
            UserDefaults.standard.set(Array(delivered.sorted().suffix(400)), forKey: deliveredSocialAlertIDsKey)
            return
        }

        NotificationManager.requestAuthorization()
        for alert in alerts.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard !delivered.contains(alert.id) else { continue }
            let triggerDate = isoDate(alert.eventDate) ?? Date()
            NotificationManager.scheduleSocialNotification(
                identifier: "social.\(alert.id)",
                title: alert.title,
                body: alert.body,
                deliverAt: triggerDate > Date() ? min(triggerDate, Date().addingTimeInterval(60)) : nil
            )
            delivered.insert(alert.id)
        }

        let trimmed = Array(delivered.sorted().suffix(400))
        UserDefaults.standard.set(trimmed, forKey: deliveredSocialAlertIDsKey)
    }

    private var socialNotificationsEnabled: Bool {
        if UserDefaults.standard.object(forKey: socialNotificationsEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: socialNotificationsEnabledKey)
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
            lastScheduleAt: emptyToNil(data["lastScheduleAt"] as? String)
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
            mergedByID[item.id] = item
        }

        for item in primaryItems {
            mergedByID[item.id] = item
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
        let startWindow = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 120, to: now) ?? now
        let enrollmentSemesterByID = Dictionary(uniqueKeysWithValues: viewModel.enrolledCourses.map { ($0.id, $0.semesterCode) })

        return viewModel.events
            .filter { event in
                guard event.startDate <= horizon else { return false }
                guard event.endDate >= startWindow else { return false }
                if let visibleToFriendID, event.kind == .personal {
                    return viewModel.personalEventVisibleToFriend(
                        visibleToFriendID,
                        event: event,
                        groupMembersByID: groupMembersByID
                    )
                }
                if let enrollmentID = event.enrollmentID {
                    return enrollmentSemesterByID[enrollmentID] == viewModel.currentSemester.rawValue
                }
                return true
            }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                SharedScheduleItem(
                    id: event.id.uuidString,
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
