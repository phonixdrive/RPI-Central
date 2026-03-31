import SwiftUI

enum FlexDollarMealPlan: String, CaseIterable, Identifiable, Codable {
    case unlimited
    case nineteenOnDemand
    case fifteenOnDemand
    case twelveOnDemand
    case fiveOnDemand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unlimited: return "Unlimited"
        case .nineteenOnDemand: return "19 On Demand"
        case .fifteenOnDemand: return "15 On Demand"
        case .twelveOnDemand: return "12 On Demand"
        case .fiveOnDemand: return "5 On Demand"
        }
    }

    var semesterFlexDollars: Double {
        switch self {
        case .unlimited: return 75
        case .nineteenOnDemand: return 225
        case .fifteenOnDemand: return 375
        case .twelveOnDemand: return 450
        case .fiveOnDemand: return 300
        }
    }

    var annualFlexDollars: Double {
        semesterFlexDollars * 2
    }

    var semesterCost: Double {
        switch self {
        case .unlimited, .nineteenOnDemand, .fifteenOnDemand: return 4405
        case .twelveOnDemand: return 3955
        case .fiveOnDemand: return 1745
        }
    }

    var availabilityNote: String {
        switch self {
        case .unlimited:
            return "Available to all students."
        case .nineteenOnDemand:
            return "Available to all students. First-year students can choose this plan."
        case .fifteenOnDemand:
            return "Available to all students. First-year students can choose this plan."
        case .twelveOnDemand:
            return "Not available to first-year students."
        case .fiveOnDemand:
            return "Only for RAs, graduate students, or approved off-campus undergraduates."
        }
    }
}

struct FlexDollarState: Codable, Equatable {
    var selectedPlan: FlexDollarMealPlan?
    var currentBalance: Double?
}

final class FlexDollarsManager: ObservableObject {
    @Published var statesBySemesterCode: [String: FlexDollarState] = [:] {
        didSet { save() }
    }

    private let storageKey = "flexDollars.bySemester.v1"

    init() {
        load()
    }

    func state(for semesterCode: String) -> FlexDollarState {
        statesBySemesterCode[semesterCode] ?? FlexDollarState(selectedPlan: nil, currentBalance: nil)
    }

    func saveState(_ state: FlexDollarState, for semesterCode: String) {
        statesBySemesterCode[semesterCode] = state
    }

    func clearState(for semesterCode: String) {
        statesBySemesterCode.removeValue(forKey: semesterCode)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: FlexDollarState].self, from: data) else {
            statesBySemesterCode = [:]
            return
        }
        statesBySemesterCode = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(statesBySemesterCode) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

struct FlexDollarSnapshot {
    let plan: FlexDollarMealPlan?
    let balance: Double
    let weeklyBudget: Double?
    let dailyBudget: Double?
    let remainingDays: Int?
    let remainingWeeks: Int?
    let endDate: Date?
    let termHasEnded: Bool
    let termHasStarted: Bool

    var balanceText: String {
        FlexDollarFormat.currency(balance)
    }

    var weeklyBudgetText: String {
        guard let weeklyBudget else { return termHasEnded ? "Term ended" : "Loading dates" }
        return "\(FlexDollarFormat.currency(weeklyBudget))/week"
    }

    var planName: String? {
        plan.map { "\($0.displayName) • \(FlexDollarFormat.currency($0.semesterFlexDollars)) / semester" }
    }

    var detailText: String {
        if termHasEnded {
            return "This term has ended. Update your balance or switch terms to keep planning."
        }

        if !termHasStarted, let endDate {
            return "Term not started yet. Planning through \(FlexDollarFormat.mediumDate(endDate))."
        }

        guard
            let dailyBudget,
            let remainingDays,
            let remainingWeeks,
            let endDate
        else {
            return "Waiting for term dates so the weekly pace can be calculated."
        }

        let dayWord = remainingDays == 1 ? "day" : "days"
        let weekWord = remainingWeeks == 1 ? "week" : "weeks"
        return "About \(FlexDollarFormat.currency(dailyBudget))/day for the next \(remainingDays) \(dayWord), or \(FlexDollarFormat.currency(weeklyBudget ?? 0))/week over \(remainingWeeks) \(weekWord), through \(FlexDollarFormat.mediumDate(endDate))."
    }
}

