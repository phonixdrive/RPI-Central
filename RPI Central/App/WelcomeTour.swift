//
//  WelcomeTour.swift
//  RPI Central
//
//  A short, skippable tour shown once on first launch. It can be replayed
//  from Settings → About.
//

import SwiftUI

enum WelcomeTour {
    static let seenKey = "welcome_tour_seen_v1"

    /// Debug builds launched for screenshots skip it with RPI_SKIP_TOUR=1.
    static var shouldShowOnLaunch: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RPI_SKIP_TOUR"] == "1" { return false }
        #endif
        return !UserDefaults.standard.bool(forKey: seenKey)
    }
}

struct WelcomeTourView: View {
    let accent: Color
    /// Called with the tab to open, if the last page's button asks for one.
    let onFinish: (_ openCourses: Bool) -> Void

    @State private var page = 0

    private struct Page {
        let symbol: String
        let colors: [Color]
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(symbol: "graduationcap.fill", colors: [.blue, .indigo],
             title: "Welcome to RPI Central",
             body: "Your classes, deadlines, and friends in one place. Here’s a 30-second tour."),
        Page(symbol: "book.fill", colors: [.indigo, .purple],
             title: "Add your classes",
             body: "Search any course in the Courses tab and add your sections. Conflicts are flagged before you add."),
        Page(symbol: "rectangle.stack.fill", colors: [.teal, .blue],
             title: "Every class has a page",
             body: "Tap a class on the calendar or Home for directions, class chat, tasks, your grade, ratings, and notes."),
        Page(symbol: "doc.text.magnifyingglass", colors: [.orange, .pink],
             title: "Import your syllabus",
             body: "On a class page, tap + and choose Import Syllabus Dates. Pick a PDF or scan the paper, and review every date before it’s added."),
        Page(symbol: "apps.iphone", colors: [.green, .teal],
             title: "Widgets and Apple Watch",
             body: "Add RPI Central widgets to your Home Screen and Lock Screen, and see what’s next on your wrist."),
        Page(symbol: "person.2.fill", colors: [.pink, .orange],
             title: "Friends, when you want them",
             body: "Chat, make plans, and share your location only if you choose. Ghost Mode hides you anytime."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish(openCourses: false) }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .opacity(page == pages.count - 1 ? 0 : 1)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: page)

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? accent : Color.secondary.opacity(0.3))
                        .frame(width: index == page ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: page)
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                if page < pages.count - 1 {
                    Button {
                        page += 1
                    } label: {
                        Text(page == 0 ? "Show Me Around" : "Next")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(accent)
                } else {
                    Button {
                        finish(openCourses: true)
                    } label: {
                        Text("Add My Classes")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(accent)

                    Button("Start Exploring") { finish(openCourses: false) }
                        .font(.body.weight(.semibold))
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Color(.systemBackground))
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: page.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 168, height: 168)
                    .shadow(color: page.colors.first?.opacity(0.35) ?? .clear, radius: 24, y: 10)
                Image(systemName: page.symbol)
                    .font(.system(size: 68, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
    }

    private func finish(openCourses: Bool) {
        UserDefaults.standard.set(true, forKey: WelcomeTour.seenKey)
        onFinish(openCourses)
    }
}
