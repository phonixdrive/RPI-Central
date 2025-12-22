//
//  PrereqStore.swift
//  RPI Central
//

import Foundation

/// Loads `prereq_graph.json` if it exists in your app bundle.
/// Normalizes keys + values into canonical "SUBJ-1230" IDs so lookups work reliably.
final class PrereqStore {
    static let shared = PrereqStore()
    private init() { load() }

    private var map: [String: [String]] = [:]   // "MATH-2010" -> ["MATH-1010", "PHYS-1100"]

    func prereqIDs(for courseID: String) -> [String] {
        let k = normalizeCourseIDString(courseID)
        return map[k] ?? []
    }

    private func load() {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json"),
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json", subdirectory: "quacs-data-master"),
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json", subdirectory: "Data/quacs-data-master"),
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json", subdirectory: "semester_data")
        ]

        guard let url = candidates.compactMap({ $0 }).first else {
            map = [:]
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: data, options: [])

            if let dict = obj as? [String: Any] {
                var out: [String: [String]] = [:]
                for (k, v) in dict {
                    let nk = normalizeCourseIDString(k)
                    let nv = normalizeValue(v).map(normalizeCourseIDString).filter { !$0.isEmpty }
                    if !nk.isEmpty {
                        out[nk] = Array(Set(nv)).sorted()
                    }
                }
                map = out
            } else {
                map = [:]
            }
        } catch {
            map = [:]
        }
    }

    private func normalizeValue(_ v: Any) -> [String] {
        if let arr = v as? [String] { return arr }

        if let arr = v as? [Any] {
            var flat: [String] = []
            for item in arr {
                flat.append(contentsOf: normalizeValue(item))
            }
            return flat
        }

        if let dict = v as? [String: Any] {
            if let inner = dict["prereqs"] { return normalizeValue(inner) }
            if let inner = dict["prerequisites"] { return normalizeValue(inner) }
        }

        return []
    }

    /// Convert "CSCI 1200", "CSCI-1200", "csci1200" -> "CSCI-1200"
    private func normalizeCourseIDString(_ s: String) -> String {
        let upper = s.uppercased()

        let patterns = [
            #"([A-Z]{3,4})\s*[- ]\s*(\d{4})"#,
            #"([A-Z]{3,4})(\d{4})"#
        ]

        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: []) {
                let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
                if let m = re.firstMatch(in: upper, options: [], range: range),
                   m.numberOfRanges >= 3,
                   let r1 = Range(m.range(at: 1), in: upper),
                   let r2 = Range(m.range(at: 2), in: upper) {
                    let subj = String(upper[r1])
                    let num  = String(upper[r2])
                    return "\(subj)-\(num)"
                }
            }
        }

        return ""
    }
}
