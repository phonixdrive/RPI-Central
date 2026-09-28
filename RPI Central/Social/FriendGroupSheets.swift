//
//  FriendGroupSheets.swift
//  RPI Central
//

import SwiftUI

struct FriendGroupEditorView: View {
    let friends: [SocialFriend]
    let accent: Color
    let onSave: (_ name: String, _ memberIDs: [String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var selectedMemberIDs: Set<String> = []
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private var sortedFriends: [SocialFriend] {
        friends.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var canSave: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedMemberIDs.isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Group name", text: $groupName)
                        .textInputAutocapitalization(.words)
                        .focused($nameFocused)
                }

                Section(selectedMemberIDs.isEmpty ? "Members" : "Members · \(selectedMemberIDs.count)") {
                    if sortedFriends.isEmpty {
                        Text("Add friends first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedFriends) { friend in
                            Button {
                                toggle(friend.id)
                            } label: {
                                HStack(spacing: 12) {
                                    SocialAvatar(id: friend.id, name: friend.displayName, size: 36)
                                    Text(friend.displayName)
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    Image(systemName: selectedMemberIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedMemberIDs.contains(friend.id) ? accent : Color.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Group")
            .onAppear { nameFocused = true }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let members = Array(selectedMemberIDs).sorted()
                        isSaving = true
                        Task {
                            let didSave = await onSave(trimmed, members)
                            await MainActor.run {
                                isSaving = false
                                if didSave {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func toggle(_ friendID: String) {
        if selectedMemberIDs.contains(friendID) {
            selectedMemberIDs.remove(friendID)
        } else {
            selectedMemberIDs.insert(friendID)
        }
    }
}

struct GroupMembersPresentation: Identifiable {
    let title: String
    let subtitle: String
    let memberNames: [String]
    let group: SocialFriendGroup?
    let addableFriends: [SocialFriend]

    var id: String { title + subtitle }
}

struct GroupMembersSheet: View {
    let presentation: GroupMembersPresentation

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var memberNames: [String]
    @State private var addableFriends: [SocialFriend]
    @State private var isUpdating = false

    init(presentation: GroupMembersPresentation) {
        self.presentation = presentation
        _memberNames = State(initialValue: presentation.memberNames)
        _addableFriends = State(initialValue: presentation.addableFriends)
    }

    var body: some View {
        NavigationStack {
            List {
                Section(memberNames.count == 1 ? "1 Member" : "\(memberNames.count) Members") {
                    ForEach(memberNames, id: \.self) { name in
                        Text(name)
                    }
                }

                if let group = presentation.group,
                   group.ownerID == socialManager.currentUser?.id,
                   !addableFriends.isEmpty {
                    Section("Add People") {
                        ForEach(addableFriends) { friend in
                            Button {
                                Task {
                                    guard !isUpdating else { return }
                                    isUpdating = true
                                    let added = await socialManager.addMembersToFriendGroup(
                                        groupID: group.id,
                                        memberIDs: [friend.id]
                                    )
                                    if added {
                                        await MainActor.run {
                                            memberNames.append(friend.displayName)
                                            memberNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                                            addableFriends.removeAll { $0.id == friend.id }
                                        }
                                    }
                                    await MainActor.run {
                                        isUpdating = false
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friend.displayName)
                                        Text("@\(friend.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(calendarViewModel.themeColor)
                                }
                            }
                            .disabled(isUpdating)
                        }
                    }
                }
            }
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
