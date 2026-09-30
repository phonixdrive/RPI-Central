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

// MARK: - Reading documents

enum SyllabusTextReader {
    /// Text lines with their positions. Pages without a text layer (scans)
    /// are read with OCR.
    static func lines(fromPDF url: URL) async -> [SyllabusLine] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { return [] }

        var lines: [SyllabusLine] = []
        for index in 0..<min(document.pageCount, 40) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.count > 40, let selection = page.selection(for: bounds) {
                for line in selection.selectionsByLine() {
                    let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let box = line.bounds(for: page)
                    lines.append(SyllabusLine(
                        text: text,
                        page: index,
                        minX: box.minX - bounds.minX,
                        maxX: box.maxX - bounds.minX,
                        top: bounds.maxY - box.maxY,
                        height: box.height
                    ))
                }
            } else {
                let scale = 2000 / max(bounds.width, bounds.height, 1)
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let cgImage = image.cgImage {
                    lines += await recognizeLines(in: cgImage, page: index)
                }
            }
        }
        return lines
    }

    static func lines(fromImages images: [UIImage]) async -> [SyllabusLine] {
        var lines: [SyllabusLine] = []
        for (index, image) in images.enumerated() {
            if let cgImage = image.cgImage {
                lines += await recognizeLines(in: cgImage, page: index)
            }
        }
        return lines
    }

    static func recognizeLines(in image: CGImage, page: Int) async -> [SyllabusLine] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> SyllabusLine? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    // Vision boxes are normalized with the origin at the bottom left.
                    let box = observation.boundingBox
                    return SyllabusLine(
                        text: text,
                        page: page,
                        minX: box.minX * width,
                        maxX: box.maxX * width,
                        top: (1 - box.maxY) * height,
                        height: box.height * height
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}

// MARK: - Views

struct SyllabusImportView: View {
    let enrollmentID: String
    let courseTitle: String
    let term: DateInterval?
    /// Class start time by weekday, for exams and quizzes without a time.
    var classTimes: [Int: DateComponents] = [:]
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: CalendarViewModel
    @ObservedObject private var tasks = TasksManager.shared
    @State private var candidates: [SyllabusCandidate] = []
    @State private var phase: Phase = .choose
    @State private var showFilePicker = false
    @State private var showScanner = false
    @State private var showUnrecognized = false

    private enum Phase: Equatable { case choose, reading, review, empty }

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    /// Earliest class start on each weekday ("14:00" on Tuesday → 3: 14:00).
    static func classTimes(for section: CourseSection) -> [Int: DateComponents] {
        var times: [Int: DateComponents] = [:]
        for meeting in section.meetings {
            let parts = meeting.start.split(separator: ":").compactMap { Int($0) }
            guard let hour = parts.first else { continue }
            let time = DateComponents(hour: hour, minute: parts.count > 1 ? parts[1] : 0)
            for day in meeting.days {
                let weekday = day.calendarWeekday
                if let existing = times[weekday], (existing.hour ?? 0, existing.minute ?? 0) <= (hour, time.minute ?? 0) { continue }
                times[weekday] = time
            }
        }
        return times
    }

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
                    process { await SyllabusTextReader.lines(fromPDF: URL(fileURLWithPath: path)) }
                }
            }
            #endif
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    process { await SyllabusTextReader.lines(fromPDF: url) }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    guard !images.isEmpty else { return }
                    process { await SyllabusTextReader.lines(fromImages: images) }
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

    private func process(_ read: @escaping () async -> [SyllabusLine]) {
        phase = .reading
        Task {
            let lines = await read()
            let term = term, classTimes = classTimes
            var found = await Task.detached(priority: .userInitiated) {
                SyllabusDateExtractor.candidates(in: lines, term: term, classTimes: classTimes)
            }.value
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
        // After the tasks exist, so the test block doesn't add its own copy.
        viewModel.markTestBlockExams(
            forEnrollmentID: enrollmentID,
            examStarts: candidates.filter { $0.isSelected && $0.kind == .exam }.map(\.date)
        )
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
                    Text(candidate.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                }
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
                if candidate.alreadyAdded {
                    Label("Already in your tasks", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let note = candidate.note {
                    Label(note, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                    if let note = candidate.note {
                        Section {
                            Label(note, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
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
                            candidate.note = nil
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
