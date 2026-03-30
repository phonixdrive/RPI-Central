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

