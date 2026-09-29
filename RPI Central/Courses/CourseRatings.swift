//
//  CourseRatings.swift
//  RPI Central
//
//  Students rate a course (overall, difficulty, weekly hours, and a few
//  preset tags). Ratings are stored per course in Firestore, one document per
//  student, so everyone sees the averages. There is no free text, which keeps
//  moderation out of it.
//

import Foundation
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
#endif

enum CourseRatingTag: String, CaseIterable, Identifiable, Codable {
    case greatLectures
    case clearGrading
    case heavyWorkload
    case toughExams
    case attendanceMatters
    case groupProjects
    case curve
    case helpfulTAs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .greatLectures: return "Great lectures"
        case .clearGrading: return "Clear grading"
        case .heavyWorkload: return "Heavy workload"
        case .toughExams: return "Tough exams"
        case .attendanceMatters: return "Attendance matters"
        case .groupProjects: return "Group projects"
        case .curve: return "Curved"
        case .helpfulTAs: return "Helpful TAs"
        }
    }
}

struct CourseRating: Equatable, Codable {
    /// 1–5
    var overall: Int
    /// 1 (easy) – 5 (hard)
    var difficulty: Int
    /// Typical hours per week outside class.
    var hoursPerWeek: Int
    var tags: [CourseRatingTag]
    var semesterCode: String

    static let maximumTags = 4

    var isValid: Bool {
        (1...5).contains(overall) && (1...5).contains(difficulty) &&
            (0...40).contains(hoursPerWeek) && tags.count <= Self.maximumTags
    }
}

struct CourseRatingSummary: Equatable {
    var count: Int
    var overall: Double
    var difficulty: Double
    var hoursPerWeek: Double
    /// Tags picked by at least one student, most common first.
    var topTags: [(tag: CourseRatingTag, count: Int)]

    static func == (lhs: CourseRatingSummary, rhs: CourseRatingSummary) -> Bool {
        lhs.count == rhs.count && lhs.overall == rhs.overall && lhs.difficulty == rhs.difficulty &&
            lhs.hoursPerWeek == rhs.hoursPerWeek && lhs.topTags.map(\.tag) == rhs.topTags.map(\.tag)
    }

    static func summarize(_ ratings: [CourseRating]) -> CourseRatingSummary? {
        let valid = ratings.filter(\.isValid)
        guard !valid.isEmpty else { return nil }
        let count = Double(valid.count)
        var tagCounts: [CourseRatingTag: Int] = [:]
        for rating in valid {
            for tag in Set(rating.tags) { tagCounts[tag, default: 0] += 1 }
        }
        let topTags = tagCounts
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { (tag: $0.key, count: $0.value) }
        return CourseRatingSummary(
            count: valid.count,
            overall: Double(valid.map(\.overall).reduce(0, +)) / count,
            difficulty: Double(valid.map(\.difficulty).reduce(0, +)) / count,
            hoursPerWeek: Double(valid.map(\.hoursPerWeek).reduce(0, +)) / count,
            topTags: topTags
        )
    }
}

@MainActor
final class CourseRatingsModel: ObservableObject {
    @Published private(set) var summary: CourseRatingSummary?
    @Published private(set) var myRating: CourseRating?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// "CSCI-1200": ratings cover the course across sections and terms.
    let courseKey: String

    init(subject: String, number: String) {
        courseKey = "\(subject.uppercased())-\(number)"
    }

    func load() async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard Auth.auth().currentUser != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await ratingsCollection.limit(to: 500).getDocuments()
            let ratings = snapshot.documents.compactMap { Self.rating(from: $0.data()) }
            summary = CourseRatingSummary.summarize(ratings)
            if let uid = Auth.auth().currentUser?.uid,
               let mine = snapshot.documents.first(where: { $0.documentID == uid }) {
                myRating = Self.rating(from: mine.data())
            }
        } catch {
            errorMessage = "Couldn’t load ratings."
        }
#endif
    }

    func save(_ rating: CourseRating) async -> Bool {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard rating.isValid, let uid = Auth.auth().currentUser?.uid else { return false }
        do {
            try await ratingsCollection.document(uid).setData([
                "overall": rating.overall,
                "difficulty": rating.difficulty,
                "hoursPerWeek": rating.hoursPerWeek,
                "tags": rating.tags.map(\.rawValue),
                "semesterCode": rating.semesterCode,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            myRating = rating
            await load()
            return true
        } catch {
            errorMessage = "Couldn’t save your rating."
            return false
        }
#else
        return false
#endif
    }

    func deleteMyRating() async {
#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try? await ratingsCollection.document(uid).delete()
        myRating = nil
        await load()
#endif
    }

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private var ratingsCollection: CollectionReference {
        Firestore.firestore().collection("courseRatings").document(courseKey).collection("ratings")
    }
#endif

    static func rating(from data: [String: Any]) -> CourseRating? {
        guard let overall = (data["overall"] as? NSNumber)?.intValue,
              let difficulty = (data["difficulty"] as? NSNumber)?.intValue else { return nil }
        let rating = CourseRating(
            overall: overall,
            difficulty: difficulty,
            hoursPerWeek: (data["hoursPerWeek"] as? NSNumber)?.intValue ?? 0,
            tags: (data["tags"] as? [String] ?? []).compactMap(CourseRatingTag.init(rawValue:)),
            semesterCode: data["semesterCode"] as? String ?? ""
        )
        return rating.isValid ? rating : nil
    }
}
