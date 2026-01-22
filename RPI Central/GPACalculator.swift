//
//  GPACalculator.swift
//  RPI Central
//

import Foundation
import SwiftUI

// MARK: - Standard 4.0 GPA scale with +/-.

enum LetterGrade: String, CaseIterable, Identifiable, Codable {
    case aPlus  = "A+"
    case a      = "A"
    case aMinus = "A-"
    case bPlus  = "B+"
    case b      = "B"
    case bMinus = "B-"
    case cPlus  = "C+"
    case c      = "C"
    case cMinus = "C-"
    case d      = "D"
    case f      = "F"

    var id: String { rawValue }

    var points: Double {
        switch self {
        case .aPlus:  return 4.00
        case .a:      return 4.00
        case .aMinus: return 3.67
        case .bPlus:  return 3.33
        case .b:      return 3.00
        case .bMinus: return 2.67
        case .cPlus:  return 2.33
        case .c:      return 2.00
        case .cMinus: return 1.67
        case .d:      return 1.00
        case .f:      return 0.00
        }
    }

    static var ordered: [LetterGrade] { Self.allCases }
}

enum GPACalculator {

    static func weightedGPA(_ entries: [(grade: LetterGrade, credits: Double)]) -> Double? {
        guard !entries.isEmpty else { return nil }

        var totalPoints = 0.0
        var totalCredits = 0.0

        for e in entries {
            totalPoints += e.grade.points * e.credits
            totalCredits += e.credits
        }

        guard totalCredits > 0 else { return nil }
        return totalPoints / totalCredits
    }

    static func format(_ gpa: Double?) -> String {
        guard let gpa else { return "—" }
        return String(format: "%.2f", gpa)
    }

    /// Converts a numeric percent grade into a letter grade (typical US scale).
    static func letterGrade(fromPercent p: Double) -> LetterGrade {
        let x = max(0, min(100, p))

        if x >= 97 { return .aPlus }
        if x >= 93 { return .a }
        if x >= 90 { return .aMinus }
        if x >= 87 { return .bPlus }
        if x >= 83 { return .b }
        if x >= 80 { return .bMinus }
        if x >= 77 { return .cPlus }
        if x >= 73 { return .c }
        if x >= 70 { return .cMinus }
        if x >= 60 { return .d }
        return .f
    }

    static func displayPercentAndLetter(
        enrollmentID: String,
        fallbackLetter: LetterGrade?
    ) -> (percentText: String, letterText: String) {
        let breakdown = GradeBreakdownStore.load(enrollmentID: enrollmentID)
        let pct = breakdown?.currentGradePercent

        let letter: LetterGrade? =
            breakdown?.overrideLetterGrade
            ?? (pct.map { letterGrade(fromPercent: $0) })
            ?? fallbackLetter

        let percentText: String = {
            guard let pct else { return "—%" }
            return String(format: "%.0f%%", pct)
        }()

        let letterText: String = letter?.rawValue ?? "—"
        return (percentText, letterText)
    }
}

// MARK: - Grade Breakdown Models

enum GradeScoreMode: String, Codable, CaseIterable, Identifiable {
    case percent
    case points
    var id: String { rawValue }
}

enum CategoryInputMode: String, Codable, CaseIterable, Identifiable {
    case percent
    case points
    case subItems

    var id: String { rawValue }

    var label: String {
        switch self {
        case .percent: return "%"
        case .points: return "Points"
        case .subItems: return "Sub-items"
        }
    }
}

struct GradeSubItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var earned: Double
    var possible: Double

    init(id: UUID = UUID(), title: String, earned: Double = 0, possible: Double = 0) {
        self.id = id
        self.title = title
        self.earned = earned
        self.possible = possible
    }

    var percent: Double {
        guard possible > 0 else { return 0 }
        return max(0, min(100, (earned / possible) * 100.0))
    }

    private enum CodingKeys: String, CodingKey { case id, title, earned, possible }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.title = (try? c.decode(String.self, forKey: .title)) ?? "Item"
        self.earned = (try? c.decode(Double.self, forKey: .earned)) ?? 0
        self.possible = (try? c.decode(Double.self, forKey: .possible)) ?? 0
    }
}

