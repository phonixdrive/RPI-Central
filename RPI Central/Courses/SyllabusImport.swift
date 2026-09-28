//
//  SyllabusImport.swift
//  RPI Central
//
//  Finds important dates (exams, due dates, quizzes, projects) in a syllabus
//  PDF or scanned pages, lets the student review them, and adds the ones they
//  keep as tasks for the class. Everything runs on the device.
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import VisionKit

// MARK: - Extraction

struct SyllabusCandidate: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var date: Date
    var kind: CourseTaskKind
    /// Recognized as an exam, due date, etc. Unrecognized dated lines start unchecked.
    var isImportant: Bool
    var isSelected: Bool
    let sourceLine: String
    /// A task of the same kind is already due that day for this class.
    var alreadyAdded = false
}

enum SyllabusDateExtractor {
    private static let rules: [(kind: CourseTaskKind, keywords: [String])] = [
        (.exam, ["final exam", "midterm", "exam", "test "]),
        (.quiz, ["quiz"]),
        (.project, ["project", "presentation", "proposal", "paper", "essay", "report"]),
        (.assignment, ["homework", "hw", "assignment", "problem set", "pset", "lab ", "due", "deadline", "submit"]),
    ]

    /// The class term plus finals week and a little slack on each side.
    static func importWindow(for term: DateInterval) -> DateInterval {
        DateInterval(start: term.start.addingTimeInterval(-7 * 86_400), end: term.end.addingTimeInterval(21 * 86_400))
    }

    /// Finds dated lines in `text`. `term` keeps dates without a year inside
    /// the semester (a spring syllabus that says "Jan 20" means next January).
    static func candidates(in text: String, term: DateInterval?, calendar: Calendar = .current, now: Date = Date()) -> [SyllabusCandidate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }

        var results: [SyllabusCandidate] = []
        var seen: Set<String> = []

        for rawLine in text.components(separatedBy: .newlines) {
            // "Week 9  Oct 27": drop the week number so it isn't read as a day.
            let line = rawLine
                .replacingOccurrences(of: #"^\s*(week|wk|lecture|lec|class|day)\s*\d+[.:)]?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 4, line.count <= 240 else { continue }
            let range = NSRange(line.startIndex..., in: line)

            let matches = detector.matches(in: line, options: [], range: range)
            // A bare time ("6:00pm") only sets the time of the line's date.
            let timeOnly = matches.first { match in
                Range(match.range, in: line).map { !isCalendarDate(String(line[$0])) } ?? false
            }
            let lineTime = timeOnly?.date.map { calendar.dateComponents([.hour, .minute], from: $0) }

            for match in matches {
                guard var date = match.date, let matchRange = Range(match.range, in: line) else { continue }
                let matchedText = String(line[matchRange])
                guard isCalendarDate(matchedText) else { continue }

                date = adjustedYear(date, matchedText: matchedText, term: term, calendar: calendar)
                if let term, !term.contains(date) {
                    // Outside the semester (e.g. the syllabus revision date).
                    continue
                }

                let lower = line.lowercased()
                let rule = rules.first { rule in rule.keywords.contains { lower.contains($0) } }
                var titleText = line.replacingCharacters(in: matchRange, with: " ")
                if let timeOnly, let timeRange = Range(timeOnly.range, in: line) {
                    titleText = titleText.replacingOccurrences(of: String(line[timeRange]), with: " ")
                }
                let title = cleanedTitle(titleText)
                guard !title.isEmpty else { continue }

                let dayKey = "\(calendar.startOfDay(for: date).timeIntervalSince1970)|\(title.lowercased())"
                guard seen.insert(dayKey).inserted else { continue }

                let dueDate: Date
                if hasTime(matchedText) {
                    dueDate = date
                } else if let hour = lineTime?.hour {
                    dueDate = calendar.date(bySettingHour: hour, minute: lineTime?.minute ?? 0, second: 0, of: date) ?? date
                } else {
                    dueDate = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
                }

                results.append(SyllabusCandidate(
                    title: title,
                    date: dueDate,
                    kind: rule?.kind ?? .other,
                    isImportant: rule != nil,
                    isSelected: rule != nil && dueDate >= calendar.startOfDay(for: now),
                    sourceLine: line
                ))
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "Oct 6" or "10/6" — not a bare time like "6:00pm".
    private static func isCalendarDate(_ text: String) -> Bool {
        let lower = text.lowercased()
        if monthNames.contains(where: lower.contains) { return true }
        return lower.range(of: #"\b\d{1,2}/\d{1,2}\b"#, options: .regularExpression) != nil
    }

    private static func hasTime(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains(":") || lower.range(of: #"\d\s*(am|pm)\b"#, options: .regularExpression) != nil
    }

    /// NSDataDetector assumes the current year when the text has none.
    private static func adjustedYear(_ date: Date, matchedText: String, term: DateInterval?, calendar: Calendar) -> Date {
        guard let term, matchedText.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) == nil else { return date }
        if term.contains(date) { return date }
        for offset in [-1, 1] {
            if let shifted = calendar.date(byAdding: .year, value: offset, to: date), term.contains(shifted) {
                return shifted
            }
        }
        return date
    }

    private static func cleanedTitle(_ text: String) -> String {
        var title = text
            .replacingOccurrences(of: #"\b(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(day|nesday|sday|urday)?\.?\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^\s*(week\s*\d+|\d+[.)])\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[\t|•·]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,;()").union(.whitespaces))
            // "HW 1 due at" once the time is removed.
            .replacingOccurrences(of: #"\s+(at|by|on|@)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if title.count > 80 {
            title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }
}

// MARK: - Reading documents

enum SyllabusTextReader {
    /// Text from a PDF; pages without a text layer (scans) are read with OCR.
    static func text(fromPDF url: URL) async -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { return "" }

        var pages: [String] = []
        for index in 0..<min(document.pageCount, 40) {
            guard let page = document.page(at: index) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.count > 40 {
                pages.append(pageText)
            } else {
                let bounds = page.bounds(for: .mediaBox)
                let scale = 2000 / max(bounds.width, bounds.height, 1)
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let cgImage = image.cgImage {
                    pages.append(await recognizeText(in: cgImage))
                }
            }
        }
        return pages.joined(separator: "\n")
    }

    static func text(fromImages images: [UIImage]) async -> String {
        var pages: [String] = []
        for image in images {
            if let cgImage = image.cgImage {
                pages.append(await recognizeText(in: cgImage))
            }
        }
        return pages.joined(separator: "\n")
    }

    static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}

