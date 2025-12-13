// CourseCatalogService.swift

import Foundation

final class CourseCatalogService: ObservableObject {
    static let shared = CourseCatalogService()

    @Published private(set) var courses: [Course] = []
    @Published var semester: Semester = .spring2025 {
        didSet { loadCourses(for: semester) }
    }

    private init() {
        loadCourses(for: semester)
    }

    private func loadCourses(for semester: Semester) {
        let filename = semester.jsonFileName

        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            print("❌ Could not find \(filename).json in bundle")
            courses = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()

            struct CourseCatalog: Decodable {
                let courses: [Course]
            }

            let catalog = try decoder.decode(CourseCatalog.self, from: data)
            DispatchQueue.main.async {
                self.courses = catalog.courses
            }
        } catch {
            print("❌ Failed to decode course catalog:", error)
            courses = []
        }
    }
}
