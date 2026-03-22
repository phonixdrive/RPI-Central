import Foundation

struct SocialUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let email: String
    let isGuest: Bool
    let shareSchedule: Bool
    let shareLocation: Bool
    let createdAt: String
    let lastScheduleAt: String?
}

struct SocialAuthResponse: Codable {
    let token: String
    let user: SocialUser
}

struct SocialOverviewResponse: Codable {
    let viewer: SocialUser
    let friends: [SocialFriend]
    let incomingRequests: [SocialFriendRequest]
    let outgoingRequests: [SocialFriendRequest]
}

struct SocialFriend: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let email: String
    let isGuest: Bool
    let shareSchedule: Bool
    let shareLocation: Bool
    let createdAt: String
    let lastScheduleAt: String?
    let canViewSchedule: Bool
    let schedulePreviewCount: Int
}

struct SocialFriendRequest: Codable, Identifiable, Equatable {
    let id: String
    let status: String
    let createdAt: String
    let respondedAt: String?
    let fromUser: SocialUser?
    let toUser: SocialUser?
}

struct SocialSearchResponse: Codable {
    let results: [SocialSearchResult]
}

struct SocialSearchResult: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let email: String
    let isGuest: Bool
    let shareSchedule: Bool
    let shareLocation: Bool
    let createdAt: String
    let lastScheduleAt: String?
    let areFriends: Bool
    let hasPendingIncoming: Bool
    let hasPendingOutgoing: Bool
}

struct SocialFriendGroup: Codable, Identifiable, Equatable {
    let id: String
    let ownerID: String
    let name: String
    let createdAt: String
    let memberIDs: [String]
}

enum SocialFeedVisibility: String, Codable, CaseIterable, Identifiable {
    case friends
    case everyone
    case groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friends: return "Friends"
        case .everyone: return "Everybody"
        case .groups: return "Specific groups"
        }
    }
}

enum SocialFeedPresenceStatus: String, Codable, Identifiable {
    case going
    case here
    case notGoing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .going: return "Going"
        case .here: return "Here"
        case .notGoing: return "Not going"
        }
    }
}

struct SocialFeedPost: Codable, Identifiable, Equatable {
    let id: String
    let ownerID: String
    let ownerUsername: String
    let ownerDisplayName: String
    let title: String
    let location: String
    let details: String
    let createdAt: String
    let startsAt: String
    let endedAt: String?
    let visibility: SocialFeedVisibility
    let visibleGroupIDs: [String]
}

struct SocialFeedPresence: Codable, Identifiable, Equatable {
    let postID: String
    let userID: String
    let username: String
    let displayName: String
    let status: SocialFeedPresenceStatus
    let respondedAt: String

    var id: String {
        "\(postID)|\(userID)"
    }
}

struct SocialFeedItem: Identifiable, Equatable {
    let post: SocialFeedPost
    let responses: [SocialFeedPresence]

    var id: String { post.id }
}

struct SocialRequestEnvelope: Codable {
    let request: SocialFriendRequest
}

struct SocialUserEnvelope: Codable {
    let user: SocialUser
}

struct SocialOKResponse: Codable {
    let ok: Bool
}

struct SharedScheduleSnapshot: Codable, Equatable {
    let semesterCode: String
    let generatedAt: String?
    let items: [SharedScheduleItem]
}

struct SharedScheduleItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let location: String
    let startDate: String
    let endDate: String
    let isAllDay: Bool
    let kind: String
    let badge: String?
}

struct FriendScheduleResponse: Codable, Identifiable {
    let owner: SocialUser
    let schedule: SharedScheduleSnapshot

    var id: String {
        "\(owner.id)|\(schedule.generatedAt ?? "none")"
    }
}
