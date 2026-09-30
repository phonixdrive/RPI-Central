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

// MARK: - Cards

/// Every server space you're in, as compact cards. Shows nothing when you
/// aren't in any.
struct ServerSpacesStrip: View {
    @EnvironmentObject private var socialManager: SocialManager
    @ObservedObject private var model = ServerSpacesModel.shared
    let accent: Color
    @State private var openSpaceID: String?

    var body: some View {
        ForEach(model.spaces) { space in
            ServerSpaceCard(space: space, online: model.onlineMembers(in: space), accent: accent) {
                openSpaceID = space.id
            }
        }
        .sheet(item: Binding(
            get: { openSpaceID.map(IdentifiedString.init) },
            set: { openSpaceID = $0?.value }
        )) { item in
            ServerSpaceSheet(spaceID: item.value, accent: accent)
                .environmentObject(socialManager)
        }
        .task(id: socialManager.currentUser?.id) {
            model.start(userID: socialManager.currentUser?.id)
        }
    }
}

private struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

struct ServerSpaceCard: View {
    let space: ServerSpace
    let online: [ServerPresence]
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((space.serverOnline ? Color.green : Color.gray).opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "server.rack")
                        .font(.title3)
                        .foregroundStyle(space.serverOnline ? .green : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(space.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        StatusPill(online: space.serverOnline)
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if let request = space.pendingRequest() {
            return "\(request.name) asked to start it"
        }
        if online.isEmpty {
            return space.serverOnline ? "No one’s on yet" : "\(space.memberIDs.count) members"
        }
        let names = online.prefix(3).map { $0.displayName.components(separatedBy: " ").first ?? $0.displayName }
        let more = online.count > 3 ? " +\(online.count - 3)" : ""
        return "On now: \(names.joined(separator: ", "))\(more)"
    }
}

private struct StatusPill: View {
    let online: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(online ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(online ? "Online" : "Offline")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(online ? .green : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((online ? Color.green : Color.gray).opacity(0.14), in: Capsule())
    }
}

// MARK: - Detail

struct ServerSpaceSheet: View {
    let spaceID: String
    let accent: Color

    @EnvironmentObject private var socialManager: SocialManager
    @ObservedObject private var model = ServerSpacesModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @State private var showEdit = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var copied = false

    private var space: ServerSpace? { model.spaces.first { $0.id == spaceID } }
    private var myID: String? { socialManager.currentUser?.id }
    private var myName: String { socialManager.currentUser?.displayName ?? "Someone" }

