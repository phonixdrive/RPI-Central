import SwiftUI

struct GroupHubPresentation: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let memberNames: [String]
    let reference: SocialGroupChatReference
    let courseCommunity: SocialCourseCommunity?
}

struct GroupHubSheet: View {
    let presentation: GroupHubPresentation

    @EnvironmentObject private var socialManager: SocialManager
    @EnvironmentObject private var calendarViewModel: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: GroupHubField?

    @State private var resources: [SocialCourseResource] = []
    @State private var isLoading = false
    @State private var showResourceComposer = false

    @State private var resourceKind = "Syllabus"
    @State private var resourceTitle = ""
    @State private var resourceURL = ""
    @State private var resourceNotes = ""

    private let resourceKinds = ["Syllabus", "Office Hours", "TA Hours", "Exam Dates", "Discord", "Study Guide", "Other"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    membersCard

                    if presentation.courseCommunity != nil {
                        resourcesCard
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground),
                        calendarViewModel.themeColor.opacity(0.14),
                        Color(.systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .task(id: presentation.id) {
                await refreshContent()
            }
        }
    }

    private var membersCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.title)
                            .font(.headline)
                        Text(presentation.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    badge("Hub")
                }

                if !presentation.memberNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(presentation.memberNames.enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(calendarViewModel.themeColor.opacity(0.12))
                                    )
                            }
                        }
                    }
                }
            }
        }
    }

    private var resourcesCard: some View {
        SocialCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pinned Resources")
                            .font(.headline)
                        Text("Keep the syllabus, office hours, Discord links, and exam dates in one place.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(showResourceComposer ? "Hide" : "Add") {
                        showResourceComposer.toggle()
                    }
                    .buttonStyle(.bordered)
                }

                if showResourceComposer {
                    resourceComposer
                }

                if isLoading && resources.isEmpty {
                    ProgressView("Loading resources...")
                } else if resources.isEmpty {
                    emptyState("No resources yet.", systemImage: "pin")
                } else {
                    VStack(spacing: 10) {
                        ForEach(resources) { resource in
                            resourceCard(resource)
                        }
                    }
                }
            }
        }
    }

    private var resourceComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: $resourceKind) {
                ForEach(resourceKinds, id: \.self) { kind in
                    Text(kind).tag(kind)
                }
            }
            .pickerStyle(.menu)

            TextField("Title", text: $resourceTitle)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .resourceTitle)

            TextField("Link (optional)", text: $resourceURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .resourceURL)

            TextField("Notes (optional)", text: $resourceNotes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($focusedField, equals: .resourceNotes)

            HStack {
                Spacer()
                Button("Save Resource") {
                    Task {
                        await saveResource()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(resourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func resourceCard(_ resource: SocialCourseResource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(resource.title)
                        .font(.subheadline.weight(.semibold))
                    Text(resource.createdByDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                badge(resource.kind)
            }

            if let url = normalizedURL(resource.url) {
                Link(destination: url) {
                    Label(url.absoluteString, systemImage: "link")
                        .font(.caption)
                }
            }

            if !resource.notes.isEmpty {
                Text(resource.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if socialManager.canDeleteCourseResource(resource) {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        Task {
                            _ = await socialManager.deleteCourseResource(resource)
                            await refreshResources()
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func emptyState(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(calendarViewModel.themeColor)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(calendarViewModel.themeColor.opacity(0.12))
            )
            .foregroundStyle(calendarViewModel.themeColor)
    }

    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private func refreshContent() async {
        isLoading = true
        await refreshResources()
        isLoading = false
    }

    private func refreshResources() async {
        guard let community = presentation.courseCommunity else {
            resources = []
            return
        }
        resources = await socialManager.loadCourseResources(for: community)
    }

    private func saveResource() async {
        guard let community = presentation.courseCommunity else { return }
        let didSave = await socialManager.addCourseResource(
            to: community,
            kind: resourceKind,
            title: resourceTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            url: resourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: resourceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard didSave else { return }

        resourceTitle = ""
        resourceURL = ""
        resourceNotes = ""
        focusedField = nil
        showResourceComposer = false
        await refreshResources()
    }
}

private enum GroupHubField: Hashable {
    case resourceTitle
    case resourceURL
    case resourceNotes
}
