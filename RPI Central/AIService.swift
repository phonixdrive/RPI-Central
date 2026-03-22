// AIService.swift

import Foundation

struct ProfessorAISummary: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let summary: String
    let sentiment: String
    let ratingText: String
    let rateMyProfessorScore: String
    let rateMyProfessorDifficulty: String
    let rateMyProfessorWouldTakeAgain: String
    let rateMyProfessorRatingCount: String
    let rateMyProfessorSummary: String

    init(
        name: String,
        summary: String,
        sentiment: String,
        ratingText: String,
        rateMyProfessorScore: String,
        rateMyProfessorDifficulty: String,
        rateMyProfessorWouldTakeAgain: String,
        rateMyProfessorRatingCount: String,
        rateMyProfessorSummary: String
    ) {
        self.name = name
        self.summary = summary
        self.sentiment = sentiment
        self.ratingText = ratingText
        self.rateMyProfessorScore = rateMyProfessorScore
        self.rateMyProfessorDifficulty = rateMyProfessorDifficulty
        self.rateMyProfessorWouldTakeAgain = rateMyProfessorWouldTakeAgain
        self.rateMyProfessorRatingCount = rateMyProfessorRatingCount
        self.rateMyProfessorSummary = rateMyProfessorSummary
    }

    enum CodingKeys: String, CodingKey {
        case name
        case summary
        case sentiment
        case ratingText
        case rateMyProfessorScore
        case rateMyProfessorDifficulty
        case rateMyProfessorWouldTakeAgain
        case rateMyProfessorRatingCount
        case rateMyProfessorSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown Professor"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? "Not enough public information to summarize yet."
        sentiment = try container.decodeIfPresent(String.self, forKey: .sentiment) ?? "mixed"
        ratingText = try container.decodeIfPresent(String.self, forKey: .ratingText) ?? "Not enough public data"
        rateMyProfessorScore = try container.decodeIfPresent(String.self, forKey: .rateMyProfessorScore) ?? "Not enough public data"
        rateMyProfessorDifficulty = try container.decodeIfPresent(String.self, forKey: .rateMyProfessorDifficulty) ?? "Unavailable"
        rateMyProfessorWouldTakeAgain = try container.decodeIfPresent(String.self, forKey: .rateMyProfessorWouldTakeAgain) ?? "Unavailable"
        rateMyProfessorRatingCount = try container.decodeIfPresent(String.self, forKey: .rateMyProfessorRatingCount) ?? "Unavailable"
        rateMyProfessorSummary = try container.decodeIfPresent(String.self, forKey: .rateMyProfessorSummary) ?? ""
    }
}

struct CourseAISummary: Codable, Equatable {
    let courseID: String
    let professorSignature: String
    let headline: String
    let overallDifficulty: String
    let recommendation: String
    let professors: [ProfessorAISummary]
    let sourcesNote: String
    let generatedAt: Date
}

enum CourseAISummaryStore {
    private static let keyPrefix = "course_ai_summary_v3."

    static func load(courseID: String) -> CourseAISummary? {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + courseID),
              let summary = try? JSONDecoder().decode(CourseAISummary.self, from: data) else {
            return nil
        }
        return summary
    }

    static func save(_ summary: CourseAISummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + summary.courseID)
    }
}

