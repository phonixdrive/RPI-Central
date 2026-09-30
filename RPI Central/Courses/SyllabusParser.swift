//
//  SyllabusParser.swift
//  RPI Central
//
//  Finds important dates in a syllabus. Works from positioned text so it can
//  read weekly schedule tables, where a row's date is the Monday of that week
//  and the column says which day something actually happens:
//
//      WEEK  Week of (Mon)  Tue                        Wed   Fri      Homework
//      7     10/05/26       TEST1 (during test block)        Lec 12   HW3
//
//  Everything else is read line by line ("HW 1 due Fri Sep 11 at 11:59pm").
//

import CoreGraphics
import Foundation

/// A run of text on a page. Positions are in points from the top-left corner.
struct SyllabusLine: Equatable {
    var text: String
    var page: Int
    var minX: CGFloat
    var maxX: CGFloat
    var top: CGFloat
    var height: CGFloat

    var midX: CGFloat { (minX + maxX) / 2 }
}

struct SyllabusCandidate: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var date: Date
    var kind: CourseTaskKind
    /// Recognized as an exam, due date, etc. Unrecognized dated lines start unchecked.
    var isImportant: Bool
    var isSelected: Bool
    let sourceLine: String
    /// Something to double-check, such as a date inferred from "week of".
    var note: String? = nil
    /// A task of the same kind is already due that day for this class.
    var alreadyAdded = false
}

enum SyllabusDateExtractor {
    /// When tests are held, from a sentence like "Tests will be given on
    /// Tuesdays from 6PM – 7:50PM".
    struct TestBlock: Equatable {
        var weekday: Int
        var hour: Int
        var minute: Int
    }

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

    // MARK: - Entry points

    /// Plain text, one line per row (tests and pasted text).
    static func candidates(
        in text: String,
        term: DateInterval?,
        classTimes: [Int: DateComponents] = [:],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [SyllabusCandidate] {
        let lines = text.components(separatedBy: .newlines).enumerated().map { index, line in
            SyllabusLine(text: line, page: 0, minX: 0, maxX: CGFloat(line.count) * 6, top: CGFloat(index) * 14, height: 12)
        }
        return candidates(in: lines, term: term, classTimes: classTimes, calendar: calendar, now: now)
    }

    /// Positioned lines from a PDF or scan.
    /// - Parameter classTimes: class start time by weekday (1 = Sunday), used
    ///   for exams and quizzes that don't give a time.
    static func candidates(
        in lines: [SyllabusLine],
        term: DateInterval?,
        classTimes: [Int: DateComponents] = [:],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [SyllabusCandidate] {
        let rows = groupIntoRows(lines)
        let fullText = rows.map(rowText).joined(separator: "\n")
        let context = Context(
            term: term,
            classTimes: classTimes,
            testBlock: testBlock(in: fullText),
            calendar: calendar,
            now: now
        )

        var tableRows: Set<Int> = []
        var results = weeklyTableCandidates(rows: rows, context: context, consumedRows: &tableRows)
        for (index, row) in rows.enumerated() where !tableRows.contains(index) {
            results += lineCandidates(in: rowText(row), context: context)
        }

        // Drop repeats (a date listed in the table and again in a summary).
        var seen: Set<String> = []
        results = results.filter { candidate in
            let key = "\(calendar.startOfDay(for: candidate.date).timeIntervalSince1970)|\(candidate.kind.rawValue)|\(candidate.title.lowercased())"
            return seen.insert(key).inserted
        }
        return results.sorted { $0.date < $1.date }
    }

    private struct Context {
        let term: DateInterval?
        let classTimes: [Int: DateComponents]
        let testBlock: TestBlock?
        let calendar: Calendar
        let now: Date

        func inTerm(_ date: Date) -> Bool {
            term.map { $0.contains(date) } ?? true
        }

        /// Exams and quizzes happen in class or the test block; everything
        /// else is due at the end of the day.
        func defaultDate(for kind: CourseTaskKind, on day: Date, preferTestBlock: Bool = false) -> Date {
            let weekday = calendar.component(.weekday, from: day)
            var hour = 23, minute = 59
            if kind == .exam, let testBlock, preferTestBlock || testBlock.weekday == weekday {
                hour = testBlock.hour
                minute = testBlock.minute
            } else if kind == .exam || kind == .quiz {
                if let time = classTimes[weekday], let classHour = time.hour {
                    hour = classHour
                    minute = time.minute ?? 0
                } else {
                    hour = 9
                    minute = 0
                }
            }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
    }

    // MARK: - Rows

    /// Lines at the same height on a page, left to right.
    static func groupIntoRows(_ lines: [SyllabusLine]) -> [[SyllabusLine]] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.page, $0.top, $0.minX) < ($1.page, $1.top, $1.minX) }
        var rows: [[SyllabusLine]] = []
        for line in sorted {
            if let first = rows.last?.first, first.page == line.page,
               abs(first.top - line.top) < min(first.height, line.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.minX < $1.minX } }
    }

