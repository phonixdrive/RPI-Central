import SwiftUI

struct SocialHubView: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @EnvironmentObject var socialManager: SocialManager

    @State private var authMode: AuthMode = .login
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var profileDisplayName: String = ""
    @State private var searchQuery: String = ""
    @State private var selectedFriendSchedule: FriendScheduleResponse?
    @FocusState private var searchFieldFocused: Bool

    private var friendCount: Int { socialManager.overview?.friends.count ?? 0 }
    private var incomingCount: Int { socialManager.overview?.incomingRequests.count ?? 0 }

    var body: some View {
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
                    VStack(spacing: 16) {
                        heroCard
                        setupCard

                        if socialManager.isFirebaseAvailable && socialManager.isAuthenticated {
                            profileCard
                            sharingCard
                            if calendarViewModel.socialDemoToolsEnabled {
                                demoCard
                            }
                            findFriendsCard
                            requestsCard
                            friendsCard
                        } else if socialManager.isFirebaseAvailable {
                            authCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .navigationTitle("Social")
            .toolbar {
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
            .refreshable {
                guard socialManager.isAuthenticated else { return }
                await socialManager.refreshOverview()
            }
            .sheet(item: $selectedFriendSchedule) { schedule in
                FriendScheduleView(response: schedule)
            }
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
            .onChange(of: calendarViewModel.currentSemester) {
                Task { await syncSharedScheduleIfNeeded() }
            }
            .onChange(of: calendarViewModel.events.count) {
                Task { await syncSharedScheduleIfNeeded() }
            }
            .onChange(of: calendarViewModel.enrolledCourses.count) {
                Task { await syncSharedScheduleIfNeeded() }
            }
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

    private var findFriendsCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Find Friends", systemImage: "magnifyingglass")
                    .font(.headline)

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
                    VStack(spacing: 10) {
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
                Label("Friends", systemImage: "person.2.fill")
                    .font(.headline)

                if let friends = socialManager.overview?.friends, !friends.isEmpty {
                    VStack(spacing: 10) {
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
                            await socialManager.sendFriendRequest(to: result.username)
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
        VStack(alignment: .leading, spacing: 10) {
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

            HStack {
                Text("\(friend.schedulePreviewCount) shared items")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

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
                }
            }

            Button("Remove friend", role: .destructive) {
                Task {
                    await socialManager.unfriend(friend.id)
                }
            }
            .font(.caption)
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

    private func messageBanner(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
    }

    private func syncSharedScheduleIfNeeded() async {
        guard socialManager.isAuthenticated,
              socialManager.currentUser?.shareSchedule == true else { return }
        await socialManager.syncSchedule(from: calendarViewModel)
    }

    private func syncProfileDisplayName() {
        profileDisplayName = socialManager.currentUser?.displayName ?? ""
    }
}

private struct SocialCard<Content: View>: View {
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
        self.anchorDate = items.first?.startDate ?? Date()
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
        let hasAcademicDay = summary.markerStyles.contains(.academic)

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
                } else if hasAcademicDay {
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
    case academic
    case personal

    init(kind: String) {
        switch kind {
        case "classMeeting":
            self = .classMeeting
        case "assignment":
            self = .assignment
        case "academic":
            self = .academic
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
        case .academic:
            return .orange
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
        case .academic:
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