struct AttendanceTracker: Codable, Equatable {
    var totalClasses: Int
    var attendedClasses: Int

    init(totalClasses: Int = 0, attendedClasses: Int = 0) {
        self.totalClasses = totalClasses
        self.attendedClasses = attendedClasses
    }

    var percent: Double {
        guard totalClasses > 0 else { return 0 }
        return max(0, min(100, (Double(attendedClasses) / Double(totalClasses)) * 100.0))
    }

    mutating func attended() {
        totalClasses += 1
        attendedClasses += 1
    }

    mutating func missed() {
        totalClasses += 1
    }

    mutating func reset() {
        totalClasses = 0
        attendedClasses = 0
    }
}

struct GradeCategory: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String

    /// 0–100
    var weightPercent: Double

    // Standard score input
    var scoreMode: GradeScoreMode
    var scorePercent: Double
    var earnedPoints: Double
    var possiblePoints: Double

    // Sub-items
    var usesSubItems: Bool
    var items: [GradeSubItem]

    // Attendance tracking
    var attendance: AttendanceTracker

    init(
        id: UUID = UUID(),
        name: String,
        weightPercent: Double,
        scoreMode: GradeScoreMode = .percent,
        scorePercent: Double = 0,
        earnedPoints: Double = 0,
        possiblePoints: Double = 0,
        usesSubItems: Bool = false,
        items: [GradeSubItem] = [],
        attendance: AttendanceTracker = AttendanceTracker()
    ) {
        self.id = id
        self.name = name
        self.weightPercent = weightPercent

        self.scoreMode = scoreMode
        self.scorePercent = scorePercent
        self.earnedPoints = earnedPoints
        self.possiblePoints = possiblePoints

        self.usesSubItems = usesSubItems
        self.items = items

        self.attendance = attendance
    }

    var isParticipationName: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n == "participation" || n.contains("participation") || n.contains("attendance")
    }

    var inputMode: CategoryInputMode {
        if usesSubItems { return .subItems }
        return scoreMode == .percent ? .percent : .points
    }

    mutating func setInputMode(_ mode: CategoryInputMode) {
        switch mode {
        case .subItems:
            usesSubItems = true
        case .percent:
            usesSubItems = false
            scoreMode = .percent
        case .points:
            usesSubItems = false
            scoreMode = .points
        }
    }

    func normalizedScorePercent() -> Double {
        if usesSubItems {
            let e = items.reduce(0.0) { $0 + $1.earned }
            let p = items.reduce(0.0) { $0 + $1.possible }
            guard p > 0 else { return 0 }
            return max(0, min(100, (e / p) * 100.0))
        }

        switch scoreMode {
        case .percent:
            return max(0, min(100, scorePercent))
        case .points:
            guard possiblePoints > 0 else { return 0 }
            return max(0, min(100, (earnedPoints / possiblePoints) * 100.0))
        }
    }
}

struct GradeBreakdown: Codable, Equatable {
    var categories: [GradeCategory] = []
    var overrideLetterGrade: LetterGrade? = nil
    var creditsOverride: Double? = nil

    /// DEFAULT OFF (your request)
    var participationTrackingEnabled: Bool = false

    var totalWeight: Double {
        categories.reduce(0) { partial, c in
            if participationTrackingEnabled && c.isParticipationName { return partial }
            return partial + c.weightPercent
        }
    }

    var currentGradePercent: Double? {
        let w = totalWeight
        guard w > 0 else { return nil }

        let weightedSum = categories.reduce(0.0) { partial, c in
            if participationTrackingEnabled && c.isParticipationName { return partial }
            return partial + (c.weightPercent * c.normalizedScorePercent() / 100.0)
        }

        return (weightedSum / w) * 100.0
    }
}

