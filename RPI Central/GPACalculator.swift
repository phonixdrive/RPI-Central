//
//  GPACalculator.swift
//  RPI Central
//

import Foundation
import SwiftUI

// MARK: - Standard 4.0 GPA scale with +/-.

enum LetterGrade: String, CaseIterable, Identifiable, Codable {
    case pass   = "P"
    case noPass = "NP"
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
        case .pass:   return 4.00
        case .noPass: return 0.00
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

    static var ordered: [LetterGrade] {
        [.pass, .noPass, .aPlus, .a, .aMinus, .bPlus, .b, .bMinus, .cPlus, .c, .cMinus, .d, .f]
    }
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
        letterGrade(fromPercent: p, using: .standard)
    }

    static func letterGrade(fromPercent p: Double, using cutoffs: GradeCutoffs) -> LetterGrade {
        let x = max(0, min(100, p))

        if x >= cutoffs.aPlus { return .aPlus }
        if x >= cutoffs.a { return .a }
        if x >= cutoffs.aMinus { return .aMinus }
        if x >= cutoffs.bPlus { return .bPlus }
        if x >= cutoffs.b { return .b }
        if x >= cutoffs.bMinus { return .bMinus }
        if x >= cutoffs.cPlus { return .cPlus }
        if x >= cutoffs.c { return .c }
        if x >= cutoffs.cMinus { return .cMinus }
        if x >= cutoffs.d { return .d }
        return .f
    }

    static func displayPercentAndLetter(
        enrollmentID: String,
        fallbackLetter: LetterGrade?
    ) -> (percentText: String, letterText: String) {
        let breakdown = GradeBreakdownStore.load(enrollmentID: enrollmentID)
        let pct = breakdown?.currentGradePercent

        let letter = resolvedLetter(enrollmentID: enrollmentID, fallbackLetter: fallbackLetter)

        let percentText: String = {
            guard let pct else { return "—%" }
            return String(format: "%.0f%%", pct)
        }()

        let letterText: String = letter?.rawValue ?? "—"
        return (percentText, letterText)
    }

    static func resolvedLetter(enrollmentID: String, fallbackLetter: LetterGrade?) -> LetterGrade? {
        let breakdown = GradeBreakdownStore.load(enrollmentID: enrollmentID)
        return breakdown?.resolvedLetterGrade() ?? fallbackLetter
    }
}

struct GradeCutoffs: Codable, Equatable {
    var aPlus: Double = 97
    var a: Double = 93
    var aMinus: Double = 90
    var bPlus: Double = 87
    var b: Double = 83
    var bMinus: Double = 80
    var cPlus: Double = 77
    var c: Double = 73
    var cMinus: Double = 70
    var d: Double = 60
    var linearShiftPercent: Double = 0

    static let standard = GradeCutoffs()

    private enum CodingKeys: String, CodingKey {
        case aPlus, a, aMinus, bPlus, b, bMinus, cPlus, c, cMinus, d, linearShiftPercent
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aPlus = try container.decodeIfPresent(Double.self, forKey: .aPlus) ?? 97
        a = try container.decodeIfPresent(Double.self, forKey: .a) ?? 93
        aMinus = try container.decodeIfPresent(Double.self, forKey: .aMinus) ?? 90
        bPlus = try container.decodeIfPresent(Double.self, forKey: .bPlus) ?? 87
        b = try container.decodeIfPresent(Double.self, forKey: .b) ?? 83
        bMinus = try container.decodeIfPresent(Double.self, forKey: .bMinus) ?? 80
        cPlus = try container.decodeIfPresent(Double.self, forKey: .cPlus) ?? 77
        c = try container.decodeIfPresent(Double.self, forKey: .c) ?? 73
        cMinus = try container.decodeIfPresent(Double.self, forKey: .cMinus) ?? 70
        d = try container.decodeIfPresent(Double.self, forKey: .d) ?? 60
        linearShiftPercent = try container.decodeIfPresent(Double.self, forKey: .linearShiftPercent) ?? 0
    }

