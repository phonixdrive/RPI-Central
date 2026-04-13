import SwiftUI
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

struct SocialHubView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager
    @AppStorage("social_show_campus_wide_group") private var showCampusWideGroup = true

    @State private var selectedSection: SocialHubSection = .friends
    @State private var authMode: AuthMode = .login
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var profileDisplayName: String = ""
    @State private var searchQuery: String = ""
    @State private var showFriendTools = false
    @State private var showCreateGroup = false
    @State private var showFeedComposer = false
    @State private var selectedFriendSchedule: FriendScheduleResponse?
    @State private var selectedGroupChat: SocialGroupChatReference?
    @State private var selectedGroupHub: GroupHubPresentation?
    @State private var selectedGroupMembers: GroupMembersPresentation?
    @State private var friendsExpanded = true
    @State private var groupsExpanded = true
    @State private var classGroupsExpanded = false
    @State private var classGroupFilter: ClassGroupFilter = .currentOverall
    @FocusState private var searchFieldFocused: Bool

    private var friendCount: Int { socialManager.overview?.friends.count ?? 0 }
    private var incomingCount: Int { socialManager.overview?.incomingRequests.count ?? 0 }
    private var feedRefreshTaskID: String {
        "\(selectedSection.rawValue)-\(calendarViewModel.socialFeedRefreshIntervalSeconds)-\(socialManager.currentUser?.id ?? "none")"
    }
    private var scheduleSyncTaskID: String {
        [
            socialManager.currentUser?.id ?? "none",
            calendarViewModel.currentSemester.rawValue,
            String(calendarViewModel.events.count),
            String(calendarViewModel.enrolledCourses.count),
            String(friendCount)
        ].joined(separator: "|")
    }

    var body: some View {
        socialHubScreen
    }

    private var socialHubScreen: AnyView {
        let navigation = AnyView(
            NavigationStack {
                rootContent
            }
            .tint(calendarViewModel.themeColor)
        )

        let decorated = AnyView(
            navigation
                .navigationTitle("Social")
                .toolbar { toolbarContent }
                .refreshable {
                    guard socialManager.isAuthenticated else { return }
                    await socialManager.refreshOverview()
                }
                .sheet(item: $selectedFriendSchedule) { schedule in friendScheduleSheet(schedule) }
                .sheet(item: $selectedGroupChat) { reference in groupChatSheet(reference) }
                .sheet(item: $selectedGroupHub) { presentation in groupHubSheet(presentation) }
                .sheet(item: $selectedGroupMembers) { presentation in groupMembersSheet(presentation) }
                .sheet(isPresented: $showFriendTools) { friendToolsSheet }
                .sheet(isPresented: $showCreateGroup) { createGroupSheet }
                .sheet(isPresented: $showFeedComposer) { feedComposerSheet }
        )

        let withTasks = AnyView(
            decorated
                .task {
                    if socialManager.isAuthenticated && socialManager.overview == nil {
                        await socialManager.refreshOverview()
                    }
                    syncProfileDisplayName()
                    await syncSharedScheduleIfNeeded()
                }
                .task(id: socialManager.currentUser?.displayName) {
                    syncProfileDisplayName()
                }
                .task(id: socialManager.currentUser?.id) {
                    syncProfileDisplayName()
                }
                .task(id: scheduleSyncTaskID) {
                    await syncSharedScheduleIfNeeded()
                }
                .task(id: feedRefreshTaskID) {
                    await runFeedRefreshLoop()
                }
                .task(id: selectedSection) {
                    guard selectedSection == .feed else { return }
                    await socialManager.refreshOverview()
                }
        )

        return withTasks
    }

    private var rootContent: some View {
        ZStack(alignment: .bottomTrailing) {
            backgroundGradient

            VStack(spacing: 0) {
                if shouldShowSectionBar {
                    sectionBar
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                }

                ScrollView {
                    LazyVStack(spacing: 16) {
                        screenSections
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, selectedSection == .feed || selectedSection == .friends ? 96 : 18)
                }
            }

            if socialManager.isAuthenticated && selectedSection == .feed {
                feedFloatingButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }

            if socialManager.isAuthenticated && selectedSection == .friends {
                friendToolsFloatingButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(.systemGroupedBackground),
                calendarViewModel.themeColor.opacity(0.14),
                Color(.systemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var shouldShowSectionBar: Bool {
        socialManager.isFirebaseAvailable && socialManager.isAuthenticated
    }

    @ViewBuilder
    private var screenSections: some View {
        if socialManager.isFirebaseAvailable && socialManager.isAuthenticated {
            authenticatedSections
        } else if socialManager.isFirebaseAvailable {
            unauthenticatedSections
        } else {
            setupCard
        }
    }

    @ViewBuilder
    private var authenticatedSections: some View {
        switch selectedSection {
        case .profile:
            heroCard
            setupCard
            profileCard
            sharingCard
            if calendarViewModel.socialDemoToolsEnabled {
                demoCard
            }
        case .feed:
            groupsCard
            feedListCard
        case .friends:
            friendsCard
            classGroupsCard
        }
    }

    @ViewBuilder
    private var unauthenticatedSections: some View {
        heroCard
        setupCard
        authCard
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if socialManager.isAuthenticated {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await socialManager.refreshOverview() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }

        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                searchFieldFocused = false
            }
        }
    }

    private var createGroupSheet: some View {
        FriendGroupEditorView(
            friends: socialManager.overview?.friends ?? [],
            accent: calendarViewModel.themeColor
        ) { name, memberIDs in
            let created = await socialManager.createFriendGroup(name: name, memberIDs: memberIDs)
            if created {
                await syncSharedScheduleIfNeeded()
            }
            return created
        }
    }

    private var feedComposerSheet: some View {
        FeedComposerView(
            groups: socialManager.friendGroups,
            accent: calendarViewModel.themeColor
        ) { title, location, details, startsAt, visibility, groupIDs in
            await socialManager.createFeedPost(
                title: title,
                location: location,
                details: details,
                startsAt: startsAt,
                visibility: visibility,
                groupIDs: groupIDs
            )
        }
    }

    private func friendScheduleSheet(_ schedule: FriendScheduleResponse) -> some View {
        FriendScheduleView(response: schedule)
    }

    private func groupChatSheet(_ reference: SocialGroupChatReference) -> some View {
        GroupChatSheet(reference: reference)
            .interactiveDismissDisabled()
    }

    private func groupHubSheet(_ presentation: GroupHubPresentation) -> some View {
        GroupHubSheet(presentation: presentation)
    }

    private func groupMembersSheet(_ presentation: GroupMembersPresentation) -> some View {
        GroupMembersSheet(presentation: presentation)
    }

    private var sectionBar: some View {
        HStack(spacing: 10) {
            sectionButton(title: "Friends", section: .friends)
            sectionButton(title: "Feed", section: .feed)
            sectionButton(title: "Profile", section: .profile)
        }
    }

    private var heroCard: some View {
        SocialCard(
            background: Color(red: 0.17, green: 0.19, blue: 0.23),
            stroke: Color.white.opacity(0.08)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(socialManager.isAuthenticated ? "Campus Hub" : "Campus Social")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text(
                            socialManager.isAuthenticated
                                ? "Friend requests, shared schedules, and quick campus coordination."
                                : "Sign in or continue as a guest to unlock schedules, friends, and sharing."
                        )
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.72))
                    }

                    Spacer()

                    Image(systemName: "person.3.sequence.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(calendarViewModel.themeColor)
                        .padding(12)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                }

                if socialManager.isAuthenticated {
                    HStack(spacing: 10) {
                        statPill(
                            title: "Friends",
                            value: "\(friendCount)",
                            background: Color.white.opacity(0.10),
                            valueColor: .white,
                            titleColor: Color.white.opacity(0.66)
                        )
                        statPill(
                            title: "Requests",
                            value: "\(incomingCount)",
                            background: Color.white.opacity(0.10),
                            valueColor: .white,
                            titleColor: Color.white.opacity(0.66)
                        )
                        statPill(
                            title: "Sharing",
                            value: socialManager.currentUser?.shareSchedule == true ? "On" : "Off",
                            background: Color.white.opacity(0.10),
                            valueColor: .white,
                            titleColor: Color.white.opacity(0.66)
                        )
                    }
                }
            }
        }
    }

    private var setupCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Firebase", systemImage: "bolt.shield")
                    .font(.headline)

                Text(socialManager.setupMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let statusMessage = socialManager.statusMessage {
                    messageBanner(text: statusMessage, color: .green)
                }

                if let errorMessage = socialManager.errorMessage {
                    messageBanner(text: errorMessage, color: .red)
                }
            }
        }
    }

    private var authCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Account", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)

                Picker("Mode", selection: $authMode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 10) {
                    if authMode.requiresDisplayName {
                        TextField("Display name", text: $displayName)
                            .textInputAutocapitalization(.words)
                            .textFieldStyle(.roundedBorder)
                    }

                    if authMode.requiresEmail {
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textFieldStyle(.roundedBorder)
                    }

                    if authMode.requiresPassword {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Button {
                    Task {
                        switch authMode {
                        case .login:
                            await socialManager.login(email: email, password: password)
                        case .register:
                            await socialManager.register(displayName: displayName, email: email, password: password)
                        case .guest:
                            await socialManager.continueAsGuest(displayName: displayName.isEmpty ? "Guest" : displayName)
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(authMode.buttonTitle)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    socialManager.isLoading ||
                    !socialManager.isFirebaseAvailable ||
                    !authMode.isFormValid(displayName: displayName, email: email, password: password)
                )
            }
        }
    }

    private var profileCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(socialManager.currentUser?.displayName ?? "Profile")
                            .font(.headline)
                        Text("@\(socialManager.currentUser?.username ?? "unknown")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(socialManager.currentUser?.isGuest == true ? "Guest" : "Account")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(calendarViewModel.themeColor.opacity(0.15)))
                }

                if let email = socialManager.currentUser?.email, !email.isEmpty {
                    LabeledContent("Email", value: email)
                        .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display name")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 10) {
                        TextField("Display name", text: $profileDisplayName)
                            .textInputAutocapitalization(.words)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            Task {
                                await socialManager.updateDisplayName(profileDisplayName)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            socialManager.isLoading ||
                            profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines) == socialManager.currentUser?.displayName
                        )
                    }

                    Text("This is the name your friends will see.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Sign out", role: .destructive) {
                    socialManager.logout()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sharingCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Sharing", systemImage: "calendar.badge.clock")
                    .font(.headline)

                Text("Share your schedule with accepted friends. Location sharing is reserved for a later pass.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Share my schedule with friends",
                    isOn: Binding(
                        get: { socialManager.currentUser?.shareSchedule ?? false },
                        set: { newValue in
                            Task {
                                await socialManager.updateShareSettings(
                                    shareSchedule: newValue,
                                    shareLocation: socialManager.currentUser?.shareLocation ?? false
                                )
                                if newValue {
                                    await socialManager.syncSchedule(from: calendarViewModel)
                                }
                            }
                        }
                    )
                )

                Button("Sync current schedule") {
                    Task {
                        await socialManager.syncSchedule(from: calendarViewModel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(socialManager.isLoading)
            }
        }
    }

    private var demoCard: some View {
        SocialCard(background: Color.orange.opacity(0.1), stroke: Color.orange.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Demo Data", systemImage: "wand.and.stars")
                    .font(.headline)

                Text("Create a searchable test user, an incoming request, and a demo friend with a shared schedule.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Seed demo social data") {
                    Task {
                        await socialManager.seedDemoData(for: calendarViewModel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(socialManager.isLoading)
            }
        }
    }

    private var findFriendsSearchCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Find Friends", systemImage: "magnifyingglass")
                    .font(.headline)

                if !socialManager.quickAddSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quick Add")
                            .font(.subheadline.weight(.semibold))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(socialManager.quickAddSuggestions) { result in
                                    quickAddCard(result)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField("Search by username or name", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFieldFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            Task {
                                searchFieldFocused = false
                                await socialManager.searchUsers(query: searchQuery)
                            }
                        }

                    Button("Search") {
                        Task {
                            searchFieldFocused = false
                            await socialManager.searchUsers(query: searchQuery)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if socialManager.searchResults.isEmpty {
                    Text("Search results will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(socialManager.searchResults) { result in
                            userResultCard(result)
                        }
                    }
                }
            }
        }
    }

    private var requestsCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Requests", systemImage: "tray.full")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Incoming")
                        .font(.subheadline.weight(.semibold))

                    if let requests = socialManager.overview?.incomingRequests, !requests.isEmpty {
                        ForEach(requests) { request in
                            requestCard(request, outgoing: false)
                        }
                    } else {
                        Text("No incoming requests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Outgoing")
                        .font(.subheadline.weight(.semibold))

                    if let requests = socialManager.overview?.outgoingRequests, !requests.isEmpty {
                        ForEach(requests) { request in
                            requestCard(request, outgoing: true)
                        }
                    } else {
                        Text("No outgoing requests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var friendsCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                collapsibleHeader(
                    title: "Friends",
                    systemImage: "person.2.fill",
                    countText: "\(socialManager.overview?.friends.count ?? 0)",
                    isExpanded: $friendsExpanded
                )

                if friendsExpanded {
                    if let friends = socialManager.overview?.friends, !friends.isEmpty {
                        LazyVStack(spacing: 10) {
                            ForEach(friends) { friend in
                                friendCard(friend)
                            }
                        }
                    } else {
                        Text("No friends yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var groupsCard: some View {
        let groups = socialManager.friendGroups
        let campusWideChat = showCampusWideGroup ? socialManager.campusWideChatReference : nil
        let friends = socialManager.overview?.friends ?? []
        let namesByID = Dictionary(
            uniqueKeysWithValues: friends.map { ($0.id, $0.displayName) } +
            [(socialManager.currentUser?.id ?? "self", socialManager.currentUser?.displayName ?? "You")]
        )
        let groupCount = groups.count + (campusWideChat == nil ? 0 : 1)

        return SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    collapsibleHeader(
                        title: "Groups",
                        systemImage: "person.3.fill",
                        countText: "\(groupCount)",
                        isExpanded: $groupsExpanded
                    )

                    Button {
                        showCreateGroup = true
                    } label: {
                        Label("New Group", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(friends.isEmpty)
                }

                if groupsExpanded {
                    Text("Create smaller circles for personal-event sharing and quick coordination.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let campusWideChat {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(campusWideChat.title)
                                        .font(.headline)
                                    Text(campusWideChat.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }

                            Text("A built-in campus-wide chat for everyone signed into RPI Central.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Button {
                                selectedGroupChat = campusWideChat
                            } label: {
                                Label("Open chat", systemImage: "bubble.left.and.bubble.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    }

                    if groups.isEmpty && campusWideChat == nil {
                        Text(friends.isEmpty ? "Add a friend first to start building groups." : "No groups yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !groups.isEmpty {
                        LazyVStack(spacing: 10) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Button {
                                        selectedGroupMembers = groupMembersPresentation(for: group, namesByID: namesByID)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .top) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(group.name)
                                                        .font(.headline)
                                                    Text("\(group.memberIDs.count + 1) members")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }

                                                Spacer()

                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text(groupSummary(for: group, namesByID: namesByID))
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    HStack(spacing: 10) {
                                        if let reference = socialManager.chatReference(for: group) {
                                            Button {
                                                selectedGroupChat = reference
                                            } label: {
                                                Label("Open chat", systemImage: "bubble.left.and.bubble.right")
                                                    .frame(maxWidth: .infinity)
                                                    .lineLimit(1)
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        if group.ownerID == socialManager.currentUser?.id {
                                            Button(role: .destructive) {
                                                Task {
                                                    let deleted = await socialManager.deleteFriendGroup(group.id)
                                                    if deleted {
                                                        await syncSharedScheduleIfNeeded()
                                                    }
                                                }
                                            } label: {
                                                Text("Delete")
                                                    .frame(maxWidth: .infinity)
                                                    .lineLimit(1)
                                            }
                                            .buttonStyle(.bordered)
                                        } else {
                                            Button(role: .destructive) {
                                                Task {
                                                    _ = await socialManager.leaveFriendGroup(group)
                                                }
                                            } label: {
                                                Text("Leave")
                                                    .frame(maxWidth: .infinity)
                                                    .lineLimit(1)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                            }
                        }
                    }
                }
            }
        }
    }

    private var classGroupsCard: some View {
        let classGroups = filteredClassGroups(from: socialManager.courseCommunities)

        return SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    collapsibleHeader(
                        title: "Class Groups",
                        systemImage: "books.vertical.fill",
                        countText: "\(classGroups.count)",
                        isExpanded: $classGroupsExpanded
                    )

                    Menu {
                        Button("Current Semester · Overall Class") {
                            classGroupFilter = .currentOverall
                        }

                        Button("Current Semester · All Groups") {
                            classGroupFilter = .currentAll
                        }

                        Button("All Semesters · Overall Class") {
                            classGroupFilter = .allOverall
                        }

                        Button("All Semesters · All Groups") {
                            classGroupFilter = .all
                        }

                        if !availableClassGroupSemesterCodes.isEmpty {
                            Divider()
                            ForEach(availableClassGroupSemesterCodes, id: \.self) { semesterCode in
                                Button(classGroupFilterTitle(for: .semesterOverall(semesterCode))) {
                                    classGroupFilter = .semesterOverall(semesterCode)
                                }
                                Button(classGroupFilterTitle(for: .semesterAll(semesterCode))) {
                                    classGroupFilter = .semesterAll(semesterCode)
                                }
                            }
                        }
                    } label: {
                        Label(classGroupFilterTitle(for: classGroupFilter), systemImage: "line.3.horizontal.decrease.circle")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }

                if classGroupsExpanded {
                    Text("These are created automatically from the sections you add, including one overall class group and one section group.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if classGroups.isEmpty {
                        Text("Enroll in a course to see class groups here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(classGroups) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(group.courseTitle)
                                                .font(.headline)
                                            Text("\(group.courseSubject) \(group.courseNumber)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        badgeLabel(
                                            group.kind == .course ? "Overall class" : "Section",
                                            color: group.kind == .course ? calendarViewModel.themeColor : .secondary
                                        )
                                    }

                                    HStack(spacing: 10) {
                                        Button {
                                            selectedGroupHub = groupHubPresentation(for: group)
                                        } label: {
                                            Label("Open hub", systemImage: "rectangle.grid.2x2")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            selectedGroupChat = socialManager.chatReference(for: group)
                                        } label: {
                                            Label("Open chat", systemImage: "bubble.left.and.bubble.right")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                            }
                        }
                    }
                }
            }
        }
    }

    private var feedHeaderCard: some View {
        SocialCard(
            background: Color(red: 0.16, green: 0.18, blue: 0.23),
            stroke: Color.white.opacity(0.08)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Campus Feed")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        Text("Share what you are doing right now and let people join in.")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    Spacer()

                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(calendarViewModel.themeColor)
                        .padding(12)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }

                Text("Tap the floating plus button to post a study session, meal, or hangout.")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
    }

    private var feedFloatingButton: some View {
        Button {
            showFeedComposer = true
        } label: {
            floatingActionCircle(
                icon: "plus",
                fill: calendarViewModel.themeColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create activity")
    }

    private var friendToolsFloatingButton: some View {
        Button {
            showFriendTools = true
        } label: {
            ZStack(alignment: .topTrailing) {
                floatingActionCircle(
                    icon: "person.badge.plus",
                    fill: Color(red: 0.20, green: 0.22, blue: 0.26)
                )

                if incomingCount > 0 {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 2)
                        )
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Friend tools")
    }

    private var feedListCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live Activity")
                            .font(.headline)
                        Text("Recent plans, meetups, and who is already there.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await socialManager.refreshOverview() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Text("Post quick plans, study sessions, and hangouts. Activities auto-end after 6 hours if nobody closes them first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if socialManager.feedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No activity yet.")
                            .font(.subheadline.weight(.semibold))
                        Text("Start the feed with a study session, meal plan, or hangout.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(socialManager.feedItems) { item in
                            feedPostCard(item)
                        }
                    }
                }
            }
        }
    }

    private func userResultCard(_ result: SocialSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayName)
                        .font(.headline)
                    Text("@\(result.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if result.areFriends {
                    badgeLabel("Friends", color: .green)
                } else if result.hasPendingOutgoing {
                    badgeLabel("Pending", color: .secondary)
                } else if result.hasPendingIncoming {
                    badgeLabel("Requested you", color: .orange)
                } else {
                    Button("Add") {
                        Task {
                            await socialManager.sendFriendRequest(toUserID: result.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !result.email.isEmpty {
                Text(result.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func quickAddCard(_ result: SocialSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text("@\(result.username)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if result.hasPendingOutgoing {
                Text("Pending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    Task {
                        await socialManager.sendFriendRequest(toUserID: result.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(width: 145, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func requestCard(_ request: SocialFriendRequest, outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let user = outgoing ? request.toUser : request.fromUser
            Text(user?.displayName ?? "Unknown User")
                .font(.headline)
            Text("@\(user?.username ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !outgoing {
                HStack {
                    Button("Accept") {
                        Task {
                            await socialManager.respondToFriendRequest(request.id, action: "accept")
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Decline", role: .destructive) {
                        Task {
                            await socialManager.respondToFriendRequest(request.id, action: "decline")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func friendCard(_ friend: SocialFriend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName)
                        .font(.headline)
                    Text("@\(friend.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                badgeLabel(friend.shareSchedule ? "Sharing on" : "Sharing off", color: friend.shareSchedule ? .green : .secondary)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await socialManager.unfriend(friend.id)
                    }
                } label: {
                    Text("Remove friend")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if friend.canViewSchedule {
                    Button("View schedule") {
                        Task {
                            await socialManager.loadFriendSchedule(friendID: friend.id)
                            if let schedule = socialManager.loadedFriendSchedule {
                                selectedFriendSchedule = schedule
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func feedPostCard(_ item: SocialFeedItem) -> some View {
        let hereResponses = item.responses.filter { $0.status == .here }
        let goingResponses = item.responses.filter { $0.status == .going }
        let myStatus = item.responses.first { $0.userID == socialManager.currentUser?.id }?.status
        let isOwnPost = item.post.ownerID == socialManager.currentUser?.id
        let canEndPost = isOwnPost || socialManager.canModerateSocialContent
        let isEnded = feedIsEnded(item)
        let isUpcoming = feedIsUpcoming(item)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(calendarViewModel.themeColor.opacity(0.14))
                        .frame(width: 42, height: 42)
                        .overlay(
                            Text(String(item.post.ownerDisplayName.prefix(1)).uppercased())
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(calendarViewModel.themeColor)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.post.title)
                            .font(.headline.weight(.semibold))
                        HStack(spacing: 8) {
                            Text(item.post.ownerDisplayName)
                                .font(.caption.weight(.semibold))
                            Text("@\(item.post.ownerUsername)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    badgeLabel(feedStateText(for: item), color: feedStateColor(for: item))
                    badgeLabel(feedVisibilityText(for: item.post), color: .secondary)
                }
            }

            if !item.post.location.isEmpty {
                Label(item.post.location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(feedTimingText(for: item), systemImage: isEnded ? "checkmark.circle" : "clock")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !item.post.details.isEmpty {
                Text(item.post.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                feedPresencePill("Going", count: goingResponses.count, names: goingResponses.map(\.displayName), color: .blue)
                feedPresencePill("Here", count: hereResponses.count, names: hereResponses.map(\.displayName), color: .green)
            }

            if !isEnded {
                HStack(spacing: 8) {
                    feedActionButton("Going", icon: "figure.walk", isSelected: myStatus == .going) {
                        Task {
                            let nextStatus: SocialFeedPresenceStatus? = myStatus == .going ? nil : .going
                            _ = await socialManager.setFeedPresence(postID: item.post.id, status: nextStatus)
                        }
                    }

                    if !isUpcoming {
                        feedActionButton("Here", icon: "location.fill", isSelected: myStatus == .here) {
                            Task {
                                let nextStatus: SocialFeedPresenceStatus? = myStatus == .here ? nil : .here
                                _ = await socialManager.setFeedPresence(postID: item.post.id, status: nextStatus)
                            }
                        }
                    }
                }
            }

            if isOwnPost || canEndPost {
                HStack(spacing: 10) {
                    if !isEnded && canEndPost {
                        Button("End activity") {
                            Task {
                                _ = await socialManager.endFeedPost(item.post)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    if isOwnPost {
                        Button("Delete post", role: .destructive) {
                            Task {
                                _ = await socialManager.deleteFeedPost(item.post.id)
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
    }

    private func statPill(
        title: String,
        value: String,
        background: Color = Color.white.opacity(0.75),
        valueColor: Color = .primary,
        titleColor: Color = .secondary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(valueColor)
            Text(title)
                .font(.caption)
                .foregroundStyle(titleColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(background))
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private func collapsibleHeader(
        title: String,
        systemImage: String,
        countText: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(countText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(calendarViewModel.themeColor.opacity(0.12)))
                    .foregroundStyle(calendarViewModel.themeColor)

                Spacer()

                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func feedPresencePill(_ title: String, count: Int, names: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count) \(title.lowercased())")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            if !names.isEmpty {
                Text(names.prefix(2).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.08)))
    }

    private func feedActionButton(_ title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isSelected ? calendarViewModel.themeColor : Color(.tertiarySystemFill))
    }

    private func messageBanner(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
    }

    private func floatingActionCircle(icon: String, fill: Color) -> some View {
        Image(systemName: icon)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(
                Circle()
                    .fill(fill)
                    .shadow(color: fill.opacity(0.30), radius: 16, y: 8)
            )
    }

    private var friendToolsSheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        calendarViewModel.themeColor.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        findFriendsSearchCard
                        requestsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showFriendTools = false
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        searchFieldFocused = false
                    }
                }
            }
            .task {
                await socialManager.loadQuickAddSuggestions()
            }
        }
    }

    private func sectionButton(title: String, section: SocialHubSection, badgeCount: Int = 0) -> some View {
        let isSelected = selectedSection == section

        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.2) : calendarViewModel.themeColor.opacity(0.16)))
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? calendarViewModel.themeColor : Color(.secondarySystemBackground).opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? calendarViewModel.themeColor.opacity(0.2) : Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func syncSharedScheduleIfNeeded() async {
        guard socialManager.isAuthenticated else { return }
        await socialManager.syncCourseCommunities(from: calendarViewModel)
        guard socialManager.currentUser?.shareSchedule == true else { return }
        await socialManager.syncSchedule(from: calendarViewModel)
    }

    private func syncProfileDisplayName() {
        profileDisplayName = socialManager.currentUser?.displayName ?? ""
    }

    private func runFeedRefreshLoop() async {
        guard socialManager.isAuthenticated, selectedSection == .feed else { return }
        guard calendarViewModel.socialFeedRefreshIntervalSeconds > 0 else { return }

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(calendarViewModel.socialFeedRefreshIntervalSeconds) * 1_000_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  socialManager.isAuthenticated,
                  selectedSection == .feed,
                  calendarViewModel.socialFeedRefreshIntervalSeconds > 0 else { return }

            await socialManager.refreshOverview()
        }
    }

    private func groupSummary(for group: SocialFriendGroup, namesByID: [String: String]) -> String {
        let names = ([group.ownerID] + group.memberIDs).compactMap { namesByID[$0] }
        if names.isEmpty {
            return "Members unavailable"
        }
        if names.count <= 3 {
            return names.joined(separator: ", ")
        }
        return "\(names.prefix(3).joined(separator: ", ")) +\(names.count - 3)"
    }

    private func groupMembersPresentation(for group: SocialFriendGroup, namesByID: [String: String]) -> GroupMembersPresentation {
        let orderedIDs = [group.ownerID] + group.memberIDs
        var seen: Set<String> = []
        let uniqueIDs = orderedIDs.filter { seen.insert($0).inserted }
        let names = uniqueIDs.compactMap { namesByID[$0] }
        let addableFriends = (socialManager.overview?.friends ?? [])
            .filter { !uniqueIDs.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return GroupMembersPresentation(
            title: group.name,
            subtitle: "\(uniqueIDs.count) members",
            memberNames: names,
            group: group,
            addableFriends: addableFriends
        )
    }

    private func groupHubPresentation(for community: SocialCourseCommunity) -> GroupHubPresentation {
        let reference = socialManager.chatReference(for: community)
        let memberNames = reference.memberDisplayNames.isEmpty ? [reference.subtitle] : reference.memberDisplayNames
        return GroupHubPresentation(
            id: "course-\(community.id)",
            title: reference.title,
            subtitle: reference.subtitle,
            memberNames: memberNames,
            reference: reference,
            courseCommunity: community
        )
    }

    private var availableClassGroupSemesterCodes: [String] {
        let groupCodes = socialManager.courseCommunities.compactMap(\.semesterCode)
        let enrollmentCodes = calendarViewModel.enrolledCourses.map(\.semesterCode)
        return Array(Set(groupCodes + enrollmentCodes)).sorted(by: >)
    }

    private func classGroupFilterTitle(for filter: ClassGroupFilter) -> String {
        switch filter {
        case .currentOverall:
            return "This Term • Course-wide"
        case .currentAll:
            return "This Term • Course + Section"
        case .allOverall:
            return "All Terms • Course-wide"
        case .all:
            return "All Terms • Course + Section"
        case .semesterOverall(let code):
            return "\(Semester(rawValue: code)?.displayName ?? code) • Course-wide"
        case .semesterAll(let code):
            return "\(Semester(rawValue: code)?.displayName ?? code) • Course + Section"
        }
    }

    private func filteredClassGroups(from groups: [SocialCourseCommunity]) -> [SocialCourseCommunity] {
        let semesterCode: String?
        switch classGroupFilter {
        case .currentOverall, .currentAll:
            semesterCode = calendarViewModel.currentSemester.rawValue
        case .allOverall, .all:
            semesterCode = nil
        case .semesterOverall(let code), .semesterAll(let code):
            semesterCode = code
        }

        let showsSectionGroups: Bool
        switch classGroupFilter {
        case .currentAll, .all, .semesterAll:
            showsSectionGroups = true
        default:
            showsSectionGroups = false
        }

        guard let semesterCode else {
            return groups
                .filter { group in
                    group.kind == .course || showsSectionGroups
                }
                .sorted(by: sortClassGroups)
        }

        let matchingCourseTokens = Set(
            calendarViewModel.enrolledCourses
                .filter { $0.semesterCode == semesterCode }
                .map { classGroupCourseToken(subject: $0.course.subject, number: $0.course.number) }
        )

        return groups.filter { group in
            if group.kind == .section {
                return showsSectionGroups && group.semesterCode == semesterCode
            }
            return matchingCourseTokens.contains(
                classGroupCourseToken(subject: group.courseSubject, number: group.courseNumber)
            )
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

    private func classGroupCourseToken(subject: String, number: String) -> String {
        "\(subject.uppercased())-\(number)"
    }

    private func feedStateText(for item: SocialFeedItem) -> String {
        if feedIsEnded(item) {
            return "Ended"
        }
        return feedIsUpcoming(item) ? "Upcoming" : "Ongoing"
    }

    private func feedStateColor(for item: SocialFeedItem) -> Color {
        switch feedStateText(for: item) {
        case "Upcoming":
            return .blue
        case "Ongoing":
            return .green
        default:
            return .secondary
        }
    }

    private func feedVisibilityText(for post: SocialFeedPost) -> String {
        switch post.visibility {
        case .friends:
            return "Friends"
        case .everyone:
            return "Everybody"
        case .groups:
            return "Groups"
        }
    }

    private func feedTimingText(for item: SocialFeedItem) -> String {
        let now = Date()
        if let endedAt = effectiveFeedEndedDate(for: item.post) {
            return "Ended \(FeedFormatters.relative.localizedString(for: endedAt, relativeTo: now))"
        }
        if let startsAt = feedDate(item.post.startsAt) {
            if startsAt > now {
                return "Starts \(FeedFormatters.shortDateTime.string(from: startsAt))"
            }
            return "Started \(FeedFormatters.relative.localizedString(for: startsAt, relativeTo: now))"
        }
        return "Recently posted"
    }

    private func feedDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return FeedFormatters.iso.date(from: value)
    }

    private func feedIsEnded(_ item: SocialFeedItem) -> Bool {
        effectiveFeedEndedDate(for: item.post) != nil
    }

    private func feedIsUpcoming(_ item: SocialFeedItem) -> Bool {
        guard let startsAt = feedDate(item.post.startsAt), !feedIsEnded(item) else { return false }
        return startsAt > Date()
    }

    private func effectiveFeedEndedDate(for post: SocialFeedPost) -> Date? {
        if let endedAt = feedDate(post.endedAt) {
            return endedAt
        }
        guard let startsAt = feedDate(post.startsAt) else { return nil }
        let autoExpireDate = startsAt.addingTimeInterval(6 * 60 * 60)
        return autoExpireDate <= Date() ? autoExpireDate : nil
    }
}

private enum SocialHubSection: String {
    case friends
    case feed
    case profile
}

private struct FeedComposerView: View {
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
    @FocusState private var focusedField: FeedComposerField?
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
            ScrollView {
                VStack(spacing: 16) {
                    SocialCard(
                        background: Color(red: 0.16, green: 0.18, blue: 0.23),
                        stroke: Color.white.opacity(0.08)
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Create Activity")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                            Text("Post something people can join, keep it ongoing, and end it when you are done.")
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                    }

                    SocialCard {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Activity")
                                    .font(.subheadline.weight(.semibold))

                                TextField("Studying at Union", text: $title)
                                    .textInputAutocapitalization(.sentences)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .title)

                                TextField("Location", text: $location)
                                    .textInputAutocapitalization(.words)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .location)

                                TextField("Optional details", text: $details, axis: .vertical)
                                    .textInputAutocapitalization(.sentences)
                                    .lineLimit(2...5)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .details)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Starts")
                                    .font(.subheadline.weight(.semibold))

                                DatePicker(
                                    "Start time",
                                    selection: $startsAt,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                .datePickerStyle(.compact)
                                .tint(accent)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Visibility")
                                    .font(.subheadline.weight(.semibold))

                                Picker("Visibility", selection: $visibility) {
                                    ForEach(SocialFeedVisibility.allCases) { option in
                                        Text(option.title).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)

                                if visibility == .groups {
                                    if groups.isEmpty {
                                        Text("Create a group first before posting a group-only activity.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        VStack(spacing: 10) {
                                            ForEach(groups) { group in
                                                Button {
                                                    toggle(group.id)
                                                } label: {
                                                    HStack(spacing: 10) {
                                                        Image(systemName: selectedGroupIDs.contains(group.id) ? "checkmark.circle.fill" : "circle")
                                                            .foregroundStyle(selectedGroupIDs.contains(group.id) ? accent : .secondary)
                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text(group.name)
                                                                .foregroundStyle(.primary)
                                                            Text("\(group.memberIDs.count) member\(group.memberIDs.count == 1 ? "" : "s")")
                                                                .font(.caption)
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        Spacer()
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        accent.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .navigationTitle("New Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        isSaving = true
                        let selectedIDs = Array(selectedGroupIDs).sorted()
                        Task {
                            let didSave = await onSave(
                                title.trimmingCharacters(in: .whitespacesAndNewlines),
                                location.trimmingCharacters(in: .whitespacesAndNewlines),
                                details.trimmingCharacters(in: .whitespacesAndNewlines),
                                startsAt,
                                visibility,
                                selectedIDs
                            )
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

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
    }

    private func toggle(_ groupID: String) {
        if selectedGroupIDs.contains(groupID) {
            selectedGroupIDs.remove(groupID)
        } else {
            selectedGroupIDs.insert(groupID)
        }
    }
}

private enum FeedComposerField: Hashable {
    case title
    case location
    case details
}

private struct FriendGroupEditorView: View {
    let friends: [SocialFriend]
    let accent: Color
    let onSave: (_ name: String, _ memberIDs: [String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var selectedMemberIDs: Set<String> = []
    @State private var isSaving = false

    private var sortedFriends: [SocialFriend] {
        friends.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var canSave: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedMemberIDs.isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Group") {
                    TextField("Group name", text: $groupName)
                        .textInputAutocapitalization(.words)
                }

                Section("Members") {
                    if sortedFriends.isEmpty {
                        Text("No friends available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedFriends) { friend in
                            Button {
                                toggle(friend.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedMemberIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedMemberIDs.contains(friend.id) ? accent : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friend.displayName)
                                            .foregroundStyle(.primary)
                                        Text("@\(friend.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        accent.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .navigationTitle("New Group")
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

private struct GroupChatSheet: View {
    let reference: SocialGroupChatReference

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool

    @State private var messages: [SocialGroupChatMessage] = []
    @State private var draftMessage: String = ""
    @State private var isSending = false
    @State private var didPerformInitialScroll = false
    @State private var participantsByID: [String: SocialUser] = [:]
    @State private var selectedProfileUser: SocialUser?
#if canImport(FirebaseFirestore)
    @State private var chatListener: ListenerRegistration?
#endif

    private let bottomAnchorID = "group-chat-bottom-anchor"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    conversationHeader

                    ZStack {
                        if messages.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(calendarViewModel.themeColor)
                                Text("No messages yet.")
                                    .font(.headline)
                                Text("Start the chat for this group.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                composerFocused = false
                            }
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(messages) { message in
                                        chatMessageRow(message)
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
                .navigationTitle(reference.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                .task(id: reference.id) {
                    socialManager.setActiveGroupChat(id: reference.id)
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
        .sheet(item: $selectedProfileUser) { user in
            SocialUserProfileSheet(user: user)
        }
    }

    private var conversationHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !participantProfiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(participantProfiles) { user in
                            Button {
                                selectedProfileUser = user
                            } label: {
                                Text(user.displayName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(calendarViewModel.themeColor.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if !reference.memberDisplayNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(reference.memberDisplayNames, id: \.self) { name in
                            Text(name)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(calendarViewModel.themeColor.opacity(0.12))
                                )
                        }
                    }
                }
            } else {
                Text(reference.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func composerBar(proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Send a message", text: $draftMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemBackground))
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
                    if didSend {
                        await MainActor.run {
                            draftMessage = ""
                            scrollToBottom(proxy, animated: true)
                        }
                    }
                    await MainActor.run {
                        isSending = false
                    }
                }
            } label: {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func chatMessageRow(_ message: SocialGroupChatMessage) -> some View {
        let isMine = message.userID == socialManager.currentUser?.id

        return HStack {
            if isMine { Spacer(minLength: 50) }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await openProfile(for: message.userID)
                        }
                    } label: {
                        Text(message.displayName)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(chatTimestamp(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isMine ? calendarViewModel.themeColor.opacity(0.16) : Color(.secondarySystemBackground))
            )

            if !isMine { Spacer(minLength: 50) }
        }
    }

    private func startListening(proxy: ScrollViewProxy) async {
        await MainActor.run {
            didPerformInitialScroll = false
        }
        let initialMessages = await socialManager.loadGroupChatMessages(for: reference)
        await refreshParticipants(using: initialMessages)
        await MainActor.run {
            messages = initialMessages
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
            messages = updatedMessages
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
        if let date = groupChatISOFormatter.date(from: isoString)
            ?? groupChatISOFormatterWithFractionalSeconds.date(from: isoString) {
            return groupChatTimestampFormatter.string(from: date)
        }
        return "Now"
    }
}

private struct SocialUserProfileSheet: View {
    let user: SocialUser

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    private var isCurrentUser: Bool {
        socialManager.currentUser?.id == user.id
    }

    private var isFriend: Bool {
        socialManager.overview?.friends.contains(where: { $0.id == user.id }) == true
    }

    private var incomingRequest: SocialFriendRequest? {
        socialManager.overview?.incomingRequests.first(where: { $0.fromUser?.id == user.id })
    }

    private var hasOutgoingRequest: Bool {
        socialManager.overview?.outgoingRequests.contains(where: { $0.toUser?.id == user.id }) == true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                SocialCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(calendarViewModel.themeColor.opacity(0.14))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Text(String(user.displayName.prefix(1)).uppercased())
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(calendarViewModel.themeColor)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.displayName)
                                    .font(.title3.weight(.semibold))
                                Text("@\(user.username)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        if isCurrentUser {
                            Text("This is your profile.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if isFriend {
                            Text("You are already friends.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if hasOutgoingRequest {
                            Text("Friend request sent.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if incomingRequest != nil {
                            Text("This person already sent you a friend request.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let request = incomingRequest {
                    SocialCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Friend Request")
                                .font(.headline)

                            HStack(spacing: 10) {
                                Button("Accept") {
                                    Task {
                                        await socialManager.respondToFriendRequest(request.id, action: "accept")
                                        await MainActor.run {
                                            dismiss()
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Decline", role: .destructive) {
                                    Task {
                                        await socialManager.respondToFriendRequest(request.id, action: "decline")
                                        await MainActor.run {
                                            dismiss()
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                } else if !isCurrentUser && !isFriend && !hasOutgoingRequest {
                    SocialCard {
                        Button {
                            Task {
                                await socialManager.sendFriendRequest(toUserID: user.id)
                            }
                        } label: {
                            Label("Send friend request", systemImage: "person.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
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
                .ignoresSafeArea()
            )
            .navigationTitle("Profile")
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

private enum ClassGroupFilter: Equatable {
    case currentOverall
    case currentAll
    case allOverall
    case all
    case semesterOverall(String)
    case semesterAll(String)
}

private struct GroupMembersPresentation: Identifiable {
    let title: String
    let subtitle: String
    let memberNames: [String]
    let group: SocialFriendGroup?
    let addableFriends: [SocialFriend]

    var id: String { title + subtitle }
}

private struct GroupMembersSheet: View {
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
                Section {
                    Text("\(memberNames.count) members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Members") {
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

struct SocialCard<Content: View>: View {
    var background: Color = Color(.systemBackground)
    var stroke: Color = Color.primary.opacity(0.06)
    let content: Content

    init(
        background: Color = Color(.systemBackground),
        stroke: Color = Color.primary.opacity(0.06),
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.stroke = stroke
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 6)
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case login
    case register
    case guest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .login: return "Login"
        case .register: return "Register"
        case .guest: return "Guest"
        }
    }

    var buttonTitle: String {
        switch self {
        case .login: return "Sign in"
        case .register: return "Create account"
        case .guest: return "Continue as guest"
        }
    }

    var requiresDisplayName: Bool {
        switch self {
        case .login: return false
        case .register, .guest: return true
        }
    }

    var requiresEmail: Bool {
        switch self {
        case .login, .register: return true
        case .guest: return false
        }
    }

    var requiresPassword: Bool {
        switch self {
        case .login, .register: return true
        case .guest: return false
        }
    }

    func isFormValid(displayName: String, email: String, password: String) -> Bool {
        switch self {
        case .login:
            return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !password.isEmpty
        case .register:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                password.count >= 6
        case .guest:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private enum FeedFormatters {
    static let iso = ISO8601DateFormatter()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private let groupChatTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

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

private struct FriendScheduleView: View {
    let response: FriendScheduleResponse
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var preparedData: FriendSchedulePreparedData?
    @State private var isPreparing = false
    @State private var selectedDate: Date = Date()
    @State private var displayedMonth: Date = FriendScheduleCalendar.startOfMonth(for: Date())

    private var selectedDateItems: [ParsedScheduleItem] {
        preparedData?.cache.items(on: selectedDate) ?? []
    }

    private var monthTitle: String {
        FriendScheduleFormatters.month.string(from: displayedMonth)
    }

    private var generatedAtText: String? {
        guard let generatedAt = response.schedule.generatedAt,
              let date = FriendScheduleFormatters.iso.date(from: generatedAt) else { return nil }
        return FriendScheduleFormatters.generatedAt.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SocialCard(background: Color(.secondarySystemBackground), stroke: calendarViewModel.themeColor.opacity(0.15)) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(response.owner.displayName)
                                        .font(.title3.bold())
                                    Text("@\(response.owner.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                badge(for: response.owner.shareSchedule ? "Sharing enabled" : "Sharing off")
                            }

                            if let generatedAtText {
                                Label("Updated \(generatedAtText)", systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !response.schedule.semesterCode.isEmpty {
                                Label(response.schedule.semesterCode, systemImage: "graduationcap")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let preparedData {
                        SocialCard(
                            background: Color.black.opacity(0.88),
                            stroke: calendarViewModel.themeColor.opacity(0.22)
                        ) {
                            VStack(spacing: 14) {
                                HStack {
                                    Button {
                                        shiftMonth(by: -1)
                                    } label: {
                                        Image(systemName: "chevron.left")
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()

                                    Text(monthTitle)
                                        .font(.headline)
                                        .foregroundStyle(.white)

                                    Spacer()

                                    Button {
                                        shiftMonth(by: 1)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                FriendScheduleMonthGrid(
                                    displayedMonth: displayedMonth,
                                    selectedDate: selectedDate,
                                    cache: preparedData.cache,
                                    accent: calendarViewModel.themeColor
                                ) { day in
                                    selectedDate = day
                                }
                            }
                        }

                        SocialCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(FriendScheduleFormatters.selectedDayHeader.string(from: selectedDate))
                                    .font(.headline)

                                if selectedDateItems.isEmpty {
                                    Text("No shared items on this day.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    LazyVStack(spacing: 10) {
                                        ForEach(selectedDateItems) { item in
                                            FriendScheduleEventRow(item: item, accent: calendarViewModel.themeColor)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        SocialCard {
                            HStack(spacing: 12) {
                                ProgressView()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Loading shared schedule")
                                        .font(.headline)
                                    Text("Optimizing the calendar for this device.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(response.owner.displayName)
            .task(id: response.owner.id) {
                await prepareScheduleIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func shiftMonth(by value: Int) {
        let nextMonth = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
        displayedMonth = FriendScheduleCalendar.startOfMonth(for: nextMonth)
    }

    private func badge(for text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(calendarViewModel.themeColor.opacity(0.14)))
            .foregroundStyle(calendarViewModel.themeColor)
    }

    private func prepareScheduleIfNeeded() async {
        guard preparedData == nil, !isPreparing else { return }
        isPreparing = true

        let schedule = response.schedule
        let prepared = await withCheckedContinuation { (continuation: CheckedContinuation<FriendSchedulePreparedData, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FriendSchedulePreparedData(schedule: schedule))
            }
        }

        preparedData = prepared
        selectedDate = prepared.anchorDate
        displayedMonth = FriendScheduleCalendar.startOfMonth(for: prepared.anchorDate)
        isPreparing = false
    }
}

private struct FriendSchedulePreparedData {
    let cache: FriendScheduleCache
    let anchorDate: Date

    init(schedule: SharedScheduleSnapshot) {
        let items = schedule.items
            .compactMap { ParsedScheduleItem(item: $0) }
            .sorted { $0.startDate < $1.startDate }
        self.cache = FriendScheduleCache(items: items)
        self.anchorDate = Date()
    }
}

private struct ParsedScheduleItem: Identifiable {
    let id: String
    let title: String
    let location: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let kind: String
    let badge: String?
    let markerStyle: FriendScheduleMarkerStyle

    var isExam: Bool {
        badge?.lowercased() == "exam"
    }

    var formattedTime: String {
        if isAllDay {
            return "All day"
        }
        let start = FriendScheduleFormatters.time.string(from: startDate)
        let end = FriendScheduleFormatters.time.string(from: endDate)
        return "\(start) - \(end)"
    }

    init?(item: SharedScheduleItem) {
        guard let startDate = FriendScheduleFormatters.iso.date(from: item.startDate),
              let endDate = FriendScheduleFormatters.iso.date(from: item.endDate) else {
            return nil
        }

        self.id = item.id
        self.title = item.title
        self.location = item.location
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = item.isAllDay
        self.kind = item.kind
        self.badge = item.badge
        self.markerStyle = FriendScheduleMarkerStyle(kind: item.kind)
    }
}

private struct FriendScheduleMonthGrid: View {
    let displayedMonth: Date
    let selectedDate: Date
    let cache: FriendScheduleCache
    let accent: Color
    let onSelectDay: (Date) -> Void

    var body: some View {
        let calendar = FriendScheduleCalendar.calendar
        let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) ?? DateInterval()
        let start = monthInterval.start
        let range: Range<Int> = calendar.range(of: .day, in: .month, for: start) ?? (1..<32)
        let leadingBlanks = FriendScheduleCalendar.leadingBlankCount(for: start)
        let totalCells = leadingBlanks + range.count
        let rows = Int(ceil(Double(totalCells) / 7.0))
        let today = Date()

        VStack(spacing: 4) {
            HStack {
                ForEach(FriendScheduleCalendar.shortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col
                        let dayNumber = index - leadingBlanks + 1

                        if dayNumber < 1 || dayNumber > range.count {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(height: 40)
                                .frame(maxWidth: .infinity)
                        } else {
                            let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: start) ?? start
                            let summary = cache.summary(on: date)
                            FriendScheduleDayCell(
                                date: date,
                                monthStart: displayedMonth,
                                isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                                isToday: calendar.isDate(date, inSameDayAs: today),
                                summary: summary,
                                accent: accent
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectDay(date)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct FriendScheduleDayCell: View {
    let date: Date
    let monthStart: Date
    let isSelected: Bool
    let isToday: Bool
    let summary: FriendScheduleDaySummary
    let accent: Color

    var body: some View {
        let calendar = Calendar.current
        let inMonth = calendar.isDate(date, equalTo: monthStart, toGranularity: .month)
        let hasBreakDay = summary.markerStyles.contains(.breakDay)

        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color.black
                            : (inMonth ? Color.white : Color.white.opacity(0.38))
                    )

                if summary.hasExam {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(isSelected ? Color.black : Color.yellow)
                }
            }
            .frame(maxWidth: .infinity)

            if summary.markerStyles.isEmpty {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 5, height: 5)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(summary.markerStyles.prefix(3).enumerated()), id: \.offset) { pair in
                        Circle()
                            .fill(pair.element.color(accent: accent))
                            .frame(width: 5, height: 5)
                    }

                    if summary.itemCount > summary.markerStyles.count {
                        Text("+")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(isSelected ? Color.black : Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(5)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(
            Group {
                if isSelected {
                    Color.white
                } else if hasBreakDay {
                    Color.orange.opacity(0.22)
                } else {
                    Color.clear
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.clear
                        : (isToday ? Color.white.opacity(0.9) : Color.clear),
                    lineWidth: 1.6
                )
        )
        .cornerRadius(7)
    }
}

private enum FriendScheduleMarkerStyle: Hashable {
    case classMeeting
    case assignment
    case holiday
    case breakDay
    case readingDays
    case finals
    case noClasses
    case followDay
    case academicOther
    case personal

    init(kind: String) {
        switch kind {
        case "classMeeting":
            self = .classMeeting
        case "assignment":
            self = .assignment
        case "holiday":
            self = .holiday
        case "break":
            self = .breakDay
        case "readingDays":
            self = .readingDays
        case "finals":
            self = .finals
        case "noClasses":
            self = .noClasses
        case "followDay":
            self = .followDay
        case "academicOther", "academic":
            self = .academicOther
        default:
            self = .personal
        }
    }

    func color(accent: Color) -> Color {
        switch self {
        case .classMeeting:
            return accent
        case .assignment:
            return .blue
        case .holiday:
            return .red
        case .breakDay:
            return .orange
        case .readingDays:
            return .blue
        case .finals:
            return .purple
        case .noClasses:
            return .gray
        case .followDay:
            return .teal
        case .academicOther:
            return .yellow
        case .personal:
            return accent.opacity(0.7)
        }
    }

    func labelText(isExam: Bool) -> String {
        switch self {
        case .classMeeting:
            return isExam ? "Class + Exam" : "Class"
        case .assignment:
            return "Assignment"
        case .holiday:
            return "Holiday"
        case .breakDay:
            return "Break"
        case .readingDays:
            return "Reading Days"
        case .finals:
            return "Finals"
        case .noClasses:
            return "No Classes"
        case .followDay:
            return "Follow Day"
        case .academicOther:
            return "Academic"
        case .personal:
            return "Personal"
        }
    }
}

private struct FriendScheduleEventRow: View {
    let item: ParsedScheduleItem
    let accent: Color

    private var indicatorColor: Color {
        item.markerStyle.color(accent: accent)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(indicatorColor.opacity(0.18))
                .frame(width: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(indicatorColor)
                        .frame(width: 4)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title)
                        .font(.headline)

                    if item.isExam {
                        Label("Exam", systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text(item.formattedTime)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !item.location.isEmpty {
                    Label(item.location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.markerStyle.labelText(isExam: item.isExam))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(indicatorColor)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
    }
}

private struct FriendScheduleCache {
    let items: [ParsedScheduleItem]
    private let itemsByDayKey: [String: [ParsedScheduleItem]]
    private let summaryByDayKey: [String: FriendScheduleDaySummary]

    init(items: [ParsedScheduleItem]) {
        self.items = items

        var grouped: [String: [ParsedScheduleItem]] = [:]
        var summaries: [String: FriendScheduleDaySummary] = [:]

        for item in items {
            let key = FriendScheduleFormatters.dayKey.string(
                from: FriendScheduleCalendar.calendar.startOfDay(for: item.startDate)
            )
            grouped[key, default: []].append(item)

            var summary = summaries[key] ?? FriendScheduleDaySummary(itemCount: 0, hasExam: false, markerStyles: [])
            summary.itemCount += 1
            summary.hasExam = summary.hasExam || item.isExam
            if !summary.markerStyles.contains(item.markerStyle) {
                summary.markerStyles.append(item.markerStyle)
            }
            summaries[key] = summary
        }

        self.itemsByDayKey = grouped
        self.summaryByDayKey = summaries
    }

    func items(on date: Date) -> [ParsedScheduleItem] {
        itemsByDayKey[dayKey(for: date)] ?? []
    }

    func summary(on date: Date) -> FriendScheduleDaySummary {
        summaryByDayKey[dayKey(for: date)] ?? FriendScheduleDaySummary(itemCount: 0, hasExam: false, markerStyles: [])
    }

    private func dayKey(for date: Date) -> String {
        FriendScheduleFormatters.dayKey.string(from: FriendScheduleCalendar.calendar.startOfDay(for: date))
    }
}

private struct FriendScheduleDaySummary {
    var itemCount: Int
    var hasExam: Bool
    var markerStyles: [FriendScheduleMarkerStyle]
}

private enum FriendScheduleCalendar {
    static let calendar = Calendar.current

    static var shortWeekdaySymbols: [String] {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    }

    static func startOfMonth(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func leadingBlankCount(for monthStart: Date) -> Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday - 2 + 7) % 7
    }
}

private enum FriendScheduleFormatters {
    static let iso = ISO8601DateFormatter()

    static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let generatedAt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let selectedDayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}
