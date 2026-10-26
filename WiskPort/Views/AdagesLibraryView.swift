import SwiftData
import SwiftUI

struct AdagesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Query(filter: #Predicate<Adage> { $0.deletedAt == nil }, sort: \Adage.createdAt, order: .reverse)
    private var adages: [Adage]

    @Binding var selectedAdageID: UUID?
    var pushesDetail: Bool

    private var groups: [AdageLibrary.Group] {
        AdageLibrary.grouped(adages.map {
            AdageLibrary.Summary(
                id: $0.id,
                collectionName: $0.collectionName,
                title: $0.title,
                body: $0.body,
                createdAt: $0.createdAt
            )
        })
    }

    var body: some View {
        Group {
            if pushesDetail {
                List {
                    listContent
                }
            } else {
                List(selection: $selectedAdageID) {
                    listContent
                }
            }
        }
        .accessibilityIdentifier("wisk.adages.list")
        .navigationTitle("Adages")
    }

    @ViewBuilder
    private var listContent: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No Adages",
                systemImage: "text.quote",
                description: Text("Add an adage mapping in Settings, then use Route on a note.")
            )
        } else {
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.adages) { summary in
                        if pushesDetail, let adage = adage(id: summary.id) {
                            NavigationLink {
                                AdageDetailView(adage: adage)
                            } label: {
                                row(summary)
                            }
                        } else {
                            row(summary)
                                .tag(Optional(summary.id))
                        }
                    }
                }
            }
        }
    }

    private func row(_ summary: AdageLibrary.Summary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline(summary))
                .lineLimit(2)
            if summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text(summary.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                delete(id: summary.id)
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                delete(id: summary.id)
            }
        }
    }

    private func headline(_ summary: AdageLibrary.Summary) -> String {
        summary.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? summary.body
    }

    private func adage(id: UUID) -> Adage? {
        adages.first { $0.id == id }
    }

    private func delete(id: UUID) {
        guard let adage = adage(id: id) else { return }
        adage.deletedAt = Date()
        adage.updatedAt = Date()
        if selectedAdageID == id {
            selectedAdageID = nil
        }
        try? modelContext.save()
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }
}

struct AdageDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService

    @Bindable var adage: Adage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(adage.collectionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if adage.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Text(adage.title)
                        .font(.title2.weight(.semibold))
                }
                Text(adage.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(adage.title.nilIfBlank ?? "Adage")
        .toolbar {
            Button("Delete", role: .destructive) {
                adage.deletedAt = Date()
                adage.updatedAt = Date()
                try? modelContext.save()
                Task {
                    await syncService.syncNow(context: modelContext)
                }
            }
            .accessibilityIdentifier("wisk.adages.delete")
        }
    }
}

struct AdageSelectionDetail: View {
    @Query(filter: #Predicate<Adage> { $0.deletedAt == nil }, sort: \Adage.createdAt, order: .reverse)
    private var adages: [Adage]

    var selectedAdageID: UUID?

    var body: some View {
        if let adage = adages.first(where: { $0.id == selectedAdageID }) {
            AdageDetailView(adage: adage)
        } else {
            ContentUnavailableView(
                "Adages",
                systemImage: "text.quote",
                description: Text("Choose an adage, or route a prefixed line from a note.")
            )
        }
    }
}

struct AdagesLibraryView: View {
    @State private var selectedAdageID: UUID?

    var body: some View {
        AdagesListView(selectedAdageID: $selectedAdageID, pushesDetail: true)
    }
}
