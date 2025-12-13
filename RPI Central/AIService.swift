// AIService.swift

import Foundation

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
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)")!
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