    var body: some View {
        NavigationStack {
            Group {
                if let space {
                    content(space)
                } else {
                    ContentUnavailableView("Server Unavailable", systemImage: "server.rack", description: Text("It may have been deleted, or you were removed."))
                }
            }
            .navigationTitle(space?.name ?? "Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let space {
                    ToolbarItem(placement: .topBarLeading) { menu(space) }
                }
            }
            .alert("Something Went Wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func content(_ space: ServerSpace) -> some View {
        let isOwner = space.ownerID == myID
        let online = model.onlineMembers(in: space)
        let amOn = model.isOn(space)

        return List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40))
                        .foregroundStyle(space.serverOnline ? .green : .secondary)
                    StatusPill(online: space.serverOnline).scaleEffect(1.2)
                    if let updated = space.statusUpdatedAt {
                        Text("\(space.statusUpdatedByName ?? "Owner") updated \(updated.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !space.address.isEmpty {
                        Button {
                            UIPasteboard.general.string = space.address
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : space.address, systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.subheadline.monospaced())
                        }
                        .buttonStyle(.bordered)
                        .tint(accent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                if isOwner {
                    Toggle("Server is online", isOn: Binding(
                        get: { space.serverOnline },
                        set: { value in Task { await model.setServerOnline(value, in: space, byName: myName) } }
                    ))
                    .tint(.green)
                }
                if let request = space.pendingRequest() {
                    Label("\(request.name) asked to start it \(request.at.formatted(.relative(presentation: .named)))", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                } else if !space.serverOnline, !isOwner {
                    Button {
                        Task { await model.requestStart(space, byName: myName) }
                    } label: {
                        Label("Ask to Start the Server", systemImage: "hand.raised")
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { amOn },
                    set: { value in Task { await model.setOnServer(value, in: space, displayName: myName) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I’m on the server")
                        Text(amOn ? "Turns off \(myExpiry(space)?.formatted(.relative(presentation: .named)) ?? "in 24 hours")" : "Turns off on its own after 24 hours")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }

            Section {
                if online.isEmpty {
                    Text("No one’s on right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(online) { presence in
                        HStack {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(presence.id == myID ? "\(presence.displayName) (you)" : presence.displayName)
                            Spacer()
                            Text(presence.since.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if isOwner, presence.id != myID {
                                Button("Mark Off", role: .destructive) {
                                    Task { await model.removePresence(of: presence.id, in: space) }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("On Now · \(online.count)")
            }

            Section {
                ForEach(space.memberIDs, id: \.self) { memberID in
                    HStack {
                        Text(memberName(memberID, in: space))
                        Spacer()
                        if memberID == space.ownerID {
                            Text("Owner").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if isOwner, memberID != space.ownerID {
                            Button("Remove", role: .destructive) {
                                Task { await model.removeMember(memberID, from: space) }
                            }
                        }
                    }
                }
                if isOwner {
                    Button {
                        showInvite = true
                    } label: {
                        Label("Invite Friends", systemImage: "person.badge.plus")
                    }
                }
            } header: {
                Text("Members · \(space.memberIDs.count)")
            } footer: {
                Text("Only members can see this server.")
            }
        }
        .sheet(isPresented: $showInvite) {
            FriendPickerSheet(
                title: "Invite Friends",
                friends: (socialManager.overview?.friends ?? []).filter { !space.memberIDs.contains($0.id) },
                accent: accent,
                actionTitle: "Invite"
            ) { ids in
                Task { await model.invite(ids, to: space) }
            }
        }
        .sheet(isPresented: $showEdit) {
            ServerSpaceEditor(title: "Edit Server", initialName: space.name, initialAddress: space.address, friends: [], accent: accent) { name, address, _ in
                Task { await model.update(space, name: name, address: address) }
            }
        }
        .confirmationDialog("Leave \(space.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                Task {
                    await model.leave(space)
                    dismiss()
                }
            }
        }
        .confirmationDialog("Delete \(space.name) for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(space)
                    dismiss()
                }
            }
        }
    }

    private func menu(_ space: ServerSpace) -> some View {
        Menu {
            if space.ownerID == myID {
                Button("Edit Name & Address", systemImage: "pencil") { showEdit = true }
                Button("Delete Server", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } else {
                Button("Leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    private func myExpiry(_ space: ServerSpace) -> Date? {
        model.onlineMembers(in: space).first { $0.id == myID }?.expiresAt
    }

    private func memberName(_ id: String, in space: ServerSpace) -> String {
        if id == myID { return "\(myName) (you)" }
        if id == space.ownerID, !space.ownerName.isEmpty { return space.ownerName }
        if let friend = socialManager.overview?.friends.first(where: { $0.id == id }) { return friend.displayName }
        if let presence = model.presenceBySpace[space.id]?.first(where: { $0.id == id }) { return presence.displayName }
        return "Member"
    }
}

// MARK: - Creating and inviting

struct ServerSpaceEditor: View {
    let title: String
    let initialName: String
    let initialAddress: String
    /// Friends to invite; empty when editing.
    let friends: [SocialFriend]
    let accent: Color
    let onSave: (_ name: String, _ address: String, _ invited: [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var invited: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (like “Minecraft SMP”)", text: $name)
                    TextField("Server address (optional)", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("Only the people you invite can see it.")
                }
                if !friends.isEmpty {
                    Section("Invite") {
                        ForEach(friends) { friend in
                            FriendToggleRow(friend: friend, isOn: invited.contains(friend.id), accent: accent) {
                                if invited.contains(friend.id) { invited.remove(friend.id) } else { invited.insert(friend.id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), address.trimmingCharacters(in: .whitespacesAndNewlines), Array(invited))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = initialName
                address = initialAddress
            }
        }
    }
}

struct FriendPickerSheet: View {
    let title: String
    let friends: [SocialFriend]
    let accent: Color
    let actionTitle: String
    let onPick: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if friends.isEmpty {
                    Text("All your friends are already here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(friends) { friend in
                    FriendToggleRow(friend: friend, isOn: picked.contains(friend.id), accent: accent) {
                        if picked.contains(friend.id) { picked.remove(friend.id) } else { picked.insert(friend.id) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? actionTitle : "\(actionTitle) \(picked.count)") {
                        onPick(Array(picked))
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}

private struct FriendToggleRow: View {
    let friend: SocialFriend
    let isOn: Bool
    let accent: Color
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName).foregroundStyle(Color.primary)
                    Text("@\(friend.username)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? accent : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
