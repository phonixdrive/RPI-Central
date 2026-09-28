//
//  SocialPlansView.swift
//  RPI Central
//
//  Friends' plans (study sessions, meals, meetups) that others can join.
//

import SwiftUI

struct SocialPlansView: View {
    @EnvironmentObject private var socialManager: SocialManager
    @Environment(\.socialActions) private var actions

    var body: some View {
        List {
            if socialManager.feedItems.isEmpty {
                ContentUnavailableView {
                    Label("No Plans", systemImage: "figure.walk")
                } description: {
                    Text("Post a study session or meetup for friends to join.")
                } actions: {
                    Button("New Plan", action: actions.newPlan)
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(socialManager.feedItems.enumerated()), id: \.element.id) { index, item in
                    Section {
                        PlanRow(item: item)
                    } header: {
                        if index == 0 {
                            HStack(spacing: 6) {
                                Text("Happening")
                                InfoButton("Plans end on their own 6 hours after they start. Tap Going or I’m Here so friends know who’s coming.")
                            }
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .refreshable { await socialManager.refreshOverview() }
    }
}

private struct PlanRow: View {
    let item: SocialFeedItem

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel

    private var post: SocialFeedPost { item.post }
    private var isOwnPost: Bool { post.ownerID == socialManager.currentUser?.id }
    private var canEnd: Bool { isOwnPost || socialManager.canModerateSocialContent }
    private var myStatus: SocialFeedPresenceStatus? {
        item.responses.first { $0.userID == socialManager.currentUser?.id }?.status
    }

    var body: some View {
        let state = PlanTiming.state(for: post)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SocialAvatar(id: post.ownerID, name: post.ownerDisplayName, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.title)
                        .font(.headline)
                    Text(metaLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(PlanTiming.text(for: post))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(state.color.opacity(0.14), in: Capsule())

                    if canEnd || isOwnPost {
                        optionsMenu(state: state)
                    }
                }
            }

            if !post.details.isEmpty {
                Text(post.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let attendance {
                Label(attendance, systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state != .ended {
                HStack(spacing: 8) {
                    presenceButton("Going", systemImage: "figure.walk", status: .going)
                    if state == .live {
                        presenceButton("I’m Here", systemImage: "location.fill", status: .here)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func optionsMenu(state: PlanTiming.State) -> some View {
        Menu {
            if state != .ended && canEnd {
                Button("End Plan", systemImage: "checkmark.circle") {
                    Task { _ = await socialManager.endFeedPost(post) }
                }
            }
            if isOwnPost {
                Button("Delete Plan", systemImage: "trash", role: .destructive) {
                    Task { _ = await socialManager.deleteFeedPost(post.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Plan options")
    }

    private var metaLine: String {
        let owner = isOwnPost ? "You" : post.ownerDisplayName
        return post.location.isEmpty ? owner : "\(owner) · \(post.location)"
    }

    /// "You & Sam going · Jordan here", or counts once it gets long.
    private var attendance: String? {
        let viewerID = socialManager.currentUser?.id
        func part(_ status: SocialFeedPresenceStatus, _ verb: String) -> String? {
            let responses = item.responses
                .filter { $0.status == status }
                .sorted { ($0.userID == viewerID ? 0 : 1) < ($1.userID == viewerID ? 0 : 1) }
            let names = responses.map { $0.userID == viewerID ? "You" : FriendAvatarStyle.firstName(for: $0.displayName) }
            switch names.count {
            case 0: return nil
            case 1, 2: return "\(names.joined(separator: " & ")) \(verb)"
            default: return "\(names.count) \(verb)"
            }
        }
        let parts = [part(.going, "going"), part(.here, "here")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func presenceButton(_ title: String, systemImage: String, status: SocialFeedPresenceStatus) -> some View {
        let isSelected = myStatus == status
        return Button {
            Task {
                _ = await socialManager.setFeedPresence(postID: post.id, status: isSelected ? nil : status)
            }
        } label: {
            Label(title, systemImage: isSelected ? "checkmark" : systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? calendarViewModel.themeColor : Color.primary)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? calendarViewModel.themeColor : Color.secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum PlanTiming {
    enum State {
        case upcoming, live, ended

        var title: String {
            switch self {
            case .upcoming: return "Upcoming"
            case .live: return "Live"
            case .ended: return "Ended"
            }
        }

        var color: Color {
            switch self {
            case .upcoming: return .blue
            case .live: return .green
            case .ended: return .secondary
            }
        }
    }

    static func state(for post: SocialFeedPost, now: Date = Date()) -> State {
        if endDate(for: post, now: now) != nil { return .ended }
        if let start = date(post.startsAt), start > now { return .upcoming }
        return .live
    }

    static func text(for post: SocialFeedPost, now: Date = Date()) -> String {
        if let ended = endDate(for: post, now: now) {
            if now.timeIntervalSince(ended) < 60 { return "Just ended" }
            return "Ended \(relative.localizedString(for: ended, relativeTo: now))"
        }
        guard let start = date(post.startsAt) else { return "Just posted" }
        if start > now {
            return "Starts \(start.formatted(.relative(presentation: .named)))"
        }
        if now.timeIntervalSince(start) < 60 { return "Just started" }
        return "Started \(relative.localizedString(for: start, relativeTo: now))"
    }

    /// Plans end when their owner ends them, or 6 hours after they start.
    private static func endDate(for post: SocialFeedPost, now: Date) -> Date? {
        if let ended = date(post.endedAt) { return ended }
        guard let start = date(post.startsAt) else { return nil }
        let autoEnd = start.addingTimeInterval(6 * 60 * 60)
        return autoEnd <= now ? autoEnd : nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return iso.date(from: value)
    }

    private static let iso = ISO8601DateFormatter()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

// MARK: - Composer

struct FeedComposerView: View {
    let groups: [SocialFriendGroup]
    let accent: Color
    let onSave: (
        _ title: String,
        _ location: String,
        _ details: String,
        _ startsAt: Date,
        _ visibility: SocialFeedVisibility,
        _ groupIDs: [String]
    ) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var location = ""
    @State private var details = ""
    @State private var startsAt = Date()
    @State private var visibility: SocialFeedVisibility = .friends
    @State private var selectedGroupIDs: Set<String> = []
    @State private var isSaving = false

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (visibility != .groups || !selectedGroupIDs.isEmpty) &&
            !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What’s the plan?", text: $title)
                        .textInputAutocapitalization(.sentences)
                        .focused($titleFocused)
                    TextField("Where", text: $location)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("Details", text: $details, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(2...5)
                }

                Section {
                    DatePicker("Starts", selection: $startsAt)
                    Picker("Visible to", selection: $visibility) {
                        ForEach(SocialFeedVisibility.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }

                if visibility == .groups {
                    Section("Groups") {
                        if groups.isEmpty {
                            Text("Create a group first.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(groups) { group in
                            Button {
                                if selectedGroupIDs.contains(group.id) {
                                    selectedGroupIDs.remove(group.id)
                                } else {
                                    selectedGroupIDs.insert(group.id)
                                }
                            } label: {
                                HStack {
                                    Text(group.name)
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    if selectedGroupIDs.contains(group.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(accent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Plan")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { titleFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        let groupIDs = Array(selectedGroupIDs).sorted()
        Task {
            let didSave = await onSave(
                title.trimmingCharacters(in: .whitespacesAndNewlines),
                location.trimmingCharacters(in: .whitespacesAndNewlines),
                details.trimmingCharacters(in: .whitespacesAndNewlines),
                startsAt,
                visibility,
                groupIDs
            )
            isSaving = false
            if didSave {
                dismiss()
            }
        }
    }
}
