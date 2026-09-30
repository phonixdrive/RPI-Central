//
//  SocialChatsView.swift
//  RPI Central
//
//  Every conversation in one list: direct messages, friend groups, and the
//  campus chat sorted by their latest message, then class chats.
//

import SwiftUI

struct SocialChatsView: View {
    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.socialActions) private var actions
    @AppStorage("social_show_campus_wide_group") private var showCampusWideGroup = true
    /// "current", "all", or a semester code.
    @AppStorage("social_class_term_filter") private var classTermFilter = "current"
    @AppStorage("social_class_include_sections") private var includeSectionChats = false
    @State private var groupPendingRemoval: SocialFriendGroup?
    @ObservedObject private var serverSpaces = ServerSpacesModel.shared

    var body: some View {
        let conversations = conversationItems()
        let classGroups = visibleClassGroups()

        List {
            if socialManager.overview == nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading chats…")
                        .foregroundStyle(.secondary)
                }
            } else if conversations.isEmpty && classGroups.isEmpty {
                ContentUnavailableView {
                    Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Add friends to message them or start a group.")
                } actions: {
                    Button("Add Friends", action: actions.addFriends)
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                if !serverSpaces.spaces.isEmpty {
                    Section {
                        ServerSpacesStrip(accent: calendarViewModel.themeColor)
                    }
                } else if let listenError = serverSpaces.listenError {
                    Section {
                        Label(listenError, systemImage: "server.rack")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if !conversations.isEmpty {
                    Section {
                        ForEach(conversations) { item in
                            conversationRow(item)
                        }
                    }
                }

                Section {
                    if classGroups.isEmpty {
                        Text("Add courses to join their class chats.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(classGroups) { community in
                            classRow(community)
                        }
                    }
                } header: {
                    classesHeader
                }
            }
        }
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .refreshable { await socialManager.refreshOverview() }
        .confirmationDialog(
            groupPendingRemoval.map(removalTitle) ?? "",
            isPresented: Binding(
                get: { groupPendingRemoval != nil },
                set: { if !$0 { groupPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: groupPendingRemoval
        ) { group in
            Button(isOwner(of: group) ? "Delete Group" : "Leave Group", role: .destructive) {
                Task { await remove(group) }
            }
        }
    }

    // MARK: Conversations

    private struct ConversationItem: Identifiable {
        enum Kind {
            case direct(SocialFriend)
            case group(SocialFriendGroup)
            case campus
        }

        let reference: SocialGroupChatReference
        let kind: Kind
        let lastActivity: Date?
        var id: String { reference.id }
    }

    private func conversationItems() -> [ConversationItem] {
        var items: [ConversationItem] = []

        // Direct messages appear once someone has written; new ones start
        // from the compose button or a friend's profile.
        for friend in socialManager.overview?.friends ?? [] {
            guard let reference = socialManager.directMessageReference(with: friend),
                  let lastActivity = socialManager.lastActivityDate(in: reference) else { continue }
            items.append(ConversationItem(reference: reference, kind: .direct(friend), lastActivity: lastActivity))
        }
        for group in socialManager.friendGroups {
            guard let reference = socialManager.chatReference(for: group) else { continue }
            items.append(ConversationItem(
                reference: reference,
                kind: .group(group),
                lastActivity: socialManager.lastActivityDate(in: reference)
            ))
        }
        if showCampusWideGroup, let reference = socialManager.campusWideChatReference {
            items.append(ConversationItem(
                reference: reference,
                kind: .campus,
                lastActivity: socialManager.lastActivityDate(in: reference)
            ))
        }

        return items.sorted { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (left?, right?): return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.reference.title.localizedCaseInsensitiveCompare(rhs.reference.title) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private func conversationRow(_ item: ConversationItem) -> some View {
        let row = ChatRow(
            title: item.reference.title,
            lastActivity: item.lastActivity,
            isUnread: socialManager.hasUnreadMessages(in: item.reference),
            accent: calendarViewModel.themeColor,
            action: { actions.openChat(item.reference) }
        ) {
            switch item.kind {
            case .direct(let friend):
                SocialAvatar(id: friend.id, name: friend.displayName)
            case .group:
                SocialSymbolAvatar(systemImage: "person.3.fill", color: calendarViewModel.themeColor)
            case .campus:
                SocialSymbolAvatar(systemImage: "building.columns.fill", color: .orange)
            }
        } subtitle: {
            switch item.kind {
            case .direct(let friend):
                FriendActivityLine(friend: friend)
            case .group(let group):
                subtitleText(memberSummary(for: group))
            case .campus:
                subtitleText("Everyone on RPI Central")
            }
        }

        switch item.kind {
        case .direct(let friend):
            row.contextMenu {
                Button("View Profile", systemImage: "person.crop.circle") {
                    actions.openProfile(friend.asUser)
                }
                if friend.canViewSchedule {
                    Button("View Schedule", systemImage: "calendar") {
                        actions.openSchedule(friend)
                    }
                }
            }
        case .group(let group):
            row
                .contextMenu {
                    Button("Members", systemImage: "person.2") {
                        actions.openGroupMembers(group)
                    }
                    Button(isOwner(of: group) ? "Delete Group" : "Leave Group", systemImage: "trash", role: .destructive) {
                        groupPendingRemoval = group
                    }
                }
                .swipeActions {
                    Button(isOwner(of: group) ? "Delete" : "Leave", role: .destructive) {
                        groupPendingRemoval = group
                    }
                }
        case .campus:
            row.swipeActions {
                Button("Hide") {
                    showCampusWideGroup = false
                }
                .tint(.gray)
            }
        }
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
    }

    private func memberSummary(for group: SocialFriendGroup) -> String {
        let viewerID = socialManager.currentUser?.id
        let namesByID = Dictionary(
            uniqueKeysWithValues: (socialManager.overview?.friends ?? []).map {
                ($0.id, FriendAvatarStyle.firstName(for: $0.displayName))
            }
        )
        let names = ([group.ownerID] + group.memberIDs)
            .filter { $0 != viewerID }
            .compactMap { namesByID[$0] }
        switch names.count {
        case 0: return "Just you"
        case 1...3: return names.joined(separator: ", ")
        default: return "\(names.prefix(3).joined(separator: ", ")) +\(names.count - 3)"
        }
    }

    private func isOwner(of group: SocialFriendGroup) -> Bool {
        group.ownerID == socialManager.currentUser?.id
    }

    private func removalTitle(for group: SocialFriendGroup) -> String {
        isOwner(of: group) ? "Delete “\(group.name)” for everyone?" : "Leave “\(group.name)”?"
    }

    private func remove(_ group: SocialFriendGroup) async {
        if isOwner(of: group) {
            if await socialManager.deleteFriendGroup(group.id) {
                socialManager.requestScheduleSync()
            }
        } else {
            _ = await socialManager.leaveFriendGroup(group)
        }
    }

    // MARK: Classes

    private var classesHeader: some View {
        HStack(spacing: 6) {
            Text("Classes")
            InfoButton("Class chats are created from the courses you add: one for the whole course and one for your section.")
            Spacer()
            Menu {
                Picker("Term", selection: $classTermFilter) {
                    Text("This Term").tag("current")
                    Text("All Terms").tag("all")
                    ForEach(availableSemesterCodes, id: \.self) { code in
                        Text(semesterName(code)).tag(code)
                    }
                }
                Toggle("Section Chats", isOn: $includeSectionChats)
            } label: {
                HStack(spacing: 3) {
                    Text(classFilterTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
                .font(.subheadline)
                .textCase(nil)
            }
        }
    }

    private func classRow(_ community: SocialCourseCommunity) -> some View {
        let reference = socialManager.chatReference(for: community)
        let memberCount = community.memberIDs.count
        let code = "\(community.courseSubject) \(community.courseNumber)"
        let members = "\(memberCount) \(memberCount == 1 ? "member" : "members")"
        // The course chat and the section chat share a course title, so say
        // which is which in the title itself.
        let sectionNumber = community.sectionLabel?.components(separatedBy: "Sec ").last?.trimmingCharacters(in: .whitespaces)
        let title = community.kind == .section
            ? "\(community.courseTitle) · Sec \(sectionNumber ?? "")"
            : community.courseTitle
        let term = community.semesterCode.flatMap(Semester.init(rawValue:))?.displayName
        let detail = community.kind == .section
            ? "\(code) · \(term.map { "\($0) section" } ?? "Section") · \(members)"
            : "\(code) · Everyone · \(members)"

        return ChatRow(
            title: title,
            lastActivity: socialManager.lastActivityDate(in: reference),
            isUnread: socialManager.hasUnreadMessages(in: reference),
            accent: calendarViewModel.themeColor,
            action: { actions.openChat(reference) }
        ) {
            SocialSymbolAvatar(
                systemImage: community.kind == .section ? "person.2.fill" : "book.closed.fill",
                color: .indigo
            )
        } subtitle: {
            subtitleText(detail)
        }
        .contextMenu {
            Button("Class Page", systemImage: "rectangle.grid.2x2") {
                actions.openClassPage(community)
            }
        }
        .swipeActions {
            Button("Class Page") {
                actions.openClassPage(community)
            }
            .tint(.indigo)
        }
    }

    private var availableSemesterCodes: [String] {
        let groupCodes = socialManager.courseCommunities.compactMap(\.semesterCode)
        let enrollmentCodes = calendarViewModel.enrolledCourses.map(\.semesterCode)
        let earliest = calendarViewModel.academicHistoryStartSemester.rawValue
        return Array(Set(groupCodes + enrollmentCodes))
            .filter { $0 >= earliest }
            .sorted(by: >)
    }

    private var classFilterTitle: String {
        switch classTermFilter {
        case "current": return "This Term"
        case "all": return "All Terms"
        default: return semesterName(classTermFilter)
        }
    }

    private func semesterName(_ code: String) -> String {
        Semester(rawValue: code)?.displayName ?? code
    }

    private func visibleClassGroups() -> [SocialCourseCommunity] {
        let earliest = calendarViewModel.academicHistoryStartSemester.rawValue
        let enrolledTokens = Set(
            calendarViewModel.enrolledCourses
                .filter { $0.semesterCode >= earliest }
                .map { courseToken(subject: $0.course.subject, number: $0.course.number) }
        )
        // Section chats only for sections you're in now (an old section you
        // switched out of would look like a duplicate).
        let enrolledSections = Set(
            calendarViewModel.enrolledCourses.map {
                "\(courseToken(subject: $0.course.subject, number: $0.course.number))|\($0.semesterCode)|\($0.section.section)"
            }
        )
        // The same course can exist twice (older IDs, or created by the web
        // app); show one, the busiest.
        var seen: Set<String> = []
        let busiestFirst = socialManager.courseCommunities.sorted { $0.memberIDs.count > $1.memberIDs.count }
        let visible = busiestFirst.filter { group in
            let token = courseToken(subject: group.courseSubject, number: group.courseNumber)
            let sectionNumber = group.sectionLabel?.components(separatedBy: "Sec ").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let identity = group.kind == .course
                ? "course|\(token)"
                : "section|\(token)|\(group.semesterCode ?? "")|\(sectionNumber)"
            guard seen.insert(identity).inserted else { return false }
            if group.kind == .section {
                guard let code = group.semesterCode, code >= earliest else { return false }
                return enrolledSections.contains("\(token)|\(code)|\(sectionNumber)")
            }
            return enrolledTokens.contains(token)
        }

        let semesterCode: String?
        switch classTermFilter {
        case "all": semesterCode = nil
        case "current": semesterCode = calendarViewModel.currentSemester.rawValue
        default: semesterCode = classTermFilter
        }

        guard let semesterCode else {
            return visible
                .filter { $0.kind == .course || includeSectionChats }
                .sorted(by: sortClassGroups)
        }

        let termTokens = Set(
            calendarViewModel.enrolledCourses
                .filter { $0.semesterCode == semesterCode }
                .map { courseToken(subject: $0.course.subject, number: $0.course.number) }
        )
        return visible
            .filter { group in
                if group.kind == .section {
                    return includeSectionChats && group.semesterCode == semesterCode
                }
                return termTokens.contains(courseToken(subject: group.courseSubject, number: group.courseNumber))
            }
            .sorted(by: sortClassGroups)
    }

    private func sortClassGroups(_ lhs: SocialCourseCommunity, _ rhs: SocialCourseCommunity) -> Bool {
        if lhs.courseTitle == rhs.courseTitle {
            if lhs.kind == rhs.kind {
                return (lhs.sectionLabel ?? "") < (rhs.sectionLabel ?? "")
            }
            return lhs.kind == .course && rhs.kind == .section
        }
        return lhs.courseTitle.localizedCaseInsensitiveCompare(rhs.courseTitle) == .orderedAscending
    }

    private func courseToken(subject: String, number: String) -> String {
        "\(subject.uppercased().trimmingCharacters(in: .whitespaces))-\(number.trimmingCharacters(in: .whitespaces))"
    }
}

// MARK: - Row

/// A Messages-style row: avatar, title, subtitle, time, and an unread dot.
struct ChatRow<Avatar: View, Subtitle: View>: View {
    let title: String
    let lastActivity: Date?
    let isUnread: Bool
    let accent: Color
    let action: () -> Void
    @ViewBuilder let avatar: () -> Avatar
    @ViewBuilder let subtitle: () -> Subtitle

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                avatar()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MarqueeText(text: title, font: .body.weight(isUnread ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        if let lastActivity {
                            Text(ChatTimeText.short(lastActivity))
                                .font(.caption)
                                .foregroundStyle(isUnread ? accent : Color.secondary)
                                .fixedSize()
                        }
                    }

                    HStack(spacing: 8) {
                        subtitle()
                        Spacer(minLength: 0)
                        if isUnread {
                            Circle()
                                .fill(accent)
                                .frame(width: 10, height: 10)
                                .accessibilityLabel("Unread")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }
}

enum ChatTimeText {
    /// "1:05 PM" today, "Yesterday", "Mon" this week, then "9/12".
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }
}

extension SocialFriend {
    var asUser: SocialUser {
        SocialUser(
            id: id,
            username: username,
            displayName: displayName,
            email: email,
            isGuest: isGuest,
            shareSchedule: shareSchedule,
            shareLocation: shareLocation,
            createdAt: createdAt,
            lastScheduleAt: lastScheduleAt,
            sharedCourseKeys: sharedCourseKeys,
            sharedSectionKeys: sharedSectionKeys
        )
    }
}