enum FlexDollarPlanner {
    static func snapshot(
        semester: Semester,
        state: FlexDollarState,
        termBounds: DateInterval?,
        now: Date = Date()
    ) -> FlexDollarSnapshot? {
        let balance = state.currentBalance ?? state.selectedPlan?.semesterFlexDollars
        guard let balance else { return nil }

        let clampedBalance = max(0, balance)

        guard let termBounds else {
            return FlexDollarSnapshot(
                plan: state.selectedPlan,
                balance: clampedBalance,
                weeklyBudget: nil,
                dailyBudget: nil,
                remainingDays: nil,
                remainingWeeks: nil,
                endDate: nil,
                termHasEnded: false,
                termHasStarted: false
            )
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTerm = calendar.startOfDay(for: termBounds.start)
        let endOfTerm = calendar.startOfDay(for: termBounds.end)

        if startOfToday > endOfTerm {
            return FlexDollarSnapshot(
                plan: state.selectedPlan,
                balance: clampedBalance,
                weeklyBudget: nil,
                dailyBudget: nil,
                remainingDays: 0,
                remainingWeeks: 0,
                endDate: termBounds.end,
                termHasEnded: true,
                termHasStarted: true
            )
        }

        let anchorDate = max(startOfToday, startOfTerm)
        let remainingDays = max(1, calendar.dateComponents([.day], from: anchorDate, to: endOfTerm).day.map { $0 + 1 } ?? 1)
        let remainingWeeks = max(1, Int(ceil(Double(remainingDays) / 7.0)))

        return FlexDollarSnapshot(
            plan: state.selectedPlan,
            balance: clampedBalance,
            weeklyBudget: clampedBalance / Double(remainingWeeks),
            dailyBudget: clampedBalance / Double(remainingDays),
            remainingDays: remainingDays,
            remainingWeeks: remainingWeeks,
            endDate: termBounds.end,
            termHasEnded: false,
            termHasStarted: startOfToday >= startOfTerm
        )
    }
}

enum FlexDollarFormat {
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func currency(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func mediumDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

struct FlexDollarsPlannerView: View {
    let semester: Semester
    let termBounds: DateInterval?
    @ObservedObject var manager: FlexDollarsManager
    let themeColor: Color

    @Environment(\.dismiss) private var dismiss
    @FocusState private var balanceFieldFocused: Bool

    @State private var selectedPlan: FlexDollarMealPlan?
    @State private var balanceText: String = ""

    private var parsedBalance: Double? {
        let trimmed = balanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: ""))
    }

    private var previewSnapshot: FlexDollarSnapshot? {
        FlexDollarPlanner.snapshot(
            semester: semester,
            state: FlexDollarState(
                selectedPlan: selectedPlan,
                currentBalance: parsedBalance ?? selectedPlan?.semesterFlexDollars
            ),
            termBounds: termBounds
        )
    }