    private static func rowText(_ row: [SyllabusLine]) -> String {
        row.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
    }

    // MARK: - Weekly schedule tables

    private struct Column {
        enum Role { case day(Int), homework }
        let role: Role
        let center: CGFloat
    }

    /// Whole-word weekday names, so "month" isn't Monday.
    private static let weekdayWords: [(pattern: String, weekday: Int)] = [
        (#"\b(sunday|sun)\b"#, 1), (#"\b(monday|mon)\b"#, 2), (#"\b(tuesday|tues|tue)\b"#, 3),
        (#"\b(wednesday|wed)\b"#, 4), (#"\b(thursday|thurs|thur|thu)\b"#, 5), (#"\b(friday|fri)\b"#, 6),
        (#"\b(saturday|sat)\b"#, 7),
    ]

    private static let weekdayNames: [(prefix: String, weekday: Int)] = [
        ("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7),
    ]

    /// "Tue", "Tues.", "Tuesday", "(Mon)" → weekday number.
    static func weekday(named text: String) -> Int? {
        let word = text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        guard word.count >= 3, word.count <= 9 else { return nil }
        let full = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (prefix, weekday) in weekdayNames where word.hasPrefix(prefix) {
            if full[weekday - 1].hasPrefix(word) || ["tues", "thur", "thurs"].contains(word) { return weekday }
        }
        return nil
    }

    private static func isHomeworkHeader(_ text: String) -> Bool {
        let word = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["homework", "hw", "assignments", "assignment", "due", "hw due", "homework due", "deliverables"].contains(word)
    }

    private static func weeklyTableCandidates(rows: [[SyllabusLine]], context: Context, consumedRows: inout Set<Int>) -> [SyllabusCandidate] {
        var results: [SyllabusCandidate] = []
        var index = 0
        while index < rows.count {
            let header = rows[index]
            let dayColumns = header.compactMap { cell in weekday(named: cell.text).map { Column(role: .day($0), center: cell.midX) } }
            guard Set(dayColumns.compactMap { if case .day(let d) = $0.role { d } else { nil } }).count >= 2 else {
                index += 1
                continue
            }
            let homeworkColumns = header.filter { isHomeworkHeader($0.text) }.map { Column(role: .homework, center: $0.midX) }
            let columns = (dayColumns + homeworkColumns).sorted { $0.center < $1.center }
            let firstDayLeft = (dayColumns.map(\.center).min() ?? 0) - 40
            let tableLeft = header.map(\.minX).min() ?? 0
            let tableWidth = max((header.map(\.maxX).max() ?? 0) - tableLeft, 1)

            consumedRows.insert(index)
            var cells: [WeekCell] = []
            var weekStart: Date?
            var rowsSinceAnchor = 0
            var cursor = index + 1

            while cursor < rows.count {
                let row = rows[cursor]
                // Body text running across the page ends the table.
                if row.count == 1, let only = row.first, only.maxX - only.minX > tableWidth * 0.6 { break }
                // So does another table's header.
                if row.filter({ weekday(named: $0.text) != nil }).count >= 2 { break }

                let leftText = row.filter { $0.midX < firstDayLeft }.map(\.text).joined(separator: " ")
                if !leftText.isEmpty, let anchor = anchorDate(in: leftText, context: context) {
                    weekStart = anchor
                    rowsSinceAnchor = 0
                } else {
                    rowsSinceAnchor += 1
                    if weekStart != nil, rowsSinceAnchor > 12 { break }
                }

                if let weekStart {
                    for line in row where line.midX >= firstDayLeft {
                        guard let column = columns.min(by: { abs($0.center - line.midX) < abs($1.center - line.midX) }) else { continue }
                        cells.append(WeekCell(weekStart: weekStart, column: column, text: line.text))
                    }
                }
                consumedRows.insert(cursor)
                cursor += 1
            }

            results += tableEvents(from: cells, columns: columns, context: context)
            index = cursor
        }
        return results
    }

    private struct WeekCell {
        let weekStart: Date
        let column: Column
        let text: String
    }

    /// "10/05/26", "7 10/05/26", "Aug 24", "Week 3: 9/7".
    private static func anchorDate(in text: String, context: Context) -> Date? {
        let cleaned = normalized(text)
        if let match = cleaned.range(of: #"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#, options: .regularExpression) {
            let parts = cleaned[match].split(separator: "/").compactMap { Int($0) }
            guard parts.count >= 2 else { return nil }
            var year = parts.count > 2 ? parts[2] : nil
            if let y = year, y < 100 { year = 2000 + y }
            return makeDate(month: parts[0], day: parts[1], year: year, context: context)
        }
        if let match = cleaned.range(of: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2})\b"#, options: [.regularExpression, .caseInsensitive]) {
            let words = cleaned[match].split(separator: " ")
            guard let monthWord = words.first?.lowercased(), let day = Int(words.last ?? ""),
                  let month = monthNames.firstIndex(where: { monthWord.hasPrefix($0) }) else { return nil }
            return makeDate(month: month + 1, day: day, year: nil, context: context)
        }
        return nil
    }

    private static func makeDate(month: Int, day: Int, year: Int?, context: Context) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let calendar = context.calendar
        if let year {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        // No year: pick the one that lands inside the term.
        let base = context.term.map { calendar.component(.year, from: $0.start) }
            ?? calendar.component(.year, from: context.now)
        for year in [base, base + 1, base - 1] {
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)), context.inTerm(date) {
                return date
            }
        }
        return calendar.date(from: DateComponents(year: base, month: month, day: day))
    }