// MARK: - Storage

private enum GradeBreakdownStore {
    static let keyPrefix = "gradeBreakdown.v9."
    static func key(for enrollmentID: String) -> String { keyPrefix + enrollmentID }

    static func load(enrollmentID: String) -> GradeBreakdown? {
        guard let data = UserDefaults.standard.data(forKey: key(for: enrollmentID)) else { return nil }
        return try? JSONDecoder().decode(GradeBreakdown.self, from: data)
    }

    static func save(_ breakdown: GradeBreakdown, enrollmentID: String) {
        guard let data = try? JSONEncoder().encode(breakdown) else { return }
        UserDefaults.standard.set(data, forKey: key(for: enrollmentID))
    }

    static func clear(enrollmentID: String) {
        UserDefaults.standard.removeObject(forKey: key(for: enrollmentID))
    }
}

// MARK: - Reusable themed pill buttons (prevents system-blue bug)

private struct ThemedPillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(prominent ? Color(.secondarySystemBackground) : Color(.tertiarySystemFill))
            .clipShape(Capsule())
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

private extension ButtonStyle where Self == ThemedPillButtonStyle {
    static func themedPill(prominent: Bool = false) -> ThemedPillButtonStyle {
        ThemedPillButtonStyle(prominent: prominent)
    }
}

// MARK: - HomeView grade capsule (shows % + letter and opens breakdown)

struct GradeBreakdownButton: View {
    @EnvironmentObject var calendarViewModel: CalendarViewModel
    let enrollmentID: String

    @State private var showBreakdown = false

    var body: some View {
        let fallbackLetter = calendarViewModel.grade(for: enrollmentID)
        let display = GPACalculator.displayPercentAndLetter(
            enrollmentID: enrollmentID,
            fallbackLetter: fallbackLetter
        )

        Button {
            showBreakdown = true
        } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Text(display.percentText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(display.letterText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 62, alignment: .trailing)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showBreakdown) {
            NavigationStack {
                GradeBreakdownView(enrollmentID: enrollmentID)
                    .environmentObject(calendarViewModel)
                // IMPORTANT: DO NOT set `.tint(.accentColor)` here.
                // It can override your custom theme tint and force blue.
            }
        }
    }
}

// MARK: - Grade Breakdown View

struct GradeBreakdownView: View {
    let enrollmentID: String

    @EnvironmentObject var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case categoryTitle(UUID)
        case weight(UUID)
        case percentScore(UUID)
        case earned(UUID)
        case possible(UUID)

        case itemTitle(UUID)
        case itemEarned(UUID)
        case itemPossible(UUID)