    var body: some View {
        Form {
            Section("Semester") {
                LabeledContent("Tracking for", value: semester.displayName)
            }

            Section(
                header: Text("Meal Plan"),
                footer: Text("If you do not enter a current balance, the planner uses the plan's starting flex dollars for the semester.")
            ) {
                Picker("Plan", selection: $selectedPlan) {
                    Text("None").tag(nil as FlexDollarMealPlan?)
                    ForEach(FlexDollarMealPlan.allCases) { plan in
                        Text("\(plan.displayName) • \(FlexDollarFormat.currency(plan.semesterFlexDollars))").tag(Optional(plan))
                    }
                }

                if let selectedPlan {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(FlexDollarFormat.currency(selectedPlan.semesterFlexDollars)) Flex Dollars each semester")
                            .font(.subheadline.weight(.semibold))
                        Text(selectedPlan.availabilityNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Semester charge: \(FlexDollarFormat.currency(selectedPlan.semesterCost))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(
                header: Text("Current Balance"),
                footer: Text("For spring, enter your actual live balance if fall carryover changed what you have left.")
            ) {
                TextField("Current flex balance", text: $balanceText)
                    .keyboardType(.decimalPad)
                    .focused($balanceFieldFocused)

                if let selectedPlan {
                    Button("Use \(FlexDollarFormat.currency(selectedPlan.semesterFlexDollars)) from \(selectedPlan.displayName)") {
                        balanceText = String(format: "%.2f", selectedPlan.semesterFlexDollars)
                    }
                }
            }

            Section("Planner") {
                if let previewSnapshot {
                    LabeledContent("Balance", value: previewSnapshot.balanceText)
                    LabeledContent("Recommended pace", value: previewSnapshot.weeklyBudgetText)

                    if let remainingDays = previewSnapshot.remainingDays {
                        LabeledContent("Days remaining", value: "\(remainingDays)")
                    }

                    if let remainingWeeks = previewSnapshot.remainingWeeks {
                        LabeledContent("Weeks remaining", value: "\(remainingWeeks)")
                    }

                    Text(previewSnapshot.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose a plan or enter a balance to see your spending pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if selectedPlan != nil || !balanceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear Setup", role: .destructive) {
                        manager.clearState(for: semester.rawValue)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Flex Dollars")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    balanceFieldFocused = false
                }
            }
        }
        .onAppear {
            let saved = manager.state(for: semester.rawValue)
            selectedPlan = saved.selectedPlan
            if let currentBalance = saved.currentBalance {
                balanceText = String(format: "%.2f", currentBalance)
            } else if let savedPlan = saved.selectedPlan {
                balanceText = String(format: "%.2f", savedPlan.semesterFlexDollars)
            }
        }
        .onChange(of: selectedPlan) { _, _ in
            persistCurrentDraft()
        }
        .onChange(of: balanceText) { _, _ in
            persistCurrentDraft()
        }
        .tint(themeColor)
    }

    private func persistCurrentDraft() {
        let trimmed = balanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if selectedPlan == nil {
                manager.clearState(for: semester.rawValue)
            } else {
                manager.saveState(
                    FlexDollarState(selectedPlan: selectedPlan, currentBalance: nil),
                    for: semester.rawValue
                )
            }
            return
        }

        guard let parsedBalance else { return }
        manager.saveState(
            FlexDollarState(selectedPlan: selectedPlan, currentBalance: parsedBalance),
            for: semester.rawValue
        )
    }
}

struct FlexDollarsBalanceUpdateView: View {
    let semester: Semester
    @ObservedObject var manager: FlexDollarsManager
    let themeColor: Color

    @Environment(\.dismiss) private var dismiss
    @FocusState private var balanceFieldFocused: Bool

    @State private var balanceText: String = ""
    @State private var workingBalance: Double = 0

    private var savedPlan: FlexDollarMealPlan? {
        manager.state(for: semester.rawValue).selectedPlan
    }

    var body: some View {
        Form {
            Section("Current Balance") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FlexDollarFormat.currency(workingBalance))
                        .font(.title2.bold())
                    Text(savedPlan?.displayName ?? "Custom balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                TextField("Exact balance", text: $balanceText)
                    .keyboardType(.decimalPad)
                    .focused($balanceFieldFocused)
            }

            Section("Quick Spend") {
                quickAdjustRow(title: "-$1", amount: -1)
                quickAdjustRow(title: "-$5", amount: -5)
                quickAdjustRow(title: "-$10", amount: -10)
                quickAdjustRow(title: "-$20", amount: -20)
            }

            Section("Quick Add Back") {
                quickAdjustRow(title: "+$1", amount: 1)
                quickAdjustRow(title: "+$5", amount: 5)
                quickAdjustRow(title: "+$10", amount: 10)
                quickAdjustRow(title: "+$20", amount: 20)
            }

            Section {
                Text("Changes save automatically as you update the balance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Update Flex")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    balanceFieldFocused = false
                }
            }
        }
        .onAppear {
            let saved = manager.state(for: semester.rawValue)
            let startingBalance = saved.currentBalance ?? saved.selectedPlan?.semesterFlexDollars ?? 0
            workingBalance = max(0, startingBalance)
            balanceText = String(format: "%.2f", workingBalance)
        }
        .onChange(of: balanceText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let parsed = Double(trimmed.replacingOccurrences(of: ",", with: "")) else { return }
            workingBalance = max(0, parsed)
            persistBalance(workingBalance)
        }
        .tint(themeColor)
    }

    private func quickAdjustRow(title: String, amount: Double) -> some View {
        Button(title) {
            let nextBalance = max(0, workingBalance + amount)
            workingBalance = nextBalance
            balanceText = String(format: "%.2f", nextBalance)
            persistBalance(nextBalance)
        }
    }

    private func persistBalance(_ value: Double) {
        manager.saveState(
            FlexDollarState(
                selectedPlan: savedPlan,
                currentBalance: value
            ),
            for: semester.rawValue
        )
    }
}
