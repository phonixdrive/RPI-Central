//
//  ServerSpaces.swift
//  RPI Central
//
//  Invite-only spaces for something with an on/off status, like a game
//  server. The owner invites friends and says whether the server is up.
//  Members can ask for it to be started and say they're on; that times out
//  after 24 hours in case they forget. Only members ever see a space.
//

import SwiftUI
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

struct ServerSpace: Identifiable, Equatable {
    let id: String
    var name: String
    var address: String
    var ownerID: String
    var ownerName: String
    var memberIDs: [String]
    var serverOnline: Bool
    var statusUpdatedAt: Date?
    var statusUpdatedByName: String?
    var requestedByID: String?
    var requestedByName: String?
    var requestedAt: Date?

    /// A start request counts for six hours, until the server comes up.
    func pendingRequest(now: Date = Date()) -> (name: String, at: Date)? {
        guard !serverOnline, let requestedAt, let requestedByName,
              now.timeIntervalSince(requestedAt) < 6 * 3600 else { return nil }
        return (requestedByName, requestedAt)
    }
}

struct ServerPresence: Identifiable, Equatable {
    let id: String // user ID
    var displayName: String
    var since: Date
    var expiresAt: Date

    func isActive(now: Date = Date()) -> Bool { expiresAt > now }
}

@MainActor
final class ServerSpacesModel: ObservableObject {
    static let shared = ServerSpacesModel()
    static let presenceDuration: TimeInterval = 24 * 3600

    @Published private(set) var spaces: [ServerSpace] = []
    @Published private(set) var presenceBySpace: [String: [ServerPresence]] = [:]
    @Published var errorMessage: String?

    private(set) var userID: String?

    #if canImport(FirebaseFirestore)
    private var db: Firestore { Firestore.firestore() }
    private var spacesListener: ListenerRegistration?
    private var presenceListeners: [String: ListenerRegistration] = [:]
    #endif