struct GeminiEventExtractor {
    static func fetchAcademicEvents(
        apiKey: String,
        completion: @escaping (Result<[AcademicEvent], Error>) -> Void
    ) {
        let calendarURL = URL(string: "https://registrar.rpi.edu/academic-calendar?academic_year=25")!

        URLSession.shared.dataTask(with: calendarURL) { data, _, error in
            if let error = error { return completion(.failure(error)) }
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                return completion(.failure(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad HTML"])))
            }

            sendToGemini(html: html, apiKey: apiKey, completion: completion)
        }.resume()
    }

    private static func sendToGemini(
        html: String,
        apiKey: String,
        completion: @escaping (Result<[AcademicEvent], Error>) -> Void
    ) {
        // Ask Gemini to output STRICT JSON
        let prompt = """
        You are given the RPI academic calendar as HTML text.

        Extract all significant events (first day of classes, breaks, holidays, exam periods, etc.)
        and output ONLY a JSON array.

        Each element:
        {
          "title": "string",
          "startDate": "YYYY-MM-DD",
          "endDate": "YYYY-MM-DD",
          "location": "optional string or null"
        }

        HTML:
        \(html)
        """

        struct GeminiRequest: Encodable {
            struct Content: Encodable {
                struct Part: Encodable { let text: String }
                let parts: [Part]
            }
            let contents: [Content]
        }

        let body = GeminiRequest(contents: [.init(parts: [.init(text: prompt)])])

        var req = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)")!
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error = error { return completion(.failure(error)) }
            guard let data = data else {
                return completion(.failure(NSError(domain: "AI", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data"])))
            }

            // Very dumb extraction: assume Gemini put the JSON into the first candidate text
            struct GeminiResponse: Decodable {
                struct Candidate: Decodable {
                    struct Content: Decodable {
                        struct Part: Decodable { let text: String? }
                        let parts: [Part]
                    }
                    let content: Content
                }
                let candidates: [Candidate]
            }

            do {
                let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
                guard
                    let jsonText = decoded.candidates.first?.content.parts.first?.text,
                    let jsonData = jsonText.data(using: .utf8)
                else {
                    throw NSError(domain: "AI", code: -3, userInfo: [NSLocalizedDescriptionKey: "No JSON from Gemini"])
                }

                let eventDTOs = try JSONDecoder().decode([AcademicEventDTO].self, from: jsonData)
                let df = ISO8601DateFormatter()
                df.formatOptions = [.withFullDate]

                let events: [AcademicEvent] = eventDTOs.compactMap { dto in
                    guard let s = df.date(from: dto.startDate),
                          let e = df.date(from: dto.endDate) else { return nil }
                    return AcademicEvent(title: dto.title, startDate: s, endDate: e, location: dto.location)
                }
                completion(.success(events))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // Helper DTO to decode Gemini's JSON
    private struct AcademicEventDTO: Decodable {
        let title: String
        let startDate: String
        let endDate: String
        let location: String?
    }
}

enum GeminiCourseAdvisor {
    private static let apiKey = "AIzaSyAaHnO7UrxxIpy0Q11IA1CSqp8VxlQqBPQ"
    private static let modelID = "gemini-2.5-flash"

    static func fetchSummary(
        course: Course,
        professorNames: [String]
    ) async throws -> CourseAISummary {
        let cleanedProfessors = professorNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let signature = cleanedProfessors.sorted().joined(separator: "|")

        if let cached = CourseAISummaryStore.load(courseID: course.id),
           cached.professorSignature == signature {
            return cached
        }

        let payloads = try await fetchProfessorPayloads(course: course, professorNames: cleanedProfessors)
        let professors = payloads.map(\.professor)

        let difficultyValues = professors.compactMap { numericValue(from: $0.rateMyProfessorDifficulty) }
        let overallDifficulty: String
        if let average = average(of: difficultyValues) {
            overallDifficulty = "Avg RMP difficulty \(formatOneDecimal(average))/5"
        } else {
            overallDifficulty = "See professor cards below"
        }

        let headline: String
        if professors.isEmpty {
            headline = "No professor ratings found"
        } else {
            headline = "RMP data for \(professors.count) professor\(professors.count == 1 ? "" : "s")"
        }

        let sources = Set(payloads.map(\.sourcesNote).filter { !$0.isEmpty })
        let payload = SummaryPayload(
            headline: headline,
            overallDifficulty: overallDifficulty,
            recommendation: "",
            professors: professors,
            sourcesNote: sources.isEmpty ? "Rate My Professors prioritized when found" : sources.sorted().joined(separator: " | ")
        )

        let summary = CourseAISummary(
            courseID: course.id,
            professorSignature: signature,
            headline: payload.headline,
            overallDifficulty: payload.overallDifficulty,
            recommendation: payload.recommendation,
            professors: payload.professors,
            sourcesNote: payload.sourcesNote,
            generatedAt: Date()
        )

        CourseAISummaryStore.save(summary)
        return summary
    }

    private static func fetchProfessorPayloads(
        course: Course,
        professorNames: [String]
    ) async throws -> [ProfessorPayload] {
        var results: [ProfessorPayload] = []
        for professorName in professorNames {
            results.append(try await fetchProfessorPayload(course: course, professorName: professorName))
        }
        return results
    }

    private static func fetchProfessorPayload(
        course: Course,
        professorName: String
    ) async throws -> ProfessorPayload {
        let prompt = """
        You are extracting exact instructor metrics for a course at Rensselaer Polytechnic Institute (RPI) in Troy, New York.
        Search for the exact professor and use URL context on the exact Rate My Professors page if you find it.
        Prioritize Rate My Professors over all other sources for these metrics.
        Do not compare this professor to any other professor.
        Ignore department heads, coordinators, or administrative names unless you find evidence this exact person teaches the course at RPI.
        If a Rate My Professors page exists for this professor at RPI, extract the exact metrics from that page.
        Only use "Not enough public data" if you cannot find an RMP page or exact overall score.
        Use "Unavailable" only for an individual metric that is missing while other RMP metrics were found.

        Course:
        - School: Rensselaer Polytechnic Institute (RPI)
        - Subject: \(course.subject)
        - Number: \(course.number)
        - Title: \(course.title)

        Professor:
        - Name: \(professorName)

        Return STRICT JSON only with this shape:
        {
          "professor": {
            "name": "Professor Name",
            "summary": "very short note under 10 words",
            "sentiment": "positive | mixed | negative",
            "ratingText": "RMP primary or RMP plus fallback",
            "rateMyProfessorScore": "exact RMP overall score like 4.2/5, or Not enough public data",
            "rateMyProfessorDifficulty": "exact RMP difficulty like 3.4/5, or Unavailable",
            "rateMyProfessorWouldTakeAgain": "exact RMP would-take-again percent like 78%, or Unavailable",
            "rateMyProfessorRatingCount": "exact number of ratings like 56, or Unavailable",
            "rateMyProfessorSummary": "very short RMP-only note under 10 words"
          },
          "sourcesNote": "very short source note, mention RMP first if used"
        }
        """

        let body = RequestBody(
            contents: [.init(parts: [.init(text: prompt)])],
            tools: [
                .init(url_context: .init()),
                .init(google_search: .init())
            ]
        )

        let text = try await generateText(body: body)
        guard let jsonText = extractJSONObject(from: text),
              let jsonData = jsonText.data(using: .utf8) else {
            throw NSError(domain: "AI", code: -20, userInfo: [NSLocalizedDescriptionKey: "AI summary response was not valid JSON"])
        }

        let payload = try JSONDecoder().decode(ProfessorPayload.self, from: jsonData)
        return ProfessorPayload(
            professor: normalizedProfessor(payload.professor, requestedName: professorName),
            sourcesNote: payload.sourcesNote
        )
    }

    private static func generateText(body: RequestBody) async throws -> String {
        var req = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent?key=\(Self.apiKey)")!
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: req)

        if let apiError = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data) {
            throw NSError(domain: "AI", code: -21, userInfo: [NSLocalizedDescriptionKey: apiError.error.message])
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates.first?.content.parts.compactMap(\.text).joined(separator: "\n") ?? ""
        guard !text.isEmpty else {
            throw NSError(domain: "AI", code: -22, userInfo: [NSLocalizedDescriptionKey: "AI summary response was empty"])
        }
        return text
    }

    private static func normalizedProfessor(_ professor: ProfessorAISummary, requestedName: String) -> ProfessorAISummary {
        ProfessorAISummary(
            name: professor.name.isEmpty ? requestedName : professor.name,
            summary: professor.summary,
            sentiment: professor.sentiment,
            ratingText: professor.ratingText,
            rateMyProfessorScore: professor.rateMyProfessorScore,
            rateMyProfessorDifficulty: professor.rateMyProfessorDifficulty,
            rateMyProfessorWouldTakeAgain: professor.rateMyProfessorWouldTakeAgain,
            rateMyProfessorRatingCount: professor.rateMyProfessorRatingCount,
            rateMyProfessorSummary: professor.rateMyProfessorSummary
        )
    }

    private static func numericValue(from text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = cleaned.split(separator: "/").first else { return nil }
        return Double(token)
    }

    private static func average(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func formatOneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func extractJSONObject(from text: String) -> String? {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return nil
    }

    private struct RequestBody: Encodable {
        struct Content: Encodable {
            struct Part: Encodable { let text: String }
            let parts: [Part]
        }

        struct Tool: Encodable {
            let google_search: GoogleSearch?
            let url_context: URLContext?

            init(google_search: GoogleSearch? = nil, url_context: URLContext? = nil) {
                self.google_search = google_search
                self.url_context = url_context
            }
        }

        struct GoogleSearch: Encodable {}
        struct URLContext: Encodable {}

        let contents: [Content]
        let tools: [Tool]
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let content: Content
        }

        let candidates: [Candidate]

        enum CodingKeys: String, CodingKey {
            case candidates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            candidates = try container.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
        }
    }

    private struct GeminiAPIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

    private struct SummaryPayload {
        let headline: String
        let overallDifficulty: String
        let recommendation: String
        let professors: [ProfessorAISummary]
        let sourcesNote: String
    }

    private struct ProfessorPayload: Decodable {
        let professor: ProfessorAISummary
        let sourcesNote: String

        enum CodingKeys: String, CodingKey {
            case professor
            case sourcesNote
        }

        init(professor: ProfessorAISummary, sourcesNote: String) {
            self.professor = professor
            self.sourcesNote = sourcesNote
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            professor = try container.decodeIfPresent(ProfessorAISummary.self, forKey: .professor)
                ?? ProfessorAISummary(
                    name: "Unknown Professor",
                    summary: "",
                    sentiment: "mixed",
                    ratingText: "Not enough public data",
                    rateMyProfessorScore: "Not enough public data",
                    rateMyProfessorDifficulty: "Unavailable",
                    rateMyProfessorWouldTakeAgain: "Unavailable",
                    rateMyProfessorRatingCount: "Unavailable",
                    rateMyProfessorSummary: ""
                )
            sourcesNote = try container.decodeIfPresent(String.self, forKey: .sourcesNote) ?? "Rate My Professors prioritized when found"
        }
    }
}
