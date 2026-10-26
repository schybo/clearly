import Foundation
import Observation
import SwiftData

/// In-memory title/body for the open editor. The owning view should pass this
/// object into a child that reads `body`, so keystrokes do not invalidate the
/// surrounding chrome.
@Observable
@MainActor
final class WiskEditorDraft {
    var noteID: UUID?
    var title: String = ""
    var body: String = ""

    func load(from note: Note) {
        noteID = note.id
        title = note.title
        body = note.body
    }

    func copy(from note: Note) {
        load(from: note)
    }
}

struct WiskEditorNoteIdentity: Equatable {
    var id: UUID
    var markdownEnabled: Bool
}

enum WiskEditorLifecycle {
    static func shouldScheduleIdlePersist(
        draftNoteID: UUID?,
        boundNoteID: UUID,
        draftValue: String,
        noteValue: String
    ) -> Bool {
        draftNoteID == boundNoteID && draftValue != noteValue
    }

    static func shouldMarkNeedsCommit(
        draftNoteID: UUID?,
        boundNoteID: UUID,
        draftTitle: String,
        draftBody: String,
        noteTitle: String,
        noteBody: String
    ) -> Bool {
        draftNoteID == boundNoteID && (draftTitle != noteTitle || draftBody != noteBody)
    }

    static func shouldScheduleDetachedLeaveCommit(deletedAt: Date?) -> Bool {
        deletedAt == nil
    }

    static func shouldCommitLeavingEditor(
        draftNoteID: UUID?,
        targetID: UUID,
        needsCommit: Bool,
        hadPendingAutosave: Bool,
        draftTitle: String,
        draftBody: String,
        targetTitle: String,
        targetBody: String
    ) -> Bool {
        guard draftNoteID == targetID else { return false }
        if needsCommit || hadPendingAutosave {
            return true
        }
        return draftTitle != targetTitle || draftBody != targetBody
    }

    static func isUserMarkdownToggle(previousNoteID: UUID, currentNoteID: UUID) -> Bool {
        previousNoteID == currentNoteID
    }

    /// Draft identity updates one frame after `note.id`. Until they match, show
    /// the note title/body so the editor opens the real source instead of the previous note.
    static func displayedBody(
        draftNoteID: UUID?,
        draftBody: String,
        noteID: UUID,
        noteBody: String
    ) -> String {
        displayedField(draftNoteID: draftNoteID, draftValue: draftBody, noteID: noteID, noteValue: noteBody)
    }

    /// Drop a leftover caret from the previous note until the draft identity matches.
    /// `Range<String.Index>` must not be converted against a different `String`.
    static func displayedSelection<R>(
        draftNoteID: UUID?,
        draftSelection: R?,
        noteID: UUID
    ) -> R? {
        draftNoteID == noteID ? draftSelection : nil
    }

    static func displayedTitle(
        draftNoteID: UUID?,
        draftTitle: String,
        noteID: UUID,
        noteTitle: String,
        libraryTitle: String? = nil
    ) -> String {
        if draftNoteID == noteID {
            return draftTitle
        }
        if noteTitle.isEmpty == false {
            return noteTitle
        }
        return libraryTitle ?? noteTitle
    }

    static func displayedField(
        draftNoteID: UUID?,
        draftValue: String,
        noteID: UUID,
        noteValue: String
    ) -> String {
        draftNoteID == noteID ? draftValue : noteValue
    }
}

/// Snapshot of the editor draft for the note being left, captured before the
/// new note is loaded so persist can happen after first paint.
struct WiskEditorLeavingDraft: Equatable {
    var draftNoteID: UUID?
    var draftTitle: String
    var draftBody: String
    var needsCommit: Bool
    var hadPendingAutosave: Bool
    var targetTitle: String
    var targetBody: String
}

enum WiskEditorPersistKind: Sendable {
    /// Write title/body for crash safety. Does not bump `updatedAt`, snapshot,
    /// enqueue, or start a Firestore round-trip.
    case idle
    /// Queue a syncable revision: `updatedAt`, snapshot, and enqueue. Callers
    /// must not `syncNow` on the typing path.
    case commit
}

enum WiskEditorPersist {
    static func stampDraft(title: String, body: String, onto note: Note) {
        if note.title != title {
            note.title = title
        }
        if note.body != body {
            note.body = body
        }
    }

    @MainActor
    static func apply(
        title: String,
        body: String,
        to note: Note,
        kind: WiskEditorPersistKind,
        snapshotReason: String = "edit",
        snapshot: Bool = true,
        syncService: SyncService? = nil,
        context: ModelContext
    ) {
        // Compare before stamping: `.idle` fires on editor lifecycle events
        // (blur, note switches) even when the draft is identical to the note.
        // Flipping a synced note to `.local` unconditionally made the repair
        // pass re-queue and re-push it every sync tick — bumping `syncRevision`
        // while `updatedAt` stayed frozen — and remote pulls keyed on
        // `updatedAt > watermark` then never re-fetched the note on other
        // devices. Only content that actually changed may go stale-local.
        let contentChanged = note.title != title || note.body != body
        stampDraft(title: title, body: body, onto: note)

        switch kind {
        case .idle:
            if contentChanged, note.syncStatus == .synced {
                note.syncStatus = .local
            }
            NoteLibraryIndex.upsert(note, in: context)
            try? context.save()
        case .commit:
            note.updatedAt = Date()
            note.syncStatus = .queued
            if snapshot {
                note.snapshotIfNeeded(reason: snapshotReason)
            }
            NoteLibraryIndex.upsert(note, in: context)
            if let syncService {
                syncService.enqueue(note: note, context: context)
            } else {
                try? context.save()
            }
        }
    }

    static func commitDetached(
        noteID: UUID,
        title: String,
        body: String,
        snapshotReason: String = "edit",
        snapshot: Bool = true,
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let note = WiskNoteFetch.note(id: noteID, in: context) else { return }
        stampDraft(title: title, body: body, onto: note)
        note.updatedAt = Date()
        note.syncStatus = .queued
        if snapshot {
            note.snapshotIfNeeded(reason: snapshotReason)
        }
        NoteLibraryIndex.upsert(note, in: context)
        try SyncMutationWriter.enqueue(note: note, context: context)
    }

    @MainActor
    static func scheduleDetachedCommit(
        noteID: UUID,
        title: String,
        body: String,
        container: ModelContainer,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        Task {
            do {
                try await Task.detached {
                    try commitDetached(
                        noteID: noteID,
                        title: title,
                        body: body,
                        container: container
                    )
                }.value
            } catch {
                onFailure(error.localizedDescription)
            }
        }
    }
}

/// Coalesces editor persists so typing does not write SwiftData, versions, or
/// Firestore on every keystroke.
@MainActor
final class WiskEditorAutosave {
    static let defaultDelay: Duration = .seconds(2)
    static let searchDebounceDelay: Duration = .milliseconds(150)

    private var task: Task<Void, Never>?
    private var pending: (@MainActor () -> Void)?

    var hasPending: Bool { pending != nil }

    func schedule(delay: Duration = defaultDelay, persist: @escaping @MainActor () -> Void) {
        pending = persist
        task?.cancel()
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        let persist = pending
        pending = nil
        persist?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
