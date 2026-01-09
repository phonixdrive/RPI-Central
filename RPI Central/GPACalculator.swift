//
//  LetterGrade.swift
//  RPI Central
//
//  Created by Neil Shrestha on 1/6/26.
//

import Foundation

enum LetterGrade: String, CaseIterable, Codable, Hashable, Identifiable {
    case aPlus = "A+"
    case a = "A"
    case aMinus = "A-"
    case bPlus = "B+"
    case b = "B"
    case bMinus = "B-"
    case cPlus = "C+"
    case c = "C"
    case cMinus = "C-"
    case dPlus = "D+"
    case d = "D"
    case dMinus = "D-"
    case f = "F"

    // Common non-GPA grades (exclude from GPA by default)
    case p = "P"
    case nc = "NC"
    case s = "S"
    case u = "U"
    case w = "W"
    case i = "I"

    var id: String { rawValue }

    var isGPAEligible: Bool {
        switch self {
        case .p, .nc, .s, .u, .w, .i:
            return false
        default:
            return true
        }
    }

    /// 4.0 scale (A+ treated as 4.0 here; adjust if you want).
    var gpaPoints: Double? {
        guard isGPAEligible else { return nil }
        switch self {
        case .aPlus: return 4.0
        case .a: return 4.0
        case .aMinus: return 3.7
        case .bPlus: return 3.3
        case .b: return 3.0
        case .bMinus: return 2.7
        case .cPlus: return 2.3
        case .c: return 2.0
        case .cMinus: return 1.7
        case .dPlus: return 1.3
        case .d: return 1.0
        case .dMinus: return 0.7
        case .f: return 0.0
        default: return nil
        }
    }

    static var gpaPickerGrades: [LetterGrade] {
        // Show GPA grades first, then the non-GPA ones.
        let eligible = Self.allCases.filter { $0.isGPAEligible }
        let non = Self.allCases.filter { !$0.isGPAEligible }
        return eligible + non
    }
}
