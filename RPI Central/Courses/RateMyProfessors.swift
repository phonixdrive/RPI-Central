//
//  RateMyProfessors.swift
//  RPI Central
//
//  Opens Rate My Professors inside the app, already searching RPI for the
//  instructor. When the student lands on a professor page they can save it,
//  and every class taught by that instructor links straight to it afterwards.
//  (RMP has no public API, so the app shows their site rather than copying
//  their data.)
//

import SwiftUI
import WebKit

enum RateMyProfessors {
    /// Rensselaer Polytechnic Institute's school ID on ratemyprofessors.com.
    static let rpiSchoolID = 795

    static func searchURL(for instructor: String) -> URL? {
        var components = URLComponents(string: "https://www.ratemyprofessors.com/search/professors/\(rpiSchoolID)")
        components?.queryItems = [URLQueryItem(name: "q", value: searchName(for: instructor))]
        return components?.url
    }

    /// "First Last", with middle initials dropped ("Shianne M. Hulbert" →
    /// "Shianne Hulbert"), which is how RMP lists most professors.
    static func searchName(for instructor: String) -> String {
        let parts = instructor
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .filter { !($0.count <= 2 && $0.hasSuffix(".")) }
        guard parts.count > 2 else { return parts.joined(separator: " ") }
        return "\(parts.first!) \(parts.last!)"
    }

    /// The catalog lists co-instructors as "First Last, First Last".
    static func instructors(from raw: String) -> [String] {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !["TBA", "STAFF", "TBD"].contains(cleaned.uppercased()) else { return [] }
        let separators = CharacterSet(charactersIn: ",;/&")
        return cleaned
            .components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !["TBA", "STAFF", "TBD"].contains($0.uppercased()) }
            .reduce(into: [String]()) { names, name in
                if !names.contains(name) { names.append(name) }
            }
    }

    /// `https://www.ratemyprofessors.com/professor/12345` pages only.
    static func isProfessorPage(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(), host.hasSuffix("ratemyprofessors.com") else { return false }
        return url.path.range(of: #"^/professor/\d+/?$"#, options: .regularExpression) != nil
    }

    static func normalizedProfessorURL(_ url: URL) -> URL? {
        guard isProfessorPage(url), let id = url.path.split(separator: "/").last else { return nil }
        return URL(string: "https://www.ratemyprofessors.com/professor/\(id)")
    }
}

/// Saved professor pages, keyed by instructor name as it appears in the catalog.
final class ProfessorLinkStore: ObservableObject {
    static let shared = ProfessorLinkStore()
    private static let key = "rmp_professor_links_v1"

    @Published private(set) var links: [String: URL]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        links = raw.compactMapValues(URL.init(string:))
    }

    func link(for instructor: String) -> URL? {
        links[Self.normalizedName(instructor)]
    }

    func setLink(_ url: URL?, for instructor: String) {
        links[Self.normalizedName(instructor)] = url
        UserDefaults.standard.set(links.mapValues(\.absoluteString), forKey: Self.key)
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").sorted().joined(separator: " ")
    }
}

// MARK: - Views

struct ProfessorRatingRow: View {
    let instructor: String
    let accent: Color

    @ObservedObject private var store = ProfessorLinkStore.shared
    @State private var browserURL: IdentifiableURL?
    @State private var showPasteLink = false
    @State private var pastedLink = ""

    var body: some View {
        let saved = store.link(for: instructor)

        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(RateMyProfessors.searchName(for: instructor))
                    .font(.body.weight(.semibold))
                Text(saved == nil ? "Not matched on Rate My Professors" : "Rate My Professors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                if let saved {
                    Button("Open Profile", systemImage: "star.bubble") { browserURL = IdentifiableURL(url: saved) }
                    Button("Search Again", systemImage: "magnifyingglass") { openSearch() }
                    Button("Unlink", systemImage: "link.badge.minus", role: .destructive) {
                        store.setLink(nil, for: instructor)
                    }
                } else {
                    Button("Find on Rate My Professors", systemImage: "magnifyingglass") { openSearch() }
                    Button("Paste Profile Link", systemImage: "link") { showPasteLink = true }
                }
            } label: {
                Text(saved == nil ? "Find" : "View")
                    .font(.subheadline.weight(.semibold))
            } primaryAction: {
                if let saved { browserURL = IdentifiableURL(url: saved) } else { openSearch() }
            }
            .buttonStyle(.bordered)
            .tint(accent)
        }
        .sheet(item: $browserURL) { item in
            ProfessorBrowser(startURL: item.url, instructor: instructor)
        }
        .alert("Rate My Professors Link", isPresented: $showPasteLink) {
            TextField("ratemyprofessors.com/professor/…", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Save") {
                var text = pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.lowercased().hasPrefix("http") { text = "https://" + text }
                if let url = URL(string: text).flatMap(RateMyProfessors.normalizedProfessorURL) {
                    store.setLink(url, for: instructor)
                }
                pastedLink = ""
            }
            Button("Cancel", role: .cancel) { pastedLink = "" }
        } message: {
            Text("Paste the link to this professor’s page.")
        }
    }

    private func openSearch() {
        if let url = RateMyProfessors.searchURL(for: instructor) {
            browserURL = IdentifiableURL(url: url)
        }
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A small in-app browser that offers to save the professor page it lands on.
struct ProfessorBrowser: View {
    let startURL: URL
    let instructor: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ProfessorLinkStore.shared
    @State private var currentURL: URL?
    @State private var isLoading = true

    var body: some View {
        let professorURL = currentURL.flatMap(RateMyProfessors.normalizedProfessorURL)
        let isSaved = professorURL != nil && professorURL == store.link(for: instructor)

        NavigationStack {
            WebView(url: startURL, currentURL: $currentURL, isLoading: $isLoading)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if isLoading { ProgressView().padding(.top, 8) }
                }
                .safeAreaInset(edge: .bottom) {
                    if let professorURL, !isSaved {
                        Button {
                            store.setLink(professorURL, for: instructor)
                        } label: {
                            Label("Use for \(RateMyProfessors.searchName(for: instructor))", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding()
                        .background(.bar)
                    } else if isSaved {
                        Label("Saved to your classes", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.bar)
                    }
                }
                .navigationTitle("Rate My Professors")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if let currentURL {
                            ShareLink(item: currentURL)
                        }
                    }
                }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var currentURL: URL?
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observation = webView.observe(\.url, options: [.new]) { view, _ in
            DispatchQueue.main.async { self.currentURL = view.url }
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        var observation: NSKeyValueObservation?

        init(_ parent: WebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
