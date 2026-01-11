//
// MeetingBlockType.swift
// RPI Central
//

import Foundation

enum MeetingBlockType: String, CaseIterable, Identifiable, Codable {
    case lecture
    case recitation
    case lab
    case studio
    case exam
    case disabled
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lecture:    return "Lecture"
        case .recitation: return "Recitation"
        case .lab:        return "Lab"
        case .studio:     return "Studio"
        case .exam:       return "Exam"
        case .disabled:   return "Disabled"
        case .other:      return "Other"
        }
    }
}
