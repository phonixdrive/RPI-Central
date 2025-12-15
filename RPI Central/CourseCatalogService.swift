//
//  CourseCatalogService.swift
//  RPI Central
//

import Foundation

@MainActor
final class CourseCatalogService: ObservableObject {
    static let shared = CourseCatalogService()

    @Published private(set) var courses: [Course] = []
    @Published var semester: Semester = .spring2025 {
        didSet { loadCourses(for: semester) }
    }

    private init() {
        loadCourses(for: semester)
    }

    // MARK: - Public loader

    private func loadCourses(for semester: Semester) {
        let term = semester.rawValue
        Task.detached(priority: .userInitiated) { [term] in
            do {
                let built = try QuACSLoader.buildCourses(termCode: term)
                await MainActor.run {
                    self.courses = built
                }
            } catch {
                print("❌ QuACS load failed:", error)
                await MainActor.run { self.courses = [] }
            }
        }
    }
}

// MARK: - QuACS Loader

private enum QuACSLoader {

    // ---- File layout in bundle (FOLDER REFERENCE REQUIRED) ----
    //
    // semester_data/
    //   202501/
    //     courses.json
    //     catalog.json
    //     prerequisites.json
    //
    static func buildCourses(termCode: String) throws -> [Course] {
        let subdir = "semester_data/\(termCode)"

        let coursesBySubject: [QuACSCoursesSubject] = try loadJSON(
            "courses",
            subdirectory: subdir
        )

        let catalog: [String: QuACSCatalogItem] = try loadJSON(
            "catalog",
            subdirectory: subdir
        )

        let prereqsByCRN: [String: QuACSPrereqEntry] = (try? loadJSON(
            "prerequisites",
            subdirectory: subdir
        )) ?? [:]

        // Flatten QuACS structure into your app's [Course]
        var result: [Course] = []
        result.reserveCapacity(5000)

        for subjectBlock in coursesBySubject {
            for c in subjectBlock.courses {
                let courseKey = "\(c.subj)-\(String(c.crse))"
                let cat = catalog[courseKey]

                let title = cat?.name ?? c.title ?? "\(c.subj) \(c.crse)"
                let desc = cat?.description ?? ""

                // Build sections
                let sections: [CourseSection] = c.sections.map { sec in
                    let meetings = buildMeetings(from: sec.timeslots)
                    let instructor = buildInstructor(from: sec.timeslots)

                    let prereqText: String = {
                        guard let crn = sec.crn else { return "" }
                        let entry = prereqsByCRN[String(crn)]
                        return entry?.prerequisites?.toHumanString() ?? ""
                    }()

                    return CourseSection(
                        crn: sec.crn,
                        section: sec.sec,
                        instructor: instructor,
                        meetings: meetings,
                        prerequisitesText: prereqText
                    )
                }

                let appCourse = Course(
                    subject: c.subj,
                    number: String(c.crse),
                    title: title,
                    description: desc,
                    sections: sections
                )
                result.append(appCourse)
            }
        }

        // Sort like before
        result.sort { ($0.subject, $0.number) < ($1.subject, $1.number) }
        return result
    }

    // MARK: - Decode helpers

    private static func loadJSON<T: Decodable>(_ name: String, subdirectory: String) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: subdirectory) else {
            throw NSError(
                domain: "QuACSLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(name).json in bundle at \(subdirectory)"]
            )
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Transform helpers

    private static func buildInstructor(from timeslots: [QuACSTimeslot]) -> String {
        let names = timeslots
            .map { $0.instructor.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.uppercased() != "TBA" }

        // unique but stable order
        var seen = Set<String>()
        var uniq: [String] = []
        for n in names {
            if !seen.contains(n) {
                seen.insert(n)
                uniq.append(n)
            }
        }
        return uniq.joined(separator: ", ")
    }

    private static func buildMeetings(from timeslots: [QuACSTimeslot]) -> [Meeting] {
        var meetings: [Meeting] = []

        for t in timeslots {
            // ignore TBA
            guard t.timeStart >= 0, t.timeEnd >= 0 else { continue }
            guard !t.days.isEmpty else { continue }

            let days: [Weekday] = t.days.compactMap { Weekday(rawValue: $0) }
            guard !days.isEmpty else { continue }

            guard
                let start = timeIntToHHMM(t.timeStart),
                let end = timeIntToHHMM(t.timeEnd)
            else { continue }

            meetings.append(
                Meeting(
                    days: days,
                    start: start,
                    end: end,
                    location: t.location
                )
            )
        }

        return meetings
    }

    private static func timeIntToHHMM(_ v: Int) -> String? {
        if v < 0 { return nil }
        let hour = v / 100
        let minute = v % 100
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }
}

// MARK: - QuACS JSON Shapes

private struct QuACSCoursesSubject: Decodable {
    let code: String
    let courses: [QuACSCourse]
}

private struct QuACSCourse: Decodable {
    let crse: Int
    let id: String
    let subj: String
    let title: String?
    let sections: [QuACSSection]
}

private struct QuACSSection: Decodable {
    let crn: Int?
    let sec: String
    let subj: String
    let crse: Int
    let title: String?
    let timeslots: [QuACSTimeslot]
}

private struct QuACSTimeslot: Decodable {
    let dateEnd: String?
    let dateStart: String?
    let days: [String]
    let instructor: String
    let location: String
    let timeEnd: Int
    let timeStart: Int
}

private struct QuACSCatalogItem: Decodable {
    let subj: String
    let crse: String
    let name: String
    let description: String
    let source: String
}

// prereqs.json is keyed by CRN string
private struct QuACSPrereqEntry: Decodable {
    let cross_list_courses: [String]?
    let prerequisites: QuACSPrereqNode?
}

// Recursive prereq node:
// { "type":"course", "course":"MATH 2010", "min_grade":"D" }
// { "type":"and", "nested":[ ... ] }
// { "type":"or",  "nested":[ ... ] }
private indirect enum QuACSPrereqNode: Decodable {
    case course(course: String, minGrade: String?)
    case and([QuACSPrereqNode])
    case or([QuACSPrereqNode])

    private enum Keys: String, CodingKey {
        case type
        case course
        case min_grade
        case nested
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""

        switch type {
        case "course":
            let course = (try? c.decode(String.self, forKey: .course)) ?? ""
            let mg = try? c.decode(String.self, forKey: .min_grade)
            self = .course(course: course, minGrade: mg)

        case "and":
            let nested = (try? c.decode([QuACSPrereqNode].self, forKey: .nested)) ?? []
            self = .and(nested)

        case "or":
            let nested = (try? c.decode([QuACSPrereqNode].self, forKey: .nested)) ?? []
            self = .or(nested)

        default:
            // unknown type -> treat as empty AND
            self = .and([])
        }
    }

    func toHumanString() -> String {
        switch self {
        case .course(let c, let mg):
            if let mg, !mg.isEmpty { return "\(c) (min \(mg))" }
            return c

        case .and(let nodes):
            let parts = nodes.map { $0.toHumanString() }.filter { !$0.isEmpty }
            if parts.isEmpty { return "" }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " AND ") + ")"

        case .or(let nodes):
            let parts = nodes.map { $0.toHumanString() }.filter { !$0.isEmpty }
            if parts.isEmpty { return "" }
            return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")"
        }
    }
}
