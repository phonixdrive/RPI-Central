// AcademicCalendarService.swift

import Foundation

/// Stub for AI integration.
/// Later you can plug Gemini in here to parse:
/// https://registrar.rpi.edu/academic-calendar?academic_year=25
final class AcademicCalendarService {

    static let shared = AcademicCalendarService()
    private init() {}

    func fetchEventsForCurrentYear(completion: @escaping (Result<[AcademicEvent], Error>) -> Void) {
        // TODO: Implement Gemini / HTTP fetch here.
        // For now, return empty so the app still builds and runs.
        completion(.success([]))
    }
}