    private static func tableEvents(from cells: [WeekCell], columns: [Column], context: Context) -> [SyllabusCandidate] {
        let calendar = context.calendar
        let dayWeekdays = columns.compactMap { column -> Int? in
            if case .day(let weekday) = column.role { return weekday }
            return nil
        }
        // Merge each week's column into one piece of text, so "EXAM" and
        // "REVIEW" on two lines read as "EXAM REVIEW".
        var merged: [(weekStart: Date, column: Column, text: String)] = []
        for cell in cells {
            if let last = merged.last, last.weekStart == cell.weekStart, last.column.center == cell.column.center {
                merged[merged.count - 1].text += " " + cell.text
            } else if let existing = merged.firstIndex(where: { $0.weekStart == cell.weekStart && $0.column.center == cell.column.center }) {
                merged[existing].text += " " + cell.text
            } else {
                merged.append((cell.weekStart, cell.column, cell.text))
            }
        }

        func date(for weekday: Int, weekStart: Date) -> Date {
            let startWeekday = calendar.component(.weekday, from: weekStart)
            let offset = (weekday - startWeekday + 7) % 7
            return calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        }

        var results: [SyllabusCandidate] = []
        for (weekStart, column, text) in merged {
            let weekLabel = weekStart.formatted(.dateTime.month(.abbreviated).day())
            for event in events(in: text) {
                var day: Date
                var note: String?
                var selected = true
                var preferTestBlock = false

                switch column.role {
                case .day(let weekday):
                    day = date(for: weekday, weekStart: weekStart)
                case .homework:
                    // No day given; use the last class day of that week.
                    day = date(for: dayWeekdays.max() ?? 6, weekStart: weekStart)
                    note = "Listed for the week of \(weekLabel). Check the due date."
                }

                if event.kind == .exam, event.mentionsTestBlock, let testBlock = context.testBlock {
                    day = date(for: testBlock.weekday, weekStart: weekStart)
                    preferTestBlock = true
                }
                if event.isFinalsWeek {
                    note = "Finals week starts \(weekLabel). Set the date once the final exam schedule is out."
                    selected = false
                    day = weekStart
                }

                let due = context.defaultDate(for: event.kind, on: day, preferTestBlock: preferTestBlock)
                guard context.inTerm(due) else { continue }
                results.append(SyllabusCandidate(
                    title: event.title,
                    date: due,
                    kind: event.kind,
                    isImportant: true,
                    isSelected: selected && due >= calendar.startOfDay(for: context.now),
                    sourceLine: "Week of \(weekLabel): \(text)",
                    note: note
                ))
            }
        }
        return results
    }

