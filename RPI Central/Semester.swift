//Semester.swift
import Foundation

/// Matches your JSON folder names like `semester_data/202501/courses.json`
enum Semester: String, CaseIterable, Identifiable, Codable {
    // Current 3 (per your request)
    case fall2025   = "202509" // current term
    case spring2025 = "202501" // previous term
    case spring2026 = "202601" // next term

    // Last 3 years (4 years total including 2025): Spring/Fall
    case fall2024   = "202409"
    case spring2024 = "202401"

    case fall2023   = "202309"
    case spring2023 = "202301"

    case fall2022   = "202209"
    case spring2022 = "202201"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fall2025:   return "Fall 2025 (current term)"
        case .spring2025: return "Spring 2025 (previous term)"
        case .spring2026: return "Spring 2026 (next term)"

        case .fall2024:   return "Fall 2024"
        case .spring2024: return "Spring 2024"

        case .fall2023:   return "Fall 2023"
        case .spring2023: return "Spring 2023"

        case .fall2022:   return "Fall 2022"
        case .spring2022: return "Spring 2022"
        }
    }

    /// The JSON file in your bundle, e.g. "rpi_courses_202501" (if you still use that elsewhere)
    var jsonFileName: String {
        "rpi_courses_\(rawValue)"
    }
}
