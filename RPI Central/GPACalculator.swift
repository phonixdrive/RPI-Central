//
//  GPACalculator.swift
//  RPI Central
//

import Foundation

/// Standard 4.0 GPA scale with +/-.
enum LetterGrade: String, CaseIterable, Identifiable, Codable {
    case aPlus  = "A+"
    case a      = "A"
    case aMinus = "A-"
    case bPlus  = "B+"
    case b      = "B"
    case bMinus = "B-"
    case cPlus  = "C+"
    case c      = "C"
    case cMinus = "C-"
    case d      = "D"
    case f      = "F"

    var id: String { rawValue }

    /// Grade points on a 4.0 scale.
    var points: Double {
        switch self {
        case .aPlus:  return 4.00
        case .a:      return 4.00
        case .aMinus: return 3.67
        case .bPlus:  return 3.33
        case .b:      return 3.00
        case .bMinus: return 2.67
        case .cPlus:  return 2.33
        case .c:      return 2.00
        case .cMinus: return 1.67
        case .d:      return 1.00
        case .f:      return 0.00
        }
    }

    /// Display ordering (A+ ... F)
    static var ordered: [LetterGrade] { Self.allCases }
}

enum GPACalculator {

    static func weightedGPA(_ entries: [(grade: LetterGrade, credits: Double)]) -> Double? {
        guard !entries.isEmpty else { return nil }

        var totalPoints = 0.0
        var totalCredits = 0.0

        for e in entries {
            totalPoints += e.grade.points * e.credits
            totalCredits += e.credits
        }

        guard totalCredits > 0 else { return nil }
        return totalPoints / totalCredits
    }

    static func format(_ gpa: Double?) -> String {
        guard let gpa else { return "—" }
        return String(format: "%.2f", gpa)
    }
}
