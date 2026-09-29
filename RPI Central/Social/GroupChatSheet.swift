//
//  GroupChatSheet.swift
//  RPI Central
//

import SwiftUI
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

struct GroupChatSheet: View {
    let reference: SocialGroupChatReference

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool

    @State private var messages: [SocialGroupChatMessage] = []
    @State private var isLoadingMessages = true
    @State private var draftMessage: String = ""
    @State private var isSending = false
    @State private var sendFailed = false
    @State private var didPerformInitialScroll = false
    @State private var isMuted = false
    @State private var participantsByID: [String: SocialUser] = [:]
    @State private var selectedProfileUser: SocialUser?
    @State private var showParticipants = false
    @State private var reportTarget: SocialReportTarget?
#if canImport(FirebaseFirestore)
    @State private var chatListener: ListenerRegistration?
#endif

    private let bottomAnchorID = "group-chat-bottom-anchor"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ZStack {
                        if isLoadingMessages {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(calendarViewModel.themeColor)
                                Text("Loading messages…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                        } else if messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(calendarViewModel.themeColor)
                                Text("No messages yet")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                composerFocused = false
                            }
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 5) {
                                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                        let previousSenderID = index > 0 ? messages[index - 1].userID : nil
                                        let showsTimeSeparator = shouldShowTimeSeparator(at: index)
                                        let showsIdentity = previousSenderID != message.userID || showsTimeSeparator

                                        if showsTimeSeparator {
                                            Text(chatTimestamp(message.createdAt))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                                .frame(maxWidth: .infinity)
                                                .padding(.top, index == 0 ? 0 : 9)
                                                .padding(.bottom, 3)
                                        }

                                        chatMessageRow(message, showsIdentity: showsIdentity)
                                            .padding(.top, showsIdentity && !showsTimeSeparator && index > 0 ? 7 : 0)
                                    }

                                    Color.clear
                                        .frame(height: 1)
                                        .id(bottomAnchorID)
                                }
                                .padding(16)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                composerFocused = false
                            }
                            .scrollDismissesKeyboard(.interactively)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color(.systemGroupedBackground),
                            calendarViewModel.themeColor.opacity(0.14),
                            Color(.systemBackground),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .safeAreaInset(edge: .bottom) {
                    composerBar(proxy: proxy)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close chat")
                    }

                    ToolbarItem(placement: .principal) {
                        Button {
                            showParticipants = true
                        } label: {
                            VStack(spacing: 1) {
                                Text(reference.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(chatHeaderSubtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View chat members")
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showParticipants = true
                            } label: {
                                Label("View members", systemImage: "person.2")
                            }

                            Button {
                                let nextValue = !isMuted
                                Task {
                                    await socialManager.setChatMuted(nextValue, for: reference)
                                    await MainActor.run {
                                        isMuted = nextValue
                                    }
                                }
                            } label: {
                                Label(
                                    isMuted ? "Unmute notifications" : "Mute notifications",
                                    systemImage: isMuted ? "bell" : "bell.slash"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Chat options")
                    }
                }
                .task(id: reference.id) {
                    socialManager.setActiveGroupChat(id: reference.id)
                    isMuted = socialManager.isChatMuted(reference)
                    await startListening(proxy: proxy)
                }
                .onChange(of: messages.count) { _, newCount in
                    guard newCount > 0 else { return }
                    if !didPerformInitialScroll {
                        didPerformInitialScroll = true
                        scrollToBottom(proxy, animated: false)
                        DispatchQueue.main.async {
                            scrollToBottom(proxy, animated: false)
                        }
                    }
                }
                .onDisappear {
                    socialManager.setActiveGroupChat(id: nil)
                    stopListening()
                }
            }
        }
        .socialReportDialog($reportTarget)
        .sheet(item: $selectedProfileUser) { user in
            SocialUserProfileSheet(user: user)
        }
        .sheet(isPresented: $showParticipants) {
            ChatParticipantsSheet(
                title: reference.title,
                profiles: participantProfiles,
                fallbackNames: reference.memberDisplayNames
            )
        }
    }

    private var chatHeaderSubtitle: String {
        let count = Set(reference.memberIDs).count
        let base: String
        if reference.sourceKind == .campusGroup {
            base = reference.subtitle
        } else if reference.sourceKind == .directMessage {
            base = reference.subtitle
        } else if count > 0 {
            base = "\(count) \(count == 1 ? "member" : "members")"
        } else {
            base = reference.subtitle
        }
        return isMuted ? "\(base) • Muted" : base
    }

    private func composerBar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if sendFailed {
                Label("Not sent. Tap send to try again.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
            composerRow(proxy: proxy)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func composerRow(proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Send a message", text: $draftMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(calendarViewModel.themeColor.opacity(0.16), lineWidth: 1)
                )
                .focused($composerFocused)

            Button {
                let trimmed = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !isSending else { return }
                isSending = true
                Task {
                    let didSend = await socialManager.sendGroupChatMessage(for: reference, body: trimmed)
                    await MainActor.run {
                        sendFailed = !didSend
                        if didSend {
                            draftMessage = ""
                            scrollToBottom(proxy, animated: true)
                        }
                        isSending = false
                    }
                }
            } label: {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(
                            draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
                                ? Color(.tertiarySystemFill)
                                : calendarViewModel.themeColor
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
    }

    private func chatMessageRow(
        _ message: SocialGroupChatMessage,
        showsIdentity: Bool
    ) -> some View {
        let isMine = message.userID == socialManager.currentUser?.id

        return HStack(alignment: .bottom, spacing: 7) {
            if isMine {
                Spacer(minLength: 54)
            } else if showsIdentity {
                Button {
                    Task {
                        await openProfile(for: message.userID)
                    }
                } label: {
                    SocialAvatar(id: message.userID, name: message.displayName, size: 30)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 30, height: 1)
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if showsIdentity && !isMine {
                    Button {
                        Task {
                            await openProfile(for: message.userID)
                        }
                    } label: {
                        Text(message.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(isMine ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isMine ? calendarViewModel.themeColor : Color(.secondarySystemBackground))
                    )
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.body
                        }
                        if !isMine {
                            Button("Report Message", systemImage: "exclamationmark.bubble") {
                                reportTarget = SocialReportTarget(
                                    userID: message.userID,
                                    displayName: message.displayName,
                                    kind: .message,
                                    contextID: "\(reference.id)/\(message.id)",
                                    excerpt: message.body
                                )
                            }
                            Button("Block \(message.displayName)", systemImage: "hand.raised", role: .destructive) {
                                Task { await socialManager.blockUser(message.userID) }
                            }
                        }
                        if socialManager.canDeleteGroupChatMessage(message) {
                            Button(role: .destructive) {
                                Task {
                                    await socialManager.deleteGroupChatMessage(message, in: reference)
                                }
                            } label: {
                                Label("Delete message", systemImage: "trash")
                            }
                        }
                    }
            }
            .frame(maxWidth: 300, alignment: isMine ? .trailing : .leading)

            if !isMine { Spacer(minLength: 40) }
        }
    }

    private func startListening(proxy: ScrollViewProxy) async {
        await MainActor.run {
            didPerformInitialScroll = false
            messages = []
            isLoadingMessages = true
        }
        async let minimumLoadingDelay: Void = Task.sleep(for: .milliseconds(700))
        let initialMessages = await socialManager.loadGroupChatMessages(for: reference)
        await refreshParticipants(using: initialMessages)
        try? await minimumLoadingDelay
        await MainActor.run {
            messages = initialMessages.filter { !socialManager.isBlocked($0.userID) }
            isLoadingMessages = false
            socialManager.markGroupChatSeen(
                reference,
                latestMessageID: initialMessages.last?.id,
                latestMessageAt: initialMessages.last?.createdAt
            )
            if !initialMessages.isEmpty {
                didPerformInitialScroll = true
                scrollToBottom(proxy, animated: false)
                DispatchQueue.main.async {
                    scrollToBottom(proxy, animated: false)
                }
            }
        }

#if canImport(FirebaseFirestore)
        chatListener?.remove()
        chatListener = await socialManager.observeGroupChatMessages(for: reference) { updatedMessages in
            let shouldScroll = updatedMessages.last?.id != messages.last?.id
            messages = updatedMessages.filter { !socialManager.isBlocked($0.userID) }
            isLoadingMessages = false
            socialManager.markGroupChatSeen(
                reference,
                latestMessageID: updatedMessages.last?.id,
                latestMessageAt: updatedMessages.last?.createdAt
            )
            Task {
                await refreshParticipants(using: updatedMessages)
            }
            if !didPerformInitialScroll && !updatedMessages.isEmpty {
                didPerformInitialScroll = true
                scrollToBottom(proxy, animated: false)
                DispatchQueue.main.async {
                    scrollToBottom(proxy, animated: false)
                }
                return
            }
            if shouldScroll {
                scrollToBottom(proxy, animated: true)
            }
        }
#endif
    }

    private func stopListening() {
#if canImport(FirebaseFirestore)
        chatListener?.remove()
        chatListener = nil
#endif
    }

    private var participantProfiles: [SocialUser] {
        participantIDsForDisplay.compactMap { participantsByID[$0] }
    }

    private var participantIDsForDisplay: [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        let baseIDs: [String]
        if reference.sourceKind == .campusGroup {
            baseIDs = recentMessageParticipantIDs(limit: 12)
        } else {
            baseIDs = reference.memberIDs + recentMessageParticipantIDs(limit: 24)
        }

        for id in baseIDs where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    private func recentMessageParticipantIDs(limit: Int) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for message in messages.reversed() where seen.insert(message.userID).inserted {
            ordered.append(message.userID)
            if ordered.count >= limit {
                break
            }
        }
        return ordered
    }

    private func refreshParticipants(using updatedMessages: [SocialGroupChatMessage]) async {
        let ids = Array(Set(reference.memberIDs + updatedMessages.map(\.userID)))
        guard !ids.isEmpty else { return }
        let missing = ids.filter { participantsByID[$0] == nil }
        guard !missing.isEmpty else { return }

        let fetched = await socialManager.loadUserProfiles(ids: missing)
        guard !fetched.isEmpty else { return }

        await MainActor.run {
            participantsByID.merge(fetched) { _, new in new }
        }
    }

    private func openProfile(for userID: String) async {
        if let existing = participantsByID[userID] {
            await MainActor.run {
                selectedProfileUser = existing
            }
            return
        }

        if let loaded = await socialManager.loadUserProfile(id: userID) {
            await MainActor.run {
                participantsByID[userID] = loaded
                selectedProfileUser = loaded
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func chatTimestamp(_ isoString: String) -> String {
        if let date = chatDate(isoString) {
            if Calendar.current.isDateInToday(date) {
                return date.formatted(date: .omitted, time: .shortened)
            }
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return "Now"
    }

    private func shouldShowTimeSeparator(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        guard let currentDate = chatDate(messages[index].createdAt),
              let previousDate = chatDate(messages[index - 1].createdAt) else {
            return false
        }

        return !Calendar.current.isDate(currentDate, inSameDayAs: previousDate)
            || currentDate.timeIntervalSince(previousDate) >= 15 * 60
    }

    private func chatDate(_ isoString: String) -> Date? {
        groupChatISOFormatter.date(from: isoString)
            ?? groupChatISOFormatterWithFractionalSeconds.date(from: isoString)
    }
}

private struct ChatParticipantsSheet: View {
    let title: String
    let profiles: [SocialUser]
    let fallbackNames: [String]

    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfile: SocialUser?

    private var unresolvedNames: [String] {
        let resolved = Set(profiles.map(\.displayName))
        return fallbackNames.filter { !resolved.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if profiles.isEmpty && unresolvedNames.isEmpty {
                    ContentUnavailableView(
                        "No Members Available",
                        systemImage: "person.2",
                        description: Text("Member profiles will appear after the conversation loads.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(profiles) { user in
                        Button {
                            selectedProfile = user
                        } label: {
                            HStack(spacing: 12) {
                                SocialAvatar(id: user.id, name: user.displayName, size: 42)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("@\(user.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(unresolvedNames, id: \.self) { name in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 42, height: 42)
                                .overlay {
                                    Text(String(name.prefix(1)).uppercased())
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                            Text(name)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $selectedProfile) { user in
            SocialUserProfileSheet(user: user)
        }
    }
}

private let groupChatISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let groupChatISOFormatterWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
