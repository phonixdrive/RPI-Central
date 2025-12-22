// AcademicCalendarService.swift
// RPI Central

import Foundation

final class AcademicCalendarService {
    static let shared = AcademicCalendarService()
    private init() {}

    // RPI is in NY; use a stable timezone so "YYYY-MM-DD" never shifts a day.
    private let rpiTimeZone = TimeZone(identifier: "America/New_York") ?? .current

    private lazy var ymdFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = rpiTimeZone
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    func loadBundledCalendar(named filenameWithoutExtension: String) throws -> AcademicCalendar {
        guard let url = Bundle.main.url(forResource: filenameWithoutExtension, withExtension: "json") else {
            throw NSError(domain: "AcademicCalendarService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing \(filenameWithoutExtension).json in bundle"
            ])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AcademicCalendar.self, from: data)
    }

    func parseYMD(_ s: String) -> Date? {
        ymdFormatter.date(from: s)
    }

    // MARK: - Backwards compatible (your old call site)

    /// Loads academic calendar events from a bundled JSON and returns them as `[AcademicEvent]`.
    /// (Kept so your older CalendarViewModel / CalendarView doesn't break.)
    func fetchEventsForCurrentYear(
        completion: @escaping (Result<[AcademicEvent], Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let now = Date()
                let year = Calendar.current.component(.year, from: now)
                let y2 = year % 100

                let candidates = [
                    "academic_calendar",
                    "rpi_academic_calendar",
                    "academic_calendar_\(year)",
                    "academic_calendar_\(y2)",
                    "rpi_academic_calendar_\(year)",
                    "rpi_academic_calendar_\(y2)"
                ]

                let filename: String? = candidates.first { name in
                    Bundle.main.url(forResource: name, withExtension: "json") != nil
                }

                guard let filename else {
                    throw NSError(
                        domain: "AcademicCalendarService",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "No bundled academic calendar JSON found. Tried: \(candidates.joined(separator: ", "))"
                        ]
                    )
                }

                let calendar = try self.loadBundledCalendar(named: filename)

                var out: [AcademicEvent] = []
                out.reserveCapacity(calendar.events.count)

                for e in calendar.events {
                    guard let start = self.parseYMD(e.startDate) else { continue }
                    let end = self.parseYMD(e.endDate ?? e.startDate) ?? start
                    let kind = self.kindFromTags(e.tags)

                    out.append(
                        AcademicEvent(
                            title: e.title,
                            startDate: start,
                            endDate: end,
                            location: nil,
                            kind: kind
                        )
                    )
                }

                completion(.success(out))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - New helpers (term-bounded semesters)

    /// Returns the start/end dates when classes run for the requested semester, if we can find that academic year JSON.
    func fetchTermBounds(
        for semester: Semester,
        completion: @escaping (Result<(start: Date, end: Date), Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let yearToken = self.academicYearStart(for: semester)
                let calendar = try self.loadCalendarForAcademicYearStart(yearToken)

                let term: Term = semester.isFall ? calendar.terms.fall : calendar.terms.spring
                guard
                    let beginStr = term.classesBegin,
                    let endStr = term.classesEnd,
                    let begin = self.parseYMD(beginStr),
                    let end = self.parseYMD(endStr)
                else {
                    throw NSError(
                        domain: "AcademicCalendarService",
                        code: 20,
                        userInfo: [NSLocalizedDescriptionKey: "Missing classesBegin/classesEnd for \(semester.displayName) in academic calendar"]
                    )
                }

                completion(.success((start: begin, end: end)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Loads academic events from the academic year that contains the semester.
    func fetchEvents(
        for semester: Semester,
        completion: @escaping (Result<[AcademicEvent], Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let yearToken = self.academicYearStart(for: semester)
                let calendar = try self.loadCalendarForAcademicYearStart(yearToken)

                var out: [AcademicEvent] = []
                out.reserveCapacity(calendar.events.count)

                for e in calendar.events {
                    guard let start = self.parseYMD(e.startDate) else { continue }
                    let end = self.parseYMD(e.endDate ?? e.startDate) ?? start
                    let kind = self.kindFromTags(e.tags)

                    out.append(
                        AcademicEvent(
                            title: e.title,
                            startDate: start,
                            endDate: end,
                            location: nil,
                            kind: kind
                        )
                    )
                }

                completion(.success(out))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Internals

    /// Academic year token:
    /// - Fall 2025 is in AY 2025–2026 => 2025
    /// - Spring 2026 is in AY 2025–2026 => 2025
    /// - Spring 2025 is in AY 2024–2025 => 2024
    private func academicYearStart(for semester: Semester) -> Int {
        let year = semester.year
        return semester.isFall ? year : (year - 1)
    }

    private func loadCalendarForAcademicYearStart(_ yearToken: Int) throws -> AcademicCalendar {
        let y2 = yearToken % 100

        let candidates = [
            "academic_calendar_\(yearToken)",
            "rpi_academic_calendar_\(yearToken)",
            "academic_calendar_\(y2)",
            "rpi_academic_calendar_\(y2)",
            "academic_calendar",
            "rpi_academic_calendar"
        ]

        let filename: String? = candidates.first { name in
            Bundle.main.url(forResource: name, withExtension: "json") != nil
        }

        guard let filename else {
            throw NSError(
                domain: "AcademicCalendarService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "No bundled academic calendar JSON found for academic year \(yearToken). Tried: \(candidates.joined(separator: ", "))"
                ]
            )
        }

        return try loadBundledCalendar(named: filename)
    }

    private func kindFromTags(_ tags: AcademicTags) -> CalendarEventKind {
        if tags.break { return .break }
        if tags.holiday { return .holiday }
        if tags.finals { return .finals }
        if tags.readingDays { return .readingDays }
        if tags.noClasses { return .noClasses }
        if tags.followDay { return .followDay }
        return .academicOther
    }

    /// Expands multi-day events into per-day items (optional helper).
    /// (Kept because you had it in the working version; now also includes AcademicDayEvent so it compiles.)
    func expandToPerDayEvents(_ calendar: AcademicCalendar) -> [AcademicDayEvent] {
        var out: [AcademicDayEvent] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = rpiTimeZone

        for e in calendar.events {
            guard let start = parseYMD(e.startDate) else { continue }
            let end = parseYMD(e.endDate ?? e.startDate) ?? start

            let startLocal = cal.startOfDay(for: start)
            let endLocal = cal.startOfDay(for: end)

            if startLocal <= endLocal {
                var cur = startLocal
                while cur <= endLocal {
                    out.append(AcademicDayEvent(date: cur, raw: e))
                    guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
                    cur = next
                }
            }
        }

        return out
    }
}

struct AcademicDayEvent: Identifiable {
    var id: String { "\(raw.id)|\(date.timeIntervalSince1970)" }
    let date: Date
    let raw: AcademicCalendarEvent
}

// MARK: - Semester helpers (file-local)

private extension Semester {
    var year: Int { Int(rawValue.prefix(4)) ?? Calendar.current.component(.year, from: Date()) }
    var month: Int { Int(rawValue.suffix(2)) ?? 1 }
    var isFall: Bool { month == 9 }
    var isSpring: Bool { month == 1 }
}
