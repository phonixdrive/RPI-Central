//  CourseCatalogService.swift
//  RPI Central

import Foundation

final class CourseCatalogService: ObservableObject {
    @Published var catalog: CourseCatalog?
    @Published var courses: [Course] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // File in your bundle: rpi_courses_202501.json
    private let filename = "rpi_courses_202509"

    init() {
        loadFromBundle()
    }

    func loadFromBundle() {
        isLoading = true
        errorMessage = nil

        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            isLoading = false
            errorMessage = "Missing \(filename).json in app bundle."
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()

            // This matches the { "term": "...", "courses": [...] } structure
            let catalog = try decoder.decode(CourseCatalog.self, from: data)

            let sorted = catalog.courses.sorted {
                if $0.subject == $1.subject {
                    return $0.number < $1.number
                }
                return $0.subject < $1.subject
            }

            self.catalog = catalog
            self.courses = sorted
            self.isLoading = false
        } catch {
            print("Decoding error:", error)
            isLoading = false
            errorMessage = "Failed to decode course catalog: \(error.localizedDescription)"
        }
    }
}
