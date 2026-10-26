import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
@MainActor
@Observable
final class WiskIOSSimplenoteImportController {
    var progress: ProgressState?
    var alert: AlertState?
    var confirmation: ConfirmationState?
    private var importTask: Task<Void, Never>?

    var isImporting: Bool { progress != nil }

    struct ProgressState: Equatable {
        var status: String
        var completed: Int
        var total: Int
    }

    struct AlertState: Equatable, Identifiable {
        var id = UUID()
        var title: String
        var message: String
    }

    struct ConfirmationState: Equatable, Identifiable {
        var id = UUID()
        var createCount: Int
        var updateCount: Int
        var unchangedCount: Int
        var url: URL
    }

    func beginImport(from url: URL, context: ModelContext, syncService: SyncService) {
        guard isImporting == false else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        progress = ProgressState(status: "Reading Simplenote export…", completed: 0, total: 0)
        importTask = Task {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let drafts = try SimplenoteLocalStore.loadActiveNotes(from: url)
                let existingNotes = WiskNoteFetch.allNotes(in: context)
                let classification = SimplenoteNoteImportService.classify(drafts, existingNotes: existingNotes)
                guard classification.hasWork else {
                    progress = nil
                    if drafts.isEmpty {
                        alert = AlertState(
                            title: "Nothing to import",
                            message: "Simplenote did not contain any active notes to import. Trashed notes are skipped."
                        )
                    } else {
                        alert = AlertState(
                            title: "Notes already match",
                            message: "\(classification.unchangedCount.formatted()) notes already matched and were skipped."
                        )
                    }
                    return
                }
                progress = nil
                confirmation = ConfirmationState(
                    createCount: classification.createCount,
                    updateCount: classification.updateCount,
                    unchangedCount: classification.unchangedCount,
                    url: url
                )
            } catch {
                progress = nil
                alert = AlertState(
                    title: "Couldn't import Simplenote notes",
                    message: error.localizedDescription
                )
            }
        }
    }

    func confirmImport(context: ModelContext, syncService: SyncService) {
        guard let confirmation else { return }
        let url = confirmation.url
        self.confirmation = nil
        let accessed = url.startAccessingSecurityScopedResource()
        progress = ProgressState(status: "Importing notes from Simplenote…", completed: 0, total: 0)
        importTask = Task {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let drafts = try SimplenoteLocalStore.loadActiveNotes(from: url)
                let existingNotes = WiskNoteFetch.allNotes(in: context)
                let classification = SimplenoteNoteImportService.classify(drafts, existingNotes: existingNotes)
                try await importClassification(classification, context: context, syncService: syncService)
            } catch is CancellationError {
                progress = nil
            } catch {
                progress = nil
                alert = AlertState(
                    title: "Couldn't import Simplenote notes",
                    message: error.localizedDescription
                )
            }
        }
    }

    func cancel() {
        importTask?.cancel()
        importTask = nil
        progress = nil
        confirmation = nil
    }

    func undoLastImport(context: ModelContext, syncService: SyncService) {
        guard isImporting == false else { return }
        let batch = SimplenoteNoteImportService.lastImportBatch()
        guard batch.isEmpty == false else {
            alert = AlertState(
                title: "Nothing to undo",
                message: "There is no Simplenote import batch to move to Archived."
            )
            return
        }
        let notes = WiskNoteFetch.notes(ids: Set(batch.map(\.noteID)), in: context)
        for note in notes {
            note.archivedAt = Date()
            note.deletedAt = nil
            note.updatedAt = Date()
            NoteLibraryIndex.updateListFlags(note, in: context)
        }
        SimplenoteNoteImportService.forgetLastImport()
        try? context.save()
        syncService.enqueue(notes: notes, context: context)
        alert = AlertState(
            title: "Import undone",
            message: "Moved \(notes.count.formatted()) imported notes to Archive."
        )
    }

    private func importClassification(
        _ classification: SimplenoteNoteImportService.Classification,
        context: ModelContext,
        syncService: SyncService
    ) async throws {
        let total = classification.createCount + classification.updateCount
        progress = ProgressState(status: "Importing notes from Simplenote…", completed: 0, total: total)

        var created: [SimplenoteNoteImportService.BatchItem] = []
        var updated: [SimplenoteNoteImportService.BatchItem] = []
        var queuedNotes: [Note] = []
        let existingNotes = WiskNoteFetch.allNotes(in: context)
        let notesByID = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0) })
        var completed = 0

        for draft in classification.toCreate {
            try Task.checkCancellation()
            let note = SimplenoteNoteImportService.makeNote(from: draft)
            context.insert(note)
            queuedNotes.append(note)
            created.append(.init(sourceID: draft.sourceID, noteID: note.id))
            completed += 1
            if completed == total || completed % 25 == 0 {
                progress = ProgressState(
                    status: "Importing notes from Simplenote…",
                    completed: completed,
                    total: total
                )
                await Task.yield()
            }
        }

        for item in classification.toUpdate {
            try Task.checkCancellation()
            guard let note = notesByID[item.noteID] else {
                completed += 1
                continue
            }
            let split = SimplenoteNoteImportService.splitTitleAndBody(item.draft.content)
            if note.title != split.title || note.body != split.body {
                note.snapshotIfNeeded(reason: "simplenote-import")
            }
            if SimplenoteNoteImportService.apply(item.draft, onto: note) {
                queuedNotes.append(note)
                updated.append(.init(sourceID: item.draft.sourceID, noteID: note.id))
            }
            completed += 1
            if completed == total || completed % 25 == 0 {
                progress = ProgressState(
                    status: "Importing notes from Simplenote…",
                    completed: completed,
                    total: total
                )
                await Task.yield()
            }
        }

        try context.save()
        for note in queuedNotes {
            NoteLibraryIndex.upsert(note, in: context)
        }
        try? context.save()
        SimplenoteNoteImportService.recordImport(created: created, updated: updated)
        syncService.enqueue(notes: queuedNotes, context: context)

        progress = ProgressState(status: "Syncing imported notes…", completed: total, total: total)
        await syncService.syncNow(context: context)
        progress = nil
        alert = AlertState(
            title: "Import complete",
            message: importSuccessMessage(
                created: created.count,
                updated: updated.count,
                unchanged: classification.unchangedCount
            )
        )
    }

    private func importSuccessMessage(created: Int, updated: Int, unchanged: Int) -> String {
        var parts: [String] = []
        if created > 0 {
            parts.append("Added \(created.formatted()) notes")
        }
        if updated > 0 {
            parts.append("updated \(updated.formatted())")
        }
        var message = parts.isEmpty ? "No notes changed." : parts.joined(separator: ", ") + "."
        if unchanged > 0 {
            message += " \(unchanged.formatted()) already matched and were skipped."
        }
        message += " Undo moves the new notes to Archive."
        return message
    }
}

struct WiskIOSSimplenoteImportOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let progress: WiskIOSSimplenoteImportController.ProgressState
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.4 : 0.28)
                .ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(.accent)
                        .frame(width: 220)
                } else {
                    ProgressView()
                        .tint(.accent)
                }
                Text(progress.status)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
                if progress.total > 0 {
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", action: onCancel)
            }
            .padding(Spacing.xl)
            .frame(minWidth: 280)
            .wiskGlassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: Radius.glassOverlay, style: .continuous)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.status)
    }
}
#endif
