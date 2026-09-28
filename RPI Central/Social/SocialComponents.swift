//
//  SocialComponents.swift
//  RPI Central
//
//  Small building blocks shared by the Social screens.
//

import SwiftUI

// MARK: - Actions

/// Navigation the Social screens hand back to `SocialHubView`, which owns the
/// sheets.
struct SocialActions {
    var openChat: (SocialGroupChatReference) -> Void = { _ in }
    var openProfile: (SocialUser) -> Void = { _ in }
    var openSchedule: (SocialFriend) -> Void = { _ in }
    var openGroupMembers: (SocialFriendGroup) -> Void = { _ in }
    var openClassPage: (SocialCourseCommunity) -> Void = { _ in }
    var addFriends: () -> Void = {}
    var newGroup: () -> Void = {}
    var newPlan: () -> Void = {}
}

private struct SocialActionsKey: EnvironmentKey {
    static let defaultValue = SocialActions()
}

extension EnvironmentValues {
    var socialActions: SocialActions {
        get { self[SocialActionsKey.self] }
        set { self[SocialActionsKey.self] = newValue }
    }
}

// MARK: - Avatars

/// A person's initials on their stable color (the same one the map uses).
struct SocialAvatar: View {
    let id: String
    let name: String
    var size: CGFloat = 44
    var showsLiveDot = false

    var body: some View {
        ZStack {
            Circle().fill(FriendAvatarStyle.color(for: id).gradient)
            Text(FriendAvatarStyle.initials(for: name))
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if showsLiveDot {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A symbol on a tinted circle, for groups and chats that aren't one person.
struct SocialSymbolAvatar: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.16)))
            .accessibilityHidden(true)
    }
}

// MARK: - Info

/// A small ⓘ button that shows an explanation in a popover, so screens can
/// skip paragraphs of helper text.
struct InfoButton: View {
    let text: String
    @State private var isPresented = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More info")
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Status toast

private struct SocialToastModifier: ViewModifier {
    @ObservedObject var socialManager: SocialManager

    private var message: (text: String, isError: Bool)? {
        if let error = socialManager.errorMessage, !error.isEmpty { return (error, true) }
        if let status = socialManager.statusMessage, !status.isEmpty { return (status, false) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Button(action: clear) {
                        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(message.isError ? Color.red : Color.primary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityHint("Dismisses the message")
                }
            }
            .animation(.snappy, value: message?.text)
            .task(id: message?.text) {
                guard let message else { return }
                try? await Task.sleep(for: .seconds(message.isError ? 6 : 3))
                guard !Task.isCancelled else { return }
                clear()
            }
    }

    private func clear() {
        socialManager.errorMessage = nil
        socialManager.statusMessage = nil
    }
}

extension View {
    /// Shows the social manager's status and error messages as a brief toast.
    func socialToast(_ socialManager: SocialManager) -> some View {
        modifier(SocialToastModifier(socialManager: socialManager))
    }

    /// A bar pinned under the navigation bar. On iOS 26 scrolled content fades
    /// beneath it like it does under the navigation bar.
    @ViewBuilder
    func socialTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top) { bar() }
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                bar().background(.bar)
            }
        }
    }
}

// MARK: - Friend activity

/// "In class · Data Structures" / "At Folsom Library" with a status dot.
struct FriendActivityLine: View {
    let friend: SocialFriend
    var showsDetail = false

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var locationManager: LocationSharingManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let schedule = socialManager.cachedFriendSchedule(for: friend)?.schedule
            let presence = FriendPresenceResolver.resolve(
                friend: friend,
                location: locationManager.friendLocations[friend.id],
                schedule: schedule,
                now: context.date
            )

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(dotColor(for: presence))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(presence?.headline ?? idleText(schedule: schedule, now: context.date))
                        .font(.subheadline)
                        .foregroundStyle(presence == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)

                    if showsDetail, let detail = detailText(for: presence, now: context.date) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func dotColor(for presence: FriendPresence?) -> Color {
        switch presence?.freshness {
        case .live?: return .green
        case .stale?: return .orange
        case .scheduled?: return .blue
        case nil: return Color.secondary.opacity(0.45)
        }
    }

    private func idleText(schedule: SharedScheduleSnapshot?, now: Date) -> String {
        if !friend.canViewSchedule { return "Not sharing" }
        if let end = schedule?.coverageEndDate, end < now { return "Schedule out of date" }
        return "Free"
    }

    private func detailText(for presence: FriendPresence?, now: Date) -> String? {
        guard let detail = presence?.detail, !detail.isEmpty else { return nil }
        return detail
    }
}

/// How long ago a friend's shared location updated ("4m"), green while live.
struct FriendUpdatedText: View {
    let friend: SocialFriend

    @EnvironmentObject private var locationManager: LocationSharingManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let location = locationManager.friendLocations[friend.id], location.isVisible(at: context.date) {
                Text(RelativeTimeText.compact(location.updatedAt, now: context.date))
                    .font(.caption)
                    .foregroundStyle(location.isFresh(at: context.date) ? Color.green : Color.secondary)
                    .accessibilityLabel("Location updated \(RelativeTimeText.since(location.updatedAt, now: context.date))")
            }
        }
    }
}

// MARK: - Card

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
