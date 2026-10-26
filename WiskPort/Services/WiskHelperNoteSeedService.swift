import Foundation
import SwiftData

/// Bear-style helper notes inserted once for brand-new accounts.
///
/// Production has no onboarding flow: first launch is `AuthGateView` then a Firestore
/// pull, and an empty library shows a generic "create a note" empty state. These
/// seeded notes give new users something to read, keep, or delete — the same role
/// Bear's welcome notes play.
@MainActor
enum WiskHelperNoteSeedService {
    static let helpTag = "wisk-help"

    private static let seededKeyPrefix = "wisk.onboarding.helperNotesSeeded."

    struct HelperNote: Sendable {
        let title: String
        let body: String
        let pinned: Bool
    }

    static var helperNotes: [HelperNote] {
        [
            HelperNote(
                title: "Welcome to Wisk",
                body: """
                This is Wisk — capture fast, organize with AI, and find everything later.

                These helper notes explain the basics. Keep them, edit them, or delete them anytime.

                - Write in **Notes**, triage suggestions in **Buckets**
                - Everything syncs across iPhone and Mac when signed in
                - Start a new note with ⌘N (Mac) or the compose button (iPhone)

                Next: read "Capture with tags" to learn the fastest way to stay organized.
                """,
                pinned: true
            ),
            HelperNote(
                title: "Capture with tags",
                body: """
                Tags and projects keep notes findable without folders.

                - Add a tag anywhere in a note with #tag, for example #groceries
                - Add a project with +project, for example +kitchen-reno
                - Search matches titles, bodies, tags, and projects
                - Try `tag:groceries` in search to filter by tag

                Edit this note and add a #tag of your own to see it work.
                """,
                pinned: false
            ),
            HelperNote(
                title: "Organize with AI and Buckets",
                body: """
                Wisk Pro turns messy notes into tasks, reminders, and review buckets.

                - Open a note and tap Organize (or Review with Wisk) to extract tasks
                - Buckets collect suggestions — accept what matters, ignore the rest
                - Route lines to Todoist from Settings > Routing
                - Background organize keeps recent notes tidy automatically

                Writing is free. AI organization, review buckets, and sharing are Wisk Pro.
                """,
                pinned: false
            ),
            HelperNote(
                title: "Sync and restore",
                body: """
                Your library syncs through your Wisk account.

                - Sign in on iPhone and Mac to keep notes in sync
                - Deleted notes soft-delete first and sync the deletion
                - Wisk keeps local backups on Mac if you ever need to restore

                Delete this note when you are done — your own notes are the best onboarding.
                """,
                pinned: false
            ),
        ]
    }

    static func seededKey(for uid: String?) -> String {
        guard let uid, !uid.isEmpty else { return seededKeyPrefix + "local" }
        return seededKeyPrefix + uid
    }

    static func hasSeeded(uid: String?, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seededKey(for: uid))
    }

    /// Seeds helper notes for true new accounts only. Call after the first `syncNow`
    /// on a signed-in launch: if the account already synced before (`hadCompletedSync`)
    /// or the library is non-empty, marks seeded and returns 0.
    @discardableResult
    static func seedIfNeeded(
        context: ModelContext,
        syncService: SyncService,
        uid: String?,
        hadCompletedSync: Bool,
        defaults: UserDefaults = .standard
    ) -> Int {
        if WiskDebugSyncHarness.isActive { return 0 }
        let key = seededKey(for: uid)
        guard defaults.bool(forKey: key) == false else { return 0 }
        // Returning accounts (existing watermark) never get helpers re-injected,
        // even if they deleted every note.
        if hadCompletedSync {
            defaults.set(true, forKey: key)
            return 0
        }
        guard visibleNoteCount(in: context) == 0 else {
            defaults.set(true, forKey: key)
            return 0
        }
        let inserted = insertMissingHelpers(context: context, syncService: syncService)
        defaults.set(true, forKey: key)
        return inserted
    }

    /// Re-inserts any missing helper notes regardless of the seeded flag.
    /// Used by the Settings "Restore welcome notes" row.
    @discardableResult
    static func restoreMissingHelpers(
        context: ModelContext,
        syncService: SyncService,
        uid: String?
    ) -> Int {
        if WiskDebugSyncHarness.isActive { return 0 }
        let inserted = insertMissingHelpers(context: context, syncService: syncService)
        if inserted > 0 {
            UserDefaults.standard.set(true, forKey: seededKey(for: uid))
        }
        return inserted
    }

    // MARK: - Private

    private static func visibleNoteCount(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil })
        descriptor.fetchLimit = 1
        // Fetch one row; empty vs non-empty is all the caller needs.
        return (try? context.fetch(descriptor).count) ?? 1
    }

    @discardableResult
    private static func insertMissingHelpers(
        context: ModelContext,
        syncService: SyncService
    ) -> Int {
        let existingTitles = Set(
            (try? context.fetch(FetchDescriptor<Note>()))?.map(\.title) ?? []
        )
        var inserted = 0
        for helper in helperNotes where !existingTitles.contains(helper.title) {
            let note = Note(title: helper.title, body: helper.body, kind: .general)
            note.pinned = helper.pinned
            note.markdownEnabled = true
            note.addTagIfNeeded(helpTag)
            note.snapshotIfNeeded(reason: "onboarding")
            context.insert(note)
            NoteLibraryIndex.upsert(note, in: context)
            syncService.enqueue(note: note, context: context)
            inserted += 1
        }
        if inserted > 0 {
            try? context.save()
        }
        return inserted
    }
}