        case credits
        case attended(UUID)
        case total(UUID)
    }

    @State private var breakdown: GradeBreakdown = GradeBreakdown(categories: [
        GradeCategory(name: "Midterm", weightPercent: 25),
        GradeCategory(name: "Final", weightPercent: 35),
        GradeCategory(name: "Homework", weightPercent: 30),
        GradeCategory(name: "Participation", weightPercent: 10)
    ], participationTrackingEnabled: false)

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Displayed Grade")
                        .font(.headline)
                    Spacer()
                    Text(displayedGradeText())
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                if let pct = breakdown.currentGradePercent, breakdown.overrideLetterGrade == nil {
                    HStack {
                        Text("Current Grade")
                        Spacer()
                        Text(String(format: "%.2f%%", pct))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Total Weight (counted)")
                    Spacer()
                    Text("\(breakdown.totalWeight, specifier: "%.1f")%")
                        .foregroundStyle(breakdown.totalWeight == 100 ? Color.secondary : Color.orange)
                }

                if breakdown.totalWeight != 100 {
                    Text("Weights that are counted should add to 100%.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Participation tracking")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        breakdown.participationTrackingEnabled.toggle()
                    } label: {
                        Text(breakdown.participationTrackingEnabled ? "On" : "Off")
                    }
                    .buttonStyle(.themedPill())
                }
            }

            Section("Credits (GPA weight)") {
                HStack {
                    Text("Credits")
                    Spacer()
                    TextField("4.0", value: Binding(
                        get: { breakdown.creditsOverride ?? 4.0 },
                        set: { breakdown.creditsOverride = max(0, $0) }
                    ), format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focusedField, equals: .credits)
                    .foregroundStyle(.tint)
                }
            }

            Section("Override (for GPA)") {
                Picker("Override Grade", selection: Binding(
                    get: { breakdown.overrideLetterGrade },
                    set: { newValue in
                        breakdown.overrideLetterGrade = newValue
                        applyOverrideToCalendarVM()
                    }
                )) {
                    Text("Auto (use breakdown)").tag(LetterGrade?.none)
                    ForEach(LetterGrade.ordered) { g in
                        Text(g.rawValue).tag(Optional(g))
                    }
                }
            }

            Section("Categories") {
                ForEach($breakdown.categories) { category in
                    VStack(alignment: .leading, spacing: 12) {

                        // Centered, theme-colored editable category title
                        ZStack {
                            HStack {
                                Spacer()
                                Button(role: .destructive) {
                                    if let idx = breakdown.categories.firstIndex(where: { $0.id == category.wrappedValue.id }) {
                                        breakdown.categories.remove(at: idx)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                            }

                            TextField("Category", text: category.name)
                                .font(.title3.weight(.bold))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .focused($focusedField, equals: .categoryTitle(category.wrappedValue.id))
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                                .foregroundStyle(.tint)
                        }

                        if breakdown.participationTrackingEnabled && category.wrappedValue.isParticipationName {
                            participationPanel(category: category)
                        } else {
                            standardPanel(category: category)
                        }
                    }
                    .padding(.vertical, 10)
                }

                Button {
                    breakdown.categories.append(GradeCategory(name: "New Category", weightPercent: 0))
                } label: {
                    Label("Add Category", systemImage: "plus.circle.fill")
                }
            }

            Section {
                Button(role: .destructive) {
                    breakdown = GradeBreakdown(categories: [])
                    GradeBreakdownStore.clear(enrollmentID: enrollmentID)
                    breakdown.overrideLetterGrade = nil
                    breakdown.creditsOverride = nil
                    applyOverrideToCalendarVM()
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Grade Breakdown")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    focusedField = nil
                    dismiss()
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            if let saved = GradeBreakdownStore.load(enrollmentID: enrollmentID) {
                breakdown = saved
            } else {
                if breakdown.creditsOverride == nil { breakdown.creditsOverride = 4.0 }
            }
            applyOverrideToCalendarVM()
        }
        .onChange(of: breakdown) { _ in
            GradeBreakdownStore.save(breakdown, enrollmentID: enrollmentID)
            applyOverrideToCalendarVM()
        }
    }

    // MARK: Panels

    private func standardPanel(category: Binding<GradeCategory>) -> some View {
        let id = category.wrappedValue.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weight")
                Spacer()
                TextField("0", value: category.weightPercent, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focusedField, equals: .weight(id))
                    .foregroundStyle(.tint)
                Text("%").foregroundStyle(.secondary)
            }

            Picker("Input", selection: Binding(
                get: { category.wrappedValue.inputMode },
                set: { category.wrappedValue.setInputMode($0) }
            )) {
                Text("%").tag(CategoryInputMode.percent)
                Text("Points").tag(CategoryInputMode.points)
                Text("Sub-items").tag(CategoryInputMode.subItems)
            }
            .pickerStyle(.segmented)

            if category.wrappedValue.inputMode == .subItems {
                HStack {
                    Text("Category Total")
                    Spacer()
                    Text("\(category.wrappedValue.normalizedScorePercent(), specifier: "%.2f")%")
                        .foregroundStyle(.secondary)
                }

                ForEach(category.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Item name", text: item.title)
                                .font(.subheadline.weight(.semibold))
                                .focused($focusedField, equals: .itemTitle(item.wrappedValue.id))
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                                .foregroundStyle(.tint)

                            Spacer(minLength: 0)

                            Button(role: .destructive) {
                                if let idx = category.wrappedValue.items.firstIndex(where: { $0.id == item.wrappedValue.id }) {
                                    category.wrappedValue.items.remove(at: idx)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }

                        HStack {
                            Text("Score")
                            Spacer()

                            TextField("Earned", value: item.earned, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .focused($focusedField, equals: .itemEarned(item.wrappedValue.id))
                                .foregroundStyle(.tint)

                            Text("/").foregroundStyle(.secondary)

                            TextField("Total", value: item.possible, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .focused($focusedField, equals: .itemPossible(item.wrappedValue.id))
                                .foregroundStyle(.tint)

                            Text("(\(item.wrappedValue.percent, specifier: "%.1f")%)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Button {
                        let n = category.wrappedValue.items.count + 1
                        category.wrappedValue.items.append(GradeSubItem(title: "Item \(n)"))
                    } label: {
                        Label("Add item", systemImage: "plus")
                    }
                    .buttonStyle(.themedPill())

                    Spacer()
                }
                .padding(.top, 4)

            } else if category.wrappedValue.inputMode == .percent {
                HStack {
                    Text("Score")
                    Spacer()
                    TextField("0", value: category.scorePercent, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($focusedField, equals: .percentScore(id))
                        .foregroundStyle(.tint)
                    Text("%").foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Score")
                    Spacer()

                    TextField("Earned", value: category.earnedPoints, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($focusedField, equals: .earned(id))
                        .foregroundStyle(.tint)

                    Text("/").foregroundStyle(.secondary)

                    TextField("Total", value: category.possiblePoints, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($focusedField, equals: .possible(id))
                        .foregroundStyle(.tint)

                    Text("(\(category.wrappedValue.normalizedScorePercent(), specifier: "%.1f")%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func participationPanel(category: Binding<GradeCategory>) -> some View {
        let id = category.wrappedValue.id

        return VStack(alignment: .leading, spacing: 10) {
            Text("Attendance tracking (does not affect grade).")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Attended")
                Spacer()

                TextField("0", value: Binding(
                    get: { category.wrappedValue.attendance.attendedClasses },
                    set: { category.wrappedValue.attendance.attendedClasses = max(0, $0) }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focusedField, equals: .attended(id))
                .foregroundStyle(.tint)

                Text("/").foregroundStyle(.secondary)

                TextField("0", value: Binding(
                    get: { category.wrappedValue.attendance.totalClasses },
                    set: { category.wrappedValue.attendance.totalClasses = max(0, $0) }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focusedField, equals: .total(id))
                .foregroundStyle(.tint)
            }

            HStack {
                Text("Rate")
                Spacer()
                Text("\(category.wrappedValue.attendance.percent, specifier: "%.1f")%")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    category.wrappedValue.attendance.attended()
                } label: {
                    Label("Attended (+1)", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.themedPill(prominent: true))

                Button {
                    category.wrappedValue.attendance.missed()
                } label: {
                    Label("Missed (+1)", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.themedPill())
            }
            .padding(.top, 4)

            Button(role: .destructive) {
                category.wrappedValue.attendance.reset()
            } label: {
                Label("Reset attendance", systemImage: "arrow.counterclockwise")
            }
            .padding(.top, 4)
        }
    }

    // MARK: Helpers

    private func displayedGradeText() -> String {
        if let g = breakdown.overrideLetterGrade {
            return g.rawValue
        }
        if let pct = breakdown.currentGradePercent {
            return String(format: "%.0f%%", pct)
        }
        return "—"
    }

    private func applyOverrideToCalendarVM() {
        if let g = breakdown.overrideLetterGrade {
            calendarViewModel.setGrade(g, for: enrollmentID)
        } else {
            calendarViewModel.clearGrade(for: enrollmentID)
        }
    }
}