    var shifted: GradeCutoffs {
        var out = self
        let shift = max(0, linearShiftPercent)
        out.aPlus = max(0, aPlus - shift)
        out.a = max(0, a - shift)
        out.aMinus = max(0, aMinus - shift)
        out.bPlus = max(0, bPlus - shift)
        out.b = max(0, b - shift)
        out.bMinus = max(0, bMinus - shift)
        out.cPlus = max(0, cPlus - shift)
        out.c = max(0, c - shift)
        out.cMinus = max(0, cMinus - shift)
        out.d = max(0, d - shift)
        out.linearShiftPercent = shift
        return out
    }

    func minimum(for grade: LetterGrade) -> Double {
        switch grade {
        case .aPlus: return aPlus
        case .a: return a
        case .aMinus: return aMinus
        case .bPlus: return bPlus
        case .b: return b
        case .bMinus: return bMinus
        case .cPlus: return cPlus
        case .c: return c
        case .cMinus: return cMinus
        case .d: return d
        case .f, .pass, .noPass: return 0
        }
    }

    mutating func setMinimum(_ value: Double, for grade: LetterGrade) {
        let clamped = max(0, min(100, value))
        switch grade {
        case .aPlus: aPlus = clamped
        case .a: a = clamped
        case .aMinus: aMinus = clamped
        case .bPlus: bPlus = clamped
        case .b: b = clamped
        case .bMinus: bMinus = clamped
        case .cPlus: cPlus = clamped
        case .c: c = clamped
        case .cMinus: cMinus = clamped
        case .d: d = clamped
        case .f, .pass, .noPass: break
        }
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

enum SimpleGradeInputMode: String, Codable, CaseIterable, Identifiable {
    case percent
    case letter

    var id: String { rawValue }
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
    init(
        id: UUID = UUID(),
        name: String,
        weightPercent: Double,
        scoreMode: GradeScoreMode = .percent,
        scorePercent: Double = 0,
        earnedPoints: Double = 0,
        possiblePoints: Double = 0,
        usesSubItems: Bool = false,
        items: [GradeSubItem] = []
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
    var gradeCutoffs: GradeCutoffs = .standard
    var isAdvancedMode: Bool = true
    var simpleScorePercent: Double? = nil
    var simpleInputMode: SimpleGradeInputMode = .percent
    var simpleLetterGrade: LetterGrade? = nil

    init(
        categories: [GradeCategory] = [],
        overrideLetterGrade: LetterGrade? = nil,
        creditsOverride: Double? = nil,
        gradeCutoffs: GradeCutoffs = .standard,
        isAdvancedMode: Bool = true,
        simpleScorePercent: Double? = nil,
        simpleInputMode: SimpleGradeInputMode = .percent,
        simpleLetterGrade: LetterGrade? = nil
    ) {
        self.categories = categories
        self.overrideLetterGrade = overrideLetterGrade
        self.creditsOverride = creditsOverride
        self.gradeCutoffs = gradeCutoffs
        self.isAdvancedMode = isAdvancedMode
        self.simpleScorePercent = simpleScorePercent
        self.simpleInputMode = simpleInputMode
        self.simpleLetterGrade = simpleLetterGrade
    }

    private enum CodingKeys: String, CodingKey {
        case categories
        case overrideLetterGrade
        case creditsOverride
        case gradeCutoffs
        case isAdvancedMode
        case simpleScorePercent
        case simpleInputMode
        case simpleLetterGrade
        case participationTrackingEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decodeIfPresent([GradeCategory].self, forKey: .categories) ?? []
        overrideLetterGrade = try c.decodeIfPresent(LetterGrade.self, forKey: .overrideLetterGrade)
        creditsOverride = try c.decodeIfPresent(Double.self, forKey: .creditsOverride)
        gradeCutoffs = try c.decodeIfPresent(GradeCutoffs.self, forKey: .gradeCutoffs) ?? .standard
        simpleScorePercent = try c.decodeIfPresent(Double.self, forKey: .simpleScorePercent)
        simpleInputMode = try c.decodeIfPresent(SimpleGradeInputMode.self, forKey: .simpleInputMode) ?? .percent
        simpleLetterGrade = try c.decodeIfPresent(LetterGrade.self, forKey: .simpleLetterGrade)

        if let advanced = try c.decodeIfPresent(Bool.self, forKey: .isAdvancedMode) {
            isAdvancedMode = advanced
        } else {
            isAdvancedMode = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categories, forKey: .categories)
        try container.encodeIfPresent(overrideLetterGrade, forKey: .overrideLetterGrade)
        try container.encodeIfPresent(creditsOverride, forKey: .creditsOverride)
        try container.encode(gradeCutoffs, forKey: .gradeCutoffs)
        try container.encode(isAdvancedMode, forKey: .isAdvancedMode)
        try container.encodeIfPresent(simpleScorePercent, forKey: .simpleScorePercent)
        try container.encode(simpleInputMode, forKey: .simpleInputMode)
        try container.encodeIfPresent(simpleLetterGrade, forKey: .simpleLetterGrade)
    }

    var totalWeight: Double {
        isAdvancedMode ? categories.reduce(0) { $0 + $1.weightPercent } : 100
    }

    var currentGradePercent: Double? {
        if !isAdvancedMode {
            if simpleInputMode == .letter { return nil }
            guard let simpleScorePercent else { return nil }
            return max(0, min(100, simpleScorePercent))
        }

        let w = totalWeight
        guard w > 0 else { return nil }

        let weightedSum = categories.reduce(0.0) { partial, c in
            return partial + (c.weightPercent * c.normalizedScorePercent() / 100.0)
        }

        return (weightedSum / w) * 100.0
    }

    func effectiveCutoffs() -> GradeCutoffs {
        gradeCutoffs.shifted
    }

    func categoryDisplayPercent(_ category: GradeCategory) -> Double? {
        return category.normalizedScorePercent()
    }

    func categoryWeightedPercent(_ category: GradeCategory) -> Double? {
        guard let pct = categoryDisplayPercent(category) else { return nil }
        return (category.weightPercent * pct) / 100.0
    }

    func resolvedLetterGrade() -> LetterGrade? {
        if let overrideLetterGrade {
            return overrideLetterGrade
        }

        if !isAdvancedMode && simpleInputMode == .letter {
            return simpleLetterGrade
        }

        guard let pct = currentGradePercent else { return nil }
        return GPACalculator.letterGrade(fromPercent: pct, using: effectiveCutoffs())
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
    @Environment(\.colorScheme) private var colorScheme
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
            .background(
                Capsule()
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule()
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.14)
                            : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
            )
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
        case cutoff(LetterGrade)

        case itemTitle(UUID)
        case itemEarned(UUID)
        case itemPossible(UUID)

        case credits
        case simpleScore
        case simpleLetter
    }

    @State private var breakdown: GradeBreakdown = GradeBreakdown(categories: [
        GradeCategory(name: "Midterm", weightPercent: 25),
        GradeCategory(name: "Final", weightPercent: 35),
        GradeCategory(name: "Homework", weightPercent: 30),
        GradeCategory(name: "Participation", weightPercent: 10)
    ], isAdvancedMode: true)

    var body: some View {
        ScrollViewReader { proxy in
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
                        Text("Total Weight")
                        Spacer()
                        Text("\(breakdown.totalWeight, specifier: "%.1f")%")
                            .foregroundStyle(breakdown.totalWeight == 100 ? Color.secondary : Color.orange)
                    }

                    if breakdown.totalWeight != 100 {
                        Text("Configured category weights should add to 100%.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Text("Calculator Mode")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            breakdown.isAdvancedMode.toggle()
                        } label: {
                            Text(breakdown.isAdvancedMode ? "Advanced" : "Simple")
                        }
                        .buttonStyle(.themedPill())
                    }
                }

                if breakdown.isAdvancedMode {
                    Section("Category Summary") {
                        ForEach(breakdown.categories) { category in
                            HStack {
                                Text(category.name.isEmpty ? "Category" : category.name)
                                Spacer()
                                if let pct = breakdown.categoryDisplayPercent(category),
                                   let weighted = breakdown.categoryWeightedPercent(category) {
                                    Text("\(pct, specifier: "%.1f")% • \(weighted, specifier: "%.1f")% weighted")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("—")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
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
                        .id(Field.credits)
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

                Section("Letter Grade Cutoffs") {
                    HStack {
                        Text("Shift all letters")
                        Spacer()

                        TextField(
                            "0",
                            value: Binding(
                                get: { breakdown.gradeCutoffs.linearShiftPercent },
                                set: { breakdown.gradeCutoffs.linearShiftPercent = max(0, min(100, $0)) }
                            ),
                            format: .number
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .foregroundStyle(.tint)

                        Text("%")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(LetterGrade.ordered.filter { ![.pass, .noPass, .f].contains($0) }, id: \.self) { grade in
                        HStack {
                            Text(grade.rawValue)
                                .font(.subheadline.weight(.semibold))
                                Spacer()

                            Text("Min")
                                .foregroundStyle(.secondary)

                            TextField(
                                "0",
                                value: Binding(
                                    get: { breakdown.effectiveCutoffs().minimum(for: grade) },
                                    set: { newValue in
                                        let adjusted = newValue + breakdown.gradeCutoffs.linearShiftPercent
                                        breakdown.gradeCutoffs.setMinimum(adjusted, for: grade)
                                    }
                                ),
                                format: .number
                            )
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                                .focused($focusedField, equals: .cutoff(grade))
                                .foregroundStyle(.tint)
                                .id(Field.cutoff(grade))

                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Reset to standard cutoffs") {
                        breakdown.gradeCutoffs = .standard
                    }
                    .buttonStyle(.themedPill())

                    Text("Cutoffs are minimum percentages for each letter grade.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if breakdown.isAdvancedMode {
                    Section("Categories") {
                        ForEach($breakdown.categories) { category in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 12) {
                                    TextField("Category", text: category.name)
                                        .font(.title3.weight(.bold))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .focused($focusedField, equals: .categoryTitle(category.wrappedValue.id))
                                        .submitLabel(.done)
                                        .onSubmit { focusedField = nil }
                                        .foregroundStyle(.tint)
                                        .id(Field.categoryTitle(category.wrappedValue.id))

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

                                standardPanel(category: category)
                            }
                            .padding(.vertical, 10)
                        }

                        Button {
                            breakdown.categories.append(GradeCategory(name: "New Category", weightPercent: 0))
                        } label: {
                            Label("Add Category", systemImage: "plus.circle.fill")
                        }
                    }
                } else {
                    Section("Simple Grade") {
                        Picker("Input", selection: $breakdown.simpleInputMode) {
                            Text("%").tag(SimpleGradeInputMode.percent)
                            Text("Letter").tag(SimpleGradeInputMode.letter)
                        }
                        .pickerStyle(.segmented)

                        if breakdown.simpleInputMode == .percent {
                        HStack {
                            Text("Overall Grade")
                            Spacer()
                            TextField(
                                "0",
                                value: Binding(
                                    get: { breakdown.simpleScorePercent ?? 0 },
                                    set: { breakdown.simpleScorePercent = max(0, min(100, $0)) }
                                ),
                                format: .number
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .simpleScore)
                            .foregroundStyle(.tint)
                            .id(Field.simpleScore)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                        } else {
                            Picker("Overall Grade", selection: Binding(
                                get: { breakdown.simpleLetterGrade },
                                set: { breakdown.simpleLetterGrade = $0 }
                            )) {
                                Text("Select grade").tag(LetterGrade?.none)
                                ForEach(LetterGrade.ordered) { grade in
                                    Text(grade.rawValue).tag(Optional(grade))
                                }
                            }
                            .id(Field.simpleLetter)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        breakdown = GradeBreakdown(categories: [])
                        GradeBreakdownStore.clear(enrollmentID: enrollmentID)
                        breakdown.overrideLetterGrade = nil
                        breakdown.creditsOverride = nil
                        breakdown.gradeCutoffs = .standard
                        breakdown.isAdvancedMode = true
                        breakdown.simpleScorePercent = nil
                        breakdown.simpleInputMode = .percent
                        breakdown.simpleLetterGrade = nil
                        applyOverrideToCalendarVM()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
            .onChange(of: breakdown) {
                GradeBreakdownStore.save(breakdown, enrollmentID: enrollmentID)
                applyOverrideToCalendarVM()
            }
            .onChange(of: focusedField) {
                let field = focusedField
                guard let field else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(field, anchor: .center)
                }
            }
        }
    }

    // MARK: Panels

    private func standardPanel(category: Binding<GradeCategory>) -> some View {
        let id = category.wrappedValue.id

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(displayCategoryName(category.wrappedValue)) Total")
                    Spacer()
                    Text("\(category.wrappedValue.normalizedScorePercent(), specifier: "%.2f")%")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Weighted Total")
                    Spacer()
                    Text("\(breakdown.categoryWeightedPercent(category.wrappedValue) ?? 0, specifier: "%.2f")%")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Weight")
                Spacer()
                TextField("0", value: category.weightPercent, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focusedField, equals: .weight(id))
                    .foregroundStyle(.tint)
                    .id(Field.weight(id))
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
                ForEach(category.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Item name", text: item.title)
                                .font(.subheadline.weight(.semibold))
                                .focused($focusedField, equals: .itemTitle(item.wrappedValue.id))
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                                .foregroundStyle(.tint)
                                .id(Field.itemTitle(item.wrappedValue.id))

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
                                .id(Field.itemEarned(item.wrappedValue.id))

                            Text("/").foregroundStyle(.secondary)

                            TextField("Total", value: item.possible, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .focused($focusedField, equals: .itemPossible(item.wrappedValue.id))
                                .foregroundStyle(.tint)
                                .id(Field.itemPossible(item.wrappedValue.id))

                            Text("(\(item.wrappedValue.percent, specifier: "%.1f")%)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Button {
                        category.wrappedValue.items.append(
                            GradeSubItem(title: nextSubItemTitle(for: category.wrappedValue))
                        )
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
                        .id(Field.percentScore(id))
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
                        .id(Field.earned(id))

                    Text("/").foregroundStyle(.secondary)

                    TextField("Total", value: category.possiblePoints, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($focusedField, equals: .possible(id))
                        .foregroundStyle(.tint)
                        .id(Field.possible(id))

                    Text("(\(category.wrappedValue.normalizedScorePercent(), specifier: "%.1f")%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Helpers

    private func displayCategoryName(_ category: GradeCategory) -> String {
        let trimmed = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Category" : trimmed
    }

    private func nextSubItemTitle(for category: GradeCategory) -> String {
        "\(displayCategoryName(category)) \(category.items.count + 1)"
    }

    private func displayedGradeText() -> String {
        if let resolved = breakdown.resolvedLetterGrade() {
            if let pct = breakdown.currentGradePercent {
                return "\(String(format: "%.0f%%", pct)) • \(resolved.rawValue)"
            }
            return resolved.rawValue
        }
        if let pct = breakdown.currentGradePercent {
            let letter = GPACalculator.letterGrade(fromPercent: pct, using: breakdown.effectiveCutoffs())
            return "\(String(format: "%.0f%%", pct)) • \(letter.rawValue)"
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