    struct TableEvent: Equatable {
        var kind: CourseTaskKind
        var title: String
        var mentionsTestBlock = false
        var isFinalsWeek = false
    }

    /// Exams, quizzes, homework, and projects named in one schedule cell.
    static func events(in text: String) -> [TableEvent] {
        let lower = text.lowercased()
        var found: [TableEvent] = []

        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(lower.startIndex..., in: lower)
            return regex.matches(in: lower, range: range).map { match in
                (0..<match.numberOfRanges).map { i in
                    Range(match.range(at: i), in: lower).map { String(lower[$0]) } ?? ""
                }
            }
        }

        if lower.contains("final exam week") || lower.contains("finals week") {
            found.append(TableEvent(kind: .exam, title: "Final exam", isFinalsWeek: true))
        } else {
            for groups in matches(#"\b(final exam|midterm exam|final|midterm|test|exam)\s*#?\s*(\d{0,2})\b(?!\s*(?:review|block|period|slot|day|week))"#) {
                let word = groups[1]
                let number = groups[2]
                // "Exam review" and "review for test" are lectures.
                if lower.contains("review") && number.isEmpty { continue }
                if word == "final" && !lower.contains("final exam") && number.isEmpty { continue }
                let base: String = switch word {
                case "final exam", "final": "Final exam"
                case "midterm", "midterm exam": "Midterm"
                case "test": "Test"
                default: "Exam"
                }
                found.append(TableEvent(
                    kind: .exam,
                    title: number.isEmpty ? base : "\(base) \(Int(number) ?? 0)",
                    mentionsTestBlock: lower.contains("test block") || lower.contains("testing block") || lower.contains("exam block")
                ))
            }
        }
        for groups in matches(#"\b(?:quiz|q)\s*#?\s*(\d{1,2})\b"#) {
            found.append(TableEvent(kind: .quiz, title: "Quiz \(Int(groups[1]) ?? 0)"))
        }
        if found.allSatisfy({ $0.kind != .quiz }), lower.range(of: #"\bquiz\b"#, options: .regularExpression) != nil {
            found.append(TableEvent(kind: .quiz, title: "Quiz"))
        }
        for groups in matches(#"\b(hw|homework|assignment|pset|problem set|lab)\s*#?\s*(\d{1,2})\b"#) {
            let label: String = switch groups[1] {
            case "hw", "homework": "HW"
            case "pset", "problem set": "Problem Set"
            case "lab": "Lab"
            default: "Assignment"
            }
            found.append(TableEvent(kind: .assignment, title: "\(label) \(Int(groups[2]) ?? 0)"))
        }
        for groups in matches(#"\b(project\s*(?:proposal|presentation|report|\d+)?|presentations?)\b[^.]{0,20}\bdue\b|\b(project (?:proposal|presentation)s?)\b"#) {
            let phrase = (groups[1].isEmpty ? groups[2] : groups[1]).trimmingCharacters(in: .whitespaces)
            found.append(TableEvent(kind: .project, title: phrase.prefix(1).uppercased() + phrase.dropFirst()))
        }

