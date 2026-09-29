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

// MARK: - Views

struct SyllabusImportView: View {
    let enrollmentID: String
    let courseTitle: String
    let term: DateInterval?
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tasks = TasksManager.shared
    @State private var candidates: [SyllabusCandidate] = []
    @State private var phase: Phase = .choose
    @State private var showFilePicker = false
    @State private var showScanner = false
    @State private var showUnrecognized = false

    private enum Phase: Equatable { case choose, reading, review, empty }

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choose: chooser
                case .reading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your syllabus…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView {
                        Label("No Dates Found", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("Try a clearer scan, or a PDF with the course schedule.")
                    } actions: {
                        Button("Try Another") { phase = .choose }
                            .buttonStyle(.borderedProminent)
                    }
                case .review: review
                }
            }
            .navigationTitle("Import Syllabus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if phase == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(selectedCount)") { addSelected() }
                            .disabled(selectedCount == 0)
                    }
                }
            }
            #if DEBUG
            .task {
                // Testing: RPI_SYLLABUS_TEST_PDF=/path/to/file.pdf reads that file directly.
                if let path = ProcessInfo.processInfo.environment["RPI_SYLLABUS_TEST_PDF"], phase == .choose {
                    process { await SyllabusTextReader.text(fromPDF: URL(fileURLWithPath: path)) }
                }
            }
            #endif
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    process { await SyllabusTextReader.text(fromPDF: url) }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    guard !images.isEmpty else { return }
                    process { await SyllabusTextReader.text(fromImages: images) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var chooser: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(accent)
                    Text("Find exams and due dates")
                        .font(.title3.bold())
                    Text("Pick your \(courseTitle) syllabus. You’ll review every date before anything is added.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose a PDF", systemImage: "doc.richtext")
                }
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan Paper Pages", systemImage: "doc.viewfinder")
                    }
                }
            }
        }
    }

    private var review: some View {
        let important = candidates.indices.filter { candidates[$0].isImportant }
        let other = candidates.indices.filter { !candidates[$0].isImportant }

        return List {
            Section {
                ForEach(important, id: \.self) { index in
                    CandidateRow(candidate: $candidates[index], accent: accent)
                }
            } header: {
                Text(important.isEmpty ? "No exams or due dates found" : "\(important.count) found")
            } footer: {
                Text("Uncheck anything that isn’t right. Tap a row to edit it.")
            }

            if !other.isEmpty {
                Section {
                    DisclosureGroup("Other dated lines (\(other.count))", isExpanded: $showUnrecognized) {
                        ForEach(other, id: \.self) { index in
                            CandidateRow(candidate: $candidates[index], accent: accent)
                        }
                    }
                }
            }
        }
    }

    private func process(_ read: @escaping () async -> String) {
        phase = .reading
        Task {
            let text = await read()
            var found = SyllabusDateExtractor.candidates(in: text, term: term)
            let existing = tasks.tasks.filter { $0.enrollmentID == enrollmentID }
            for index in found.indices {
                let candidate = found[index]
                if existing.contains(where: { $0.kind == candidate.kind && Calendar.current.isDate($0.dueDate, inSameDayAs: candidate.date) }) {
                    found[index].alreadyAdded = true
                    found[index].isSelected = false
                }
            }
            candidates = found
            phase = found.isEmpty ? .empty : .review
        }
    }

    private func addSelected() {
        for candidate in candidates where candidate.isSelected {
            tasks.add(CourseTask(
                enrollmentID: enrollmentID,
                title: candidate.title,
                kind: candidate.kind,
                dueDate: candidate.date,
                notes: "From syllabus: \(candidate.sourceLine)"
            ))
        }
        dismiss()
    }
}

private struct CandidateRow: View {
    @Binding var candidate: SyllabusCandidate
    let accent: Color
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                candidate.isSelected.toggle()
            } label: {
                Image(systemName: candidate.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(candidate.isSelected ? accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(candidate.isSelected ? "Selected" : "Not selected")

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Label(candidate.kind.label, systemImage: candidate.kind.systemImage)
                    Text("·")
                    Text(candidate.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                }
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
                if candidate.alreadyAdded {
                    Label("Already in your tasks", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { isEditing = true }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                Form {
                    TextField("Title", text: $candidate.title)
                    Picker("Type", selection: $candidate.kind) {
                        ForEach(CourseTaskKind.allCases) { kind in
                            Label(kind.label, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    DatePicker("Due", selection: $candidate.date)
                    Section("From the syllabus") {
                        Text(candidate.sourceLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Edit Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            candidate.isSelected = true
                            isEditing = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// VisionKit's document camera: edge detection, perspective correction, multiple pages.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map(scan.imageOfPage(at:)))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}