    /// Starts or stops listening when the signed-in user changes.
    func start(userID: String?) {
        guard userID != self.userID else { return }
        stop()
        self.userID = userID
        guard let userID else { return }
        #if canImport(FirebaseFirestore)
        spacesListener = db.collection("serverSpaces")
            .whereField("memberIDs", arrayContains: userID)
            .addSnapshotListener { [weak self] snapshot, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let spaces = (snapshot?.documents ?? []).compactMap(Self.space(from:))
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.spaces = spaces
                    self.syncPresenceListeners()
                }
            }
        #endif
    }

    func stop() {
        #if canImport(FirebaseFirestore)
        spacesListener?.remove()
        spacesListener = nil
        presenceListeners.values.forEach { $0.remove() }
        presenceListeners = [:]
        #endif
        spaces = []
        presenceBySpace = [:]
        userID = nil
    }

    func onlineMembers(in space: ServerSpace, now: Date = Date()) -> [ServerPresence] {
        (presenceBySpace[space.id] ?? [])
            .filter { $0.isActive(now: now) }
            .sorted { $0.since < $1.since }
    }

    func isOn(_ space: ServerSpace, now: Date = Date()) -> Bool {
        guard let userID else { return false }
        return onlineMembers(in: space, now: now).contains { $0.id == userID }
    }

    // MARK: Changes

    func create(name: String, address: String, ownerName: String, invitedIDs: [String]) async {
        guard let userID else { return }
        #if canImport(FirebaseFirestore)
        await run {
            try await self.db.collection("serverSpaces").document().setData([
                "name": String(name.prefix(40)),
                "address": String(address.prefix(100)),
                "ownerID": userID,
                "ownerName": ownerName,
                "memberIDs": [userID] + invitedIDs.filter { $0 != userID },
                "serverOnline": false,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        }
        #endif
    }

    func setServerOnline(_ online: Bool, in space: ServerSpace, byName name: String) async {
        #if canImport(FirebaseFirestore)
        var fields: [String: Any] = [
            "serverOnline": online,
            "statusUpdatedAt": FieldValue.serverTimestamp(),
            "statusUpdatedByName": name,
        ]
        if online {
            fields["requestedByID"] = FieldValue.delete()
            fields["requestedByName"] = FieldValue.delete()
            fields["requestedAt"] = FieldValue.delete()
        }
        await run { try await self.db.collection("serverSpaces").document(space.id).updateData(fields) }
        #endif
    }

    func requestStart(_ space: ServerSpace, byName name: String) async {
        guard let userID else { return }
        #if canImport(FirebaseFirestore)
        await run {
            try await self.db.collection("serverSpaces").document(space.id).updateData([
                "requestedByID": userID,
                "requestedByName": name,
                "requestedAt": FieldValue.serverTimestamp(),
            ])
        }
        #endif
    }

    /// "I'm on" lasts 24 hours unless you turn it off sooner.
    func setOnServer(_ on: Bool, in space: ServerSpace, displayName: String) async {
        guard let userID else { return }
        #if canImport(FirebaseFirestore)
        let ref = db.collection("serverSpaces").document(space.id).collection("presence").document(userID)
        await run {
            if on {
                let now = Date()
                try await ref.setData([
                    "displayName": displayName,
                    "since": Timestamp(date: now),
                    "expiresAt": Timestamp(date: now.addingTimeInterval(Self.presenceDuration)),
                ])
            } else {
                try await ref.delete()
            }
        }
        #endif
    }

    /// The owner marks someone off the server.
    func removePresence(of memberID: String, in space: ServerSpace) async {
        #if canImport(FirebaseFirestore)
        await run {
            try await self.db.collection("serverSpaces").document(space.id).collection("presence").document(memberID).delete()
        }
        #endif
    }

    func invite(_ ids: [String], to space: ServerSpace) async {
        guard !ids.isEmpty else { return }
        #if canImport(FirebaseFirestore)
        await run {
            try await self.db.collection("serverSpaces").document(space.id).updateData(["memberIDs": FieldValue.arrayUnion(ids)])
        }
        #endif
    }

    func removeMember(_ memberID: String, from space: ServerSpace) async {
        #if canImport(FirebaseFirestore)
        await run {
            let ref = self.db.collection("serverSpaces").document(space.id)
            try? await ref.collection("presence").document(memberID).delete()
            try await ref.updateData(["memberIDs": FieldValue.arrayRemove([memberID])])
        }
        #endif
    }

    func leave(_ space: ServerSpace) async {
        guard let userID else { return }
        #if canImport(FirebaseFirestore)
        await run {
            let ref = self.db.collection("serverSpaces").document(space.id)
            try? await ref.collection("presence").document(userID).delete()
            try await ref.updateData(["memberIDs": FieldValue.arrayRemove([userID])])
        }
        #endif
    }

    func update(_ space: ServerSpace, name: String, address: String) async {
        #if canImport(FirebaseFirestore)
        await run {
            try await self.db.collection("serverSpaces").document(space.id).updateData([
                "name": String(name.prefix(40)),
                "address": String(address.prefix(100)),
            ])
        }
        #endif
    }

    func delete(_ space: ServerSpace) async {
        #if canImport(FirebaseFirestore)
        await run {
            let ref = self.db.collection("serverSpaces").document(space.id)
            for presence in self.presenceBySpace[space.id] ?? [] {
                try? await ref.collection("presence").document(presence.id).delete()
            }
            try await ref.delete()
        }
        #endif
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = "Couldn’t update the server. Check your connection and try again."
            #if DEBUG
            print("Server space update failed:", error)
            #endif
        }
    }

    // MARK: Listening

    #if canImport(FirebaseFirestore)
    private func syncPresenceListeners() {
        let ids = Set(spaces.map(\.id))
        for (id, listener) in presenceListeners where !ids.contains(id) {
            listener.remove()
            presenceListeners[id] = nil
            presenceBySpace[id] = nil
        }
        for id in ids where presenceListeners[id] == nil {
            presenceListeners[id] = db.collection("serverSpaces").document(id).collection("presence")
                .addSnapshotListener { [weak self] snapshot, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        let presence = (snapshot?.documents ?? []).compactMap(Self.presence(from:))
                        self.presenceBySpace[id] = presence
                        self.clearOwnExpiredPresence(in: id, presence: presence)
                    }
                }
        }
    }

    /// Tidies up your own "I'm on" once it has timed out.
    private func clearOwnExpiredPresence(in spaceID: String, presence: [ServerPresence]) {
        guard let userID, let mine = presence.first(where: { $0.id == userID }), !mine.isActive() else { return }
        db.collection("serverSpaces").document(spaceID).collection("presence").document(userID).delete()
    }

    private static func space(from snapshot: QueryDocumentSnapshot) -> ServerSpace? {
        let data = snapshot.data()
        guard let name = data["name"] as? String, let ownerID = data["ownerID"] as? String else { return nil }
        return ServerSpace(
            id: snapshot.documentID,
            name: name,
            address: data["address"] as? String ?? "",
            ownerID: ownerID,
            ownerName: data["ownerName"] as? String ?? "",
            memberIDs: data["memberIDs"] as? [String] ?? [],
            serverOnline: data["serverOnline"] as? Bool ?? false,
            statusUpdatedAt: (data["statusUpdatedAt"] as? Timestamp)?.dateValue(),
            statusUpdatedByName: data["statusUpdatedByName"] as? String,
            requestedByID: data["requestedByID"] as? String,
            requestedByName: data["requestedByName"] as? String,
            requestedAt: (data["requestedAt"] as? Timestamp)?.dateValue()
        )
    }

    private static func presence(from snapshot: QueryDocumentSnapshot) -> ServerPresence? {
        let data = snapshot.data()
        guard let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
        return ServerPresence(
            id: snapshot.documentID,
            displayName: data["displayName"] as? String ?? "Member",
            since: (data["since"] as? Timestamp)?.dateValue() ?? expiresAt.addingTimeInterval(-presenceDuration),
            expiresAt: expiresAt
        )
    }
    #endif
}

