// Semester.swift

import Foundation

/// Matches your JSON file names like `rpi_courses_202501.json`
enum Semester: String, CaseIterable, Identifiable, Codable {
    // Adjust these to match the JSONs you actually ship
    case spring2025 = "202501"
    case fall2025   = "202509"
    case spring2026 = "202601"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spring2025: return "Spring 2025"
        case .fall2025:   return "Fall 2025"
        case .spring2026: return "Spring 2026"
        }
    }

    /// The JSON file in your bundle, e.g. "rpi_courses_202501"
    var jsonFileName: String {
        "rpi_courses_\(rawValue)"
    }
}
