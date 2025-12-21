//
//  PrereqStore.swift
//  RPI Central
//

import Foundation

/// Loads `prereq_graph.json` if it exists in your app bundle.
/// Works even if the JSON shape changes, because we normalize with JSONSerialization.
final class PrereqStore {
    static let shared = PrereqStore()
    private init() { load() }

    private var map: [String: [String]] = [:]   // "MATH-2010" -> ["MATH-1010", "PHYS-1100"]

    func prereqIDs(for courseID: String) -> [String] {
        // courseID is like "MATH-2010"
        map[courseID] ?? []
    }

    private func load() {
        // Try a couple common bundle locations
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json"),
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json", subdirectory: "quacs-data-master"),
            Bundle.main.url(forResource: "prereq_graph", withExtension: "json", subdirectory: "Data/quacs-data-master")
        ]

        guard let url = candidates.compactMap({ $0 }).first else {
            map = [:]
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: data, options: [])

            // Expected common shapes:
            // 1) { "MATH-2010": ["MATH-1010","MATH-1020"] }
            // 2) { "MATH-2010": { "prereqs": ["MATH-1010"] } }
            // 3) { "MATH-2010": [["MATH-1010"],["PHYS-1100"]] }  -> flatten strings
            if let dict = obj as? [String: Any] {
                var out: [String: [String]] = [:]
                for (k, v) in dict {
                    out[k] = normalizeValue(v)
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
        // ["MATH-1010","MATH-1020"]
        if let arr = v as? [String] { return arr }

        // [["MATH-1010"],["PHYS-1100"]] or mixed
        if let arr = v as? [Any] {
            var flat: [String] = []
            for item in arr {
                flat.append(contentsOf: normalizeValue(item))
            }
            return Array(Set(flat)).sorted()
        }

        // { "prereqs": [...] }
        if let dict = v as? [String: Any] {
            if let inner = dict["prereqs"] {
                return normalizeValue(inner)
            }
        }

        return []
    }
}