        var seen: Set<String> = []
        return found.filter { seen.insert($0.title).inserted }
    }

    /// "Tests will be given ... on Tuesday's from 6PM – 7:50PM".
    static func testBlock(in text: String) -> TestBlock? {
        let flattened = text.replacingOccurrences(of: "\n", with: " ").lowercased()
        let pattern = #"(?:tests?|exams?|midterms?|testing period|test block)[^.]{0,120}?\b(sun|mon|tue|wed|thu|fri|sat)[a-z]*(?:['’]s|s)?\b[^.]{0,30}?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|to)\s*\d{1,2}(?::\d{2})?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        // Skip "Exam Locations: TBD … Office Hours: Tuesday 12:15PM – 1:45PM".
        let ignored = ["office", "hours", "location", "recitation", "lecture", "class meet"]
        guard let match = regex.matches(in: flattened, range: NSRange(flattened.startIndex..., in: flattened)).first(where: { match in
            guard let range = Range(match.range, in: flattened) else { return false }
            let matched = flattened[range]
            return !ignored.contains { matched.contains($0) }
        }) else { return nil }
        func group(_ i: Int) -> String? {
            Range(match.range(at: i), in: flattened).map { String(flattened[$0]) }
        }
        guard let dayWord = group(1), let weekday = weekday(named: dayWord),
              var hour = group(2).flatMap(Int.init) else { return nil }
        let minute = group(3).flatMap(Int.init) ?? 0
        let meridiem = group(4) ?? group(5)
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == nil, hour < 8 { hour += 12 } // "6 – 7:50" means evening
        return TestBlock(weekday: weekday, hour: hour, minute: minute)
    }

    // MARK: - Dated lines

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "Mon. Sept. 7" → "Mon Sep 7", which NSDataDetector reads reliably.
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\b(sept)\.?(?=\s|\d|$)"#, with: "Sep", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\b(jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\.(?=\s|\d)"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\b(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\.(?=\s)"#, with: "$1", options: [.regularExpression, .caseInsensitive])
    }

    private static func lineCandidates(in rawLine: String, context: Context) -> [SyllabusCandidate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let calendar = context.calendar

        // "Week 9  Oct 27": drop the week number so it isn't read as a day.
        let line = normalized(rawLine)
            .replacingOccurrences(of: #"^\s*(week|wk|lecture|lec|class|day)\s*\d+[.:)]?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count >= 4, line.count <= 240 else { return [] }
        let range = NSRange(line.startIndex..., in: line)

        let matches = detector.matches(in: line, options: [], range: range)
        // A bare time ("6:00pm") only sets the time of the line's date. A bare
        // weekday ("due Wednesday") isn't a time.
        let timeOnly = matches.first { match in
            Range(match.range, in: line).map { !isCalendarDate(String(line[$0])) && hasTime(String(line[$0])) } ?? false
        }
        let lineTime = timeOnly?.date.map { calendar.dateComponents([.hour, .minute], from: $0) }
        var dateMatches = matches.filter { match in
            Range(match.range, in: line).map { isCalendarDate(String(line[$0])) } ?? false
        }
        // "Sep 28 - Oct 2" is one week, starting on the first date.
        if dateMatches.count == 2,
           let first = dateMatches[0].date, let second = dateMatches[1].date,
           (1...7).contains(calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: second)).day ?? 0),
           let gap = Range(NSRange(location: dateMatches[0].range.upperBound, length: dateMatches[1].range.location - dateMatches[0].range.upperBound), in: line),
           line[gap].trimmingCharacters(in: .whitespaces).range(of: #"^(-|–|—|to|through|thru)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            dateMatches.removeLast()
        }
        let dateCount = dateMatches.count

        var results: [SyllabusCandidate] = []
        for (position, match) in dateMatches.enumerated() {
            guard var date = match.date, let matchRange = Range(match.range, in: line) else { continue }
            let matchedText = String(line[matchRange])

            date = adjustedYear(date, matchedText: matchedText, term: context.term, calendar: calendar)
            // Outside the semester (e.g. the syllabus revision date).
            guard context.inTerm(date) else { continue }

            let lower = line.lowercased()
            // With several dates on a row, each date owns the text after it.
            var titleText: String
            if dateCount > 1 {
                let start = position == 0 ? line.startIndex : matchRange.upperBound
                let end = position + 1 < dateMatches.count
                    ? (Range(dateMatches[position + 1].range, in: line)?.lowerBound ?? line.endIndex)
                    : line.endIndex
                let prefix = position == 0 ? String(line[line.startIndex..<matchRange.lowerBound]) : ""
                titleText = start < end ? prefix + " " + String(line[matchRange.upperBound..<end]) : prefix
            } else {
                titleText = line.replacingCharacters(in: matchRange, with: " ")
            }
            if let timeOnly, let timeRange = Range(timeOnly.range, in: line) {
                titleText = titleText.replacingOccurrences(of: String(line[timeRange]), with: " ")
            }
            // Drop the second date of a "Sep 28 - Oct 2" range from the title.
            for other in matches where other.range != match.range {
                if let otherRange = Range(other.range, in: line), isCalendarDate(String(line[otherRange])), dateCount == 1 {
                    titleText = titleText.replacingOccurrences(of: String(line[otherRange]), with: " ")
                }
            }

            // "Week of Oct 5: Test 1 on Tuesday" means Oct 6.
            var note: String?
            let restLower = titleText.lowercased()
            let dateWeekday = calendar.component(.weekday, from: date)
            let otherWeekdays = weekdayWords.compactMap { pattern, weekday in
                restLower.range(of: pattern, options: .regularExpression) != nil && weekday != dateWeekday ? weekday : nil
            }
            if dateCount == 1, otherWeekdays.count == 1, let target = otherWeekdays.first {
                let offset = (target - dateWeekday + 7) % 7
                date = calendar.date(byAdding: .day, value: offset, to: date) ?? date
            } else if lower.contains("week of") || lower.range(of: #"\bweek\s*\d+\s*\("#, options: .regularExpression) != nil {
                note = "Listed for the week of \(date.formatted(.dateTime.month(.abbreviated).day())). Check the day."
            }

            func dueDate(for kind: CourseTaskKind) -> Date {
                if hasTime(matchedText) {
                    return calendar.date(bySettingHour: calendar.component(.hour, from: match.date ?? date),
                                         minute: calendar.component(.minute, from: match.date ?? date),
                                         second: 0, of: date) ?? date
                }
                if let hour = lineTime?.hour {
                    return calendar.date(bySettingHour: hour, minute: lineTime?.minute ?? 0, second: 0, of: date) ?? date
                }
                return context.defaultDate(for: kind, on: date, preferTestBlock: lower.contains("test block"))
            }

            // A row naming specific work ("Quiz 3", "HW 4 due") becomes one
            // task per item, with a clean title.
            let named = events(in: titleText)
            if !named.isEmpty {
                for event in named {
                    let due = dueDate(for: event.kind)
                    results.append(SyllabusCandidate(
                        title: event.title,
                        date: due,
                        kind: event.kind,
                        isImportant: true,
                        isSelected: due >= calendar.startOfDay(for: context.now),
                        sourceLine: line,
                        note: note
                    ))
                }
                continue
            }

            var rule = rules.first { rule in rule.keywords.contains { restLower.contains($0) } }
            // "Exam review" and "Midterm review" are lectures.
            if rule?.kind == .exam, restLower.contains("review") { rule = nil }
            let title = cleanedTitle(titleText)
            guard !title.isEmpty else { continue }

            let kind = rule?.kind ?? .other
            let due = dueDate(for: kind)
            results.append(SyllabusCandidate(
                title: title,
                date: due,
                kind: kind,
                isImportant: rule != nil,
                isSelected: rule != nil && due >= calendar.startOfDay(for: context.now),
                sourceLine: line,
                note: note
            ))
        }
        return results
    }

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
            // "Assignment 3 Due" reads better as "Assignment 3".
            .replacingOccurrences(of: #"(\d)\s+due$"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,;").union(.whitespaces))
        if title.count > 80 {
            title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }
}
