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
    @Published private(set) var searchResults: [SocialSearchResult] = []
    @Published private(set) var loadedFriendSchedule: FriendScheduleResponse?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var isFirebaseAvailable: Bool
    @Published private(set) var setupMessage: String

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
        currentUser = nil
        overview = nil
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

    func syncSchedule(from calendarViewModel: CalendarViewModel) async {
        await runOperation(showSpinner: false) {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
            guard let viewer = currentUser else { throw SocialError.notAuthenticated }
            let now = nowISO()
            let snapshot = makeScheduleSnapshot(from: calendarViewModel)
            try await setData([
                "ownerID": viewer.id,
                "semesterCode": calendarViewModel.currentSemester.rawValue,
                "generatedAt": now,
                "items": snapshot.map(sharedScheduleItemData),
            ], at: firestore.collection("sharedSchedules").document(viewer.id))

            try await updateData([
                "lastScheduleAt": now,
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

            let scheduleDoc = try await getDocument(firestore.collection("sharedSchedules").document(friendID))
            let schedule = makeScheduleSnapshot(from: scheduleDoc.data()) ?? SharedScheduleSnapshot(
                semesterCode: "",
                generatedAt: nil,
                items: []
            )
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
                    self.currentUser = nil
                    self.overview = nil
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

        do {
            try await refreshAuthTokenIfNeeded(forceRefresh: true)
            try await refreshOverviewInternal()
            errorMessage = nil
            statusMessage = "Social connection restored."
        } catch {
            currentUser = nil
            overview = nil
            searchResults = []
            loadedFriendSchedule = nil
            errorMessage = "Social access was denied. Sign in again to refresh your phone's session."
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

        try await setData([
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
        ], at: context.firestore.collection("users").document(user.id))

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
        for user in users where user.shareSchedule {
            do {
                let snapshot = try await getDocument(firestore.collection("sharedSchedules").document(user.id))
                let items = snapshot.data()?["items"] as? [[String: Any]] ?? []
                counts[user.id] = items.count
            } catch {
                // Preview counts are cosmetic. A missing or denied schedule should not break the entire social hub.
                counts[user.id] = 0
            }
        }
        return counts
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

    private func makeScheduleSnapshot(from viewModel: CalendarViewModel) -> [SharedScheduleItem] {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 21, to: now) ?? now
        let enrollmentSemesterByID = Dictionary(uniqueKeysWithValues: viewModel.enrolledCourses.map { ($0.id, $0.semesterCode) })

        return viewModel.events
            .filter { event in
                guard event.startDate <= horizon else { return false }
                if let enrollmentID = event.enrollmentID {
                    return enrollmentSemesterByID[enrollmentID] == viewModel.currentSemester.rawValue
                }
                return event.endDate >= now
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
