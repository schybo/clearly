import Foundation
import SwiftData

enum NoteLibraryIndex {
    static let tagSeparator: Character = "\u{1F}"
    static let searchTextLimit = 32_000

    static func upsert(_ note: Note, in context: ModelContext) {
        let record = record(for: note.id, in: context)
        apply(note, to: record)
    }

    /// Updates a preloaded library row, or inserts one, without a per-note fetch.
    static func upsert(
        _ note: Note,
        into recordsByNoteID: inout [UUID: NoteLibraryRecord],
        context: ModelContext
    ) {
        let record: NoteLibraryRecord
        if let existing = recordsByNoteID[note.id] {
            record = existing
        } else {
            record = NoteLibraryRecord(noteID: note.id)
            context.insert(record)
            recordsByNoteID[note.id] = record
        }
        apply(note, to: record)
    }

    /// Copies list flags without rebuilding `searchText` or excerpts.
    static func updateListFlags(_ note: Note, in context: ModelContext) {
        guard let record = existingRecord(for: note.id, in: context) else {
            upsert(note, in: context)
            return
        }
        record.deletedAt = note.deletedAt
        record.archivedAt = note.archivedAt
        record.updatedAt = note.updatedAt
        record.pinned = note.pinned
    }

    static func excludingPendingHidden(
        _ records: [NoteLibraryRecord],
        pendingIDs: Set<UUID>
    ) -> [NoteLibraryRecord] {
        guard pendingIDs.isEmpty == false else { return records }
        return records.filter { pendingIDs.contains($0.noteID) == false }
    }

    static func remainingPendingHiddenIDs(
        _ pending: Set<UUID>,
        records: [NoteLibraryRecord]
    ) -> Set<UUID> {
        guard pending.isEmpty == false else { return pending }
        var confirmed = Set<UUID>()
        for record in records where pending.contains(record.noteID) && record.deletedAt != nil {
            confirmed.insert(record.noteID)
        }
        return pending.subtracting(confirmed)
    }

    static func delete(noteID: UUID, in context: ModelContext) {
        if let record = existingRecord(for: noteID, in: context) {
            context.delete(record)
        }
    }

    static func archivedNotes(in notes: [Note]) -> [Note] {
        notes.filter { $0.deletedAt == nil && $0.archivedAt != nil }
    }

    static func trashedNotes(in notes: [Note]) -> [Note] {
        notes.filter { $0.deletedAt != nil }
    }

    static func purgeNote(_ note: Note, in context: ModelContext) {
        delete(noteID: note.id, in: context)
        context.delete(note)
    }

    /// Permanently removes notes and their library rows from the local store.
    @discardableResult
    static func purge(_ notes: [Note], in context: ModelContext) -> Int {
        guard notes.isEmpty == false else { return 0 }
        for note in notes {
            purgeNote(note, in: context)
        }
        try? context.save()
        return notes.count
    }

    static let backfillYieldBatchSize = 25

    @MainActor
    static func backfillIfNeeded(in context: ModelContext) {
        let snapshot = backfillSnapshot(in: context)
        var existing = snapshot.existing
        var seen = Set<UUID>()
        var didChange = false
        for note in snapshot.notes {
            seen.insert(note.id)
            if reconcileBackfill(
                note,
                existing: &existing,
                countsMatch: snapshot.countsMatch,
                context: context
            ) {
                didChange = true
            }
        }
        if deleteUnseenBackfillRecords(existing: existing, seen: seen, context: context) {
            didChange = true
        }
        if didChange {
            try? context.save()
        }
    }

    /// Same reconciliation as `backfillIfNeeded`, saving and yielding every
    /// `backfillYieldBatchSize` writes so a large library can keep painting.
    @MainActor
    static func backfillIfNeededYielding(in context: ModelContext) async {
        let snapshot = backfillSnapshot(in: context)
        var existing = snapshot.existing
        var seen = Set<UUID>()
        var pendingWrites = 0
        for note in snapshot.notes {
            seen.insert(note.id)
            guard reconcileBackfill(
                note,
                existing: &existing,
                countsMatch: snapshot.countsMatch,
                context: context
            ) else { continue }
            pendingWrites += 1
            if pendingWrites >= backfillYieldBatchSize {
                try? context.save()
                pendingWrites = 0
                await Task.yield()
            }
        }
        if deleteUnseenBackfillRecords(existing: existing, seen: seen, context: context) {
            pendingWrites += 1
        }
        if pendingWrites > 0 {
            try? context.save()
        }
    }

    @MainActor
    private static func backfillSnapshot(
        in context: ModelContext
    ) -> (notes: [Note], existing: [UUID: NoteLibraryRecord], countsMatch: Bool) {
        let notes = WiskNoteFetch.allNotes(in: context)
        let existing = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<NoteLibraryRecord>())) ?? [])
                .map { ($0.noteID, $0) }
        )
        return (notes, existing, existing.count == notes.count)
    }

    @MainActor
    private static func reconcileBackfill(
        _ note: Note,
        existing: inout [UUID: NoteLibraryRecord],
        countsMatch: Bool,
        context: ModelContext
    ) -> Bool {
        if let record = existing[note.id] {
            let title = displayTitle(for: note)
            let excerpt = displayExcerpt(for: note)
            let imageIDsJoined = listImageAttachmentIDsJoined(for: note)
            if record.title != title
                || record.excerpt != excerpt
                || record.imageAttachmentIDsJoined != imageIDsJoined
                || countsMatch == false {
                let preservedUpdatedAt = record.updatedAt
                apply(note, to: record)
                if countsMatch {
                    record.updatedAt = preservedUpdatedAt
                }
                return true
            }
            return false
        }
        let created = NoteLibraryRecord(noteID: note.id)
        context.insert(created)
        apply(note, to: created)
        existing[note.id] = created
        return true
    }

    @MainActor
    private static func deleteUnseenBackfillRecords(
        existing: [UUID: NoteLibraryRecord],
        seen: Set<UUID>,
        context: ModelContext
    ) -> Bool {
        var didDelete = false
        for (id, record) in existing where seen.contains(id) == false {
            context.delete(record)
            didDelete = true
        }
        return didDelete
    }

    static let untitledTitle = "Untitled"
    static let untitledListTitle = "Untitled List"
    static let untitledTrackerTitle = "Untitled Tracker"
    static let structuredFallbackTitle = "Structured Note"

    private static let placeholderTitles = [
        untitledTitle,
        untitledListTitle,
        untitledTrackerTitle,
    ]

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return true }
        return placeholderTitles.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    static func strippedHeadingTitle(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let markerCount = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else { return trimmed }
        let rest = trimmed.dropFirst(markerCount)
        guard rest.first == " " else { return trimmed }
        let content = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? trimmed : content
    }

    static func displayTitle(for note: Note) -> String {
        displayTitle(title: note.title, body: note.body, kind: note.kind)
    }

    static func displayTitle(title: String, body: String, kind: NoteKind) -> String {
        if isPlaceholderTitle(title) == false {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if kind == .structured || NoteStructuredSections.containsStructuredMarkup(body) {
            return NoteStructuredSections.firstSectionTitle(in: body) ?? structuredFallbackTitle
        }
        if kind == .list {
            return NoteChecklist.firstItemText(in: body) ?? untitledListTitle
        }
        if kind == .tracker {
            return untitledTrackerTitle
        }
        return untitledTitle
    }

    static func displayExcerpt(for note: Note) -> String {
        displayExcerpt(title: note.title, body: note.body, kind: note.kind)
    }

    static func displayExcerpt(title: String, body: String, kind: NoteKind) -> String {
        if kind == .list {
            return NoteChecklist.progressSummary(for: body)
        }
        if kind == .tracker {
            return NoteTrackerStore.summary(for: body)
        }
        if kind == .structured {
            return NoteStructuredSections.excerpt(for: body)
        }
        if isPlaceholderTitle(title) == false, kind == .general || kind == .daily {
            return ""
        }
        if NoteStructuredSections.containsStructuredMarkup(body) {
            return NoteStructuredSections.excerpt(for: body)
        }
        return firstExcerptLine(in: body)
    }

    private static func isStandaloneMediaLine(_ line: String) -> Bool {
        if WiskMarkdownDocumentEngine.attachment(from: line) != nil {
            return true
        }
        return isStandaloneMarkdownImageLine(line)
    }

    private static func isStandaloneMarkdownImageLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("![") else { return false }
        guard let altEnd = trimmed.firstIndex(of: "]") else { return false }
        let afterAlt = trimmed[trimmed.index(after: altEnd)...]
        return afterAlt.hasPrefix("(") && trimmed.hasSuffix(")")
    }

    private static func firstExcerptLine(in body: String) -> String {
        for line in NoteStructuredSections.visibleBodyLines(in: body) {
            guard isStandaloneMediaLine(line) == false else { continue }
            let stripped = strippedHeadingTitle(from: line)
            if stripped.isEmpty == false {
                return stripped
            }
        }
        return ""
    }

    static func listIdentityHash(for records: [NoteLibraryRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(records.count)
        for record in records {
            hasher.combine(record.noteID)
            hasher.combine(record.updatedAt)
            hasher.combine(record.title)
            hasher.combine(record.excerpt)
        }
        return hasher.finalize()
    }

    static func searchText(for note: Note) -> String {
        var parts = [note.title, note.body]
        parts.append(contentsOf: note.tags.map(\.name))
        if note.kind == .tracker {
            parts.append(NoteTrackerStore.searchableText(for: note.body))
        }
        if note.kind == .structured {
            parts.append(NoteStructuredSections.aiText(from: note.title, body: note.body))
        }
        parts.append(contentsOf: note.parsedItems.map(\.title))
        let joined = parts.joined(separator: " ").lowercased()
        if joined.count > searchTextLimit {
            return String(joined.prefix(searchTextLimit))
        }
        return joined
    }

    static func matchesTerms(_ record: NoteLibraryRecord, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { record.searchText.contains($0) }
    }

    static func matchesTagQuery(_ record: NoteLibraryRecord, tagQuery: String?) -> Bool {
        guard let tagQuery else { return true }
        if tagQuery.caseInsensitiveCompare("untagged") == .orderedSame {
            return record.tagNames.isEmpty
        }
        return record.tagNames.contains { $0.caseInsensitiveCompare(tagQuery) == .orderedSame }
    }

    private static func record(for noteID: UUID, in context: ModelContext) -> NoteLibraryRecord {
        if let existing = existingRecord(for: noteID, in: context) {
            return existing
        }
        let created = NoteLibraryRecord(noteID: noteID)
        context.insert(created)
        return created
    }

    private static func existingRecord(for noteID: UUID, in context: ModelContext) -> NoteLibraryRecord? {
        let target = noteID
        var descriptor = FetchDescriptor<NoteLibraryRecord>(predicate: #Predicate { $0.noteID == target })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// How many image attachment IDs a library record tracks for list thumbnails.
    static let listThumbnailLimit = 2

    /// First image attachment IDs referenced by the note body, in body order,
    /// capped at `listThumbnailLimit`. Only attachments that still exist on the
    /// note (`isImage`, not soft-deleted) are returned, so orphaned references
    /// never reserve a thumbnail slot.
    static func imageAttachmentIDs(for note: Note) -> [UUID] {
        let referenced = referencedImageAttachmentIDs(in: note.body)
        guard referenced.isEmpty == false else { return [] }
        let available = Set(
            note.attachments
                .filter { $0.deletedAt == nil && $0.isImage }
                .map(\.id)
        )
        guard available.isEmpty == false else { return [] }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in referenced {
            guard available.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
            if result.count == listThumbnailLimit { break }
        }
        return result
    }

    private static func referencedImageAttachmentIDs(in body: String) -> [UUID] {
        var ids: [UUID] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = WiskMarkdownDocumentEngine.attachment(from: String(line)),
                  match.value.isImage else { continue }
            ids.append(match.value.id)
        }
        return ids
    }

    private static func listImageAttachmentIDsJoined(for note: Note) -> String {
        imageAttachmentIDs(for: note)
            .map(\.uuidString)
            .joined(separator: String(tagSeparator))
    }

    private static func apply(_ note: Note, to record: NoteLibraryRecord) {
        record.noteID = note.id
        record.title = displayTitle(for: note)
        record.excerpt = displayExcerpt(for: note)
        record.searchText = searchText(for: note)
        record.tagNamesJoined = note.tags.prefix(8).map(\.name).joined(separator: String(tagSeparator))
        record.imageAttachmentIDsJoined = listImageAttachmentIDsJoined(for: note)
        record.updatedAt = note.updatedAt
        record.createdAt = note.createdAt
        record.pinned = note.pinned
        record.kindRaw = note.kindRaw
        record.deletedAt = note.deletedAt
        record.archivedAt = note.archivedAt
        record.hasShares = note.shares.isEmpty == false
    }

    static func matches(_ record: NoteLibraryRecord, scope: WiskNotesScope) -> Bool {
        switch scope {
        case .all:
            return record.deletedAt == nil && record.archivedAt == nil
        case .archive:
            return record.deletedAt == nil && record.archivedAt != nil
        case .trash:
            return record.deletedAt != nil
        case .untagged:
            return record.deletedAt == nil && record.archivedAt == nil && record.tagNames.isEmpty
        case .tag(let tag):
            return record.deletedAt == nil
                && record.archivedAt == nil
                && record.tagNames.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    static func visibleRecords(
        _ records: [NoteLibraryRecord],
        scope: WiskNotesScope,
        searchText: String,
        sortMode: WiskNoteSortMode
    ) -> [NoteLibraryRecord] {
        let parsedSearch = NoteSearchEngine.ParsedSearch(searchText)
        let filtered = records.filter { record in
            matches(record, scope: scope)
                && matchesTagQuery(record, tagQuery: parsedSearch.tagQuery)
                && matchesTerms(record, terms: parsedSearch.terms)
        }
        return sorted(filtered, sortMode: sortMode)
    }

    static func sorted(
        _ records: [NoteLibraryRecord],
        sortMode: WiskNoteSortMode
    ) -> [NoteLibraryRecord] {
        records.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned, lhs.deletedAt == nil, rhs.deletedAt == nil {
                return lhs.pinned
            }
            switch sortMode {
            case .modifiedNewest:
                return lhs.updatedAt > rhs.updatedAt
            case .modifiedOldest:
                return lhs.updatedAt < rhs.updatedAt
            case .createdNewest:
                return lhs.createdAt > rhs.createdAt
            case .createdOldest:
                return lhs.createdAt < rhs.createdAt
            case .titleAscending:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .titleDescending:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }
        }
    }

    static func activeTagNames(from records: [NoteLibraryRecord]) -> [String] {
        var names = Set<String>()
        for record in records where record.deletedAt == nil && record.archivedAt == nil {
            names.formUnion(record.tagNames)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
