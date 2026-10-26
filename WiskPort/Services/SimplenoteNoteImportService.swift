import Foundation
import SwiftData

enum SimplenoteNoteImportService {
    static let importedIDsDefaultsKey = "wisk.simplenoteImportedIDs"
    static let lastBatchDefaultsKey = "wisk.simplenoteLastImportBatch"
    static let importedNoteMapDefaultsKey = "wisk.simplenoteImportedNoteMap"

    struct BatchItem: Codable, Equatable, Sendable {
        var sourceID: String
        var noteID: UUID
    }

    struct TitleBody: Equatable, Sendable {
        var title: String
        var body: String
    }

    static func splitTitleAndBody(_ content: String) -> TitleBody {
        // Repair byte-swapped `\uXXXX` artifacts before splitting so imports
        // (and re-import comparisons) see the repaired text.
        let lines = WiskByteSwappedEscapeRepair.repaired(content)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let titleIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            return TitleBody(title: "Untitled", body: "")
        }

        var titleLine = lines[titleIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if titleLine.hasPrefix("#") {
            titleLine = String(titleLine.drop(while: { $0 == "#" }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if titleLine.isEmpty {
            titleLine = "Untitled"
        }

        let remaining = lines.suffix(from: titleIndex + 1).joined(separator: "\n")
        let body = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return TitleBody(title: titleLine, body: body)
    }

    static func makeNote(from draft: SimplenoteNoteDraft) -> Note {
        let split = splitTitleAndBody(draft.content)
        let note = Note(title: split.title, body: split.body, kind: .general)
        note.createdAt = draft.createdAt
        note.updatedAt = draft.updatedAt
        note.pinned = draft.pinned
        note.markdownEnabled = draft.markdownEnabled
        for tag in uniquedTagNames(draft.tags) {
            note.addTagIfNeeded(tag)
        }
        return note
    }

    struct UpdateItem: Equatable, Sendable {
        var draft: SimplenoteNoteDraft
        var noteID: UUID
    }

    struct Classification: Equatable, Sendable {
        var toCreate: [SimplenoteNoteDraft] = []
        var toUpdate: [UpdateItem] = []
        var unchangedCount = 0

        var createCount: Int { toCreate.count }
        var updateCount: Int { toUpdate.count }
        var hasWork: Bool { createCount > 0 || updateCount > 0 }
    }

    static func classify(
        _ drafts: [SimplenoteNoteDraft],
        existingNotes: [Note],
        defaults: UserDefaults = .standard
    ) -> Classification {
        let notesByID = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0) })
        let noteIDsBySourceID = importedNoteIDsBySourceID(defaults: defaults)
        var classification = Classification()

        for draft in drafts {
            if let noteID = noteIDsBySourceID[draft.sourceID], let note = notesByID[noteID] {
                if wouldChange(draft, note: note) {
                    classification.toUpdate.append(UpdateItem(draft: draft, noteID: noteID))
                } else {
                    classification.unchangedCount += 1
                }
            } else {
                classification.toCreate.append(draft)
            }
        }

        return classification
    }

    static func wouldChange(_ draft: SimplenoteNoteDraft, note: Note) -> Bool {
        let split = splitTitleAndBody(draft.content)
        if note.title != split.title { return true }
        if note.body != split.body { return true }
        if note.pinned != draft.pinned { return true }
        if note.markdownEnabled != draft.markdownEnabled { return true }
        if note.createdAt != draft.createdAt { return true }
        if note.updatedAt != draft.updatedAt { return true }
        if note.kind != .general { return true }
        if note.deletedAt != nil { return true }
        return tagNameSet(on: note) != tagNameSet(draft.tags)
    }

    /// Overwrites a mapped Wisk note with the Simplenote copy. Returns whether any field changed.
    @discardableResult
    static func apply(_ draft: SimplenoteNoteDraft, onto note: Note) -> Bool {
        guard wouldChange(draft, note: note) else { return false }

        let split = splitTitleAndBody(draft.content)
        note.title = split.title
        note.body = split.body
        note.kind = .general
        note.pinned = draft.pinned
        note.markdownEnabled = draft.markdownEnabled
        note.createdAt = draft.createdAt
        note.updatedAt = draft.updatedAt
        note.deletedAt = nil
        replaceTags(on: note, with: uniquedTagNames(draft.tags))
        return true
    }

    static func importedSourceIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: importedIDsDefaultsKey) ?? [])
    }

    static func importedNoteIDsBySourceID(defaults: UserDefaults = .standard) -> [String: UUID] {
        if let data = defaults.data(forKey: importedNoteMapDefaultsKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            let mapped = raw.compactMapValues(UUID.init(uuidString:))
            if mapped.isEmpty == false {
                return mapped
            }
        }
        return Dictionary(uniqueKeysWithValues: lastImportBatch(defaults: defaults).map { ($0.sourceID, $0.noteID) })
    }

    static func lastImportBatch(defaults: UserDefaults = .standard) -> [BatchItem] {
        guard let data = defaults.data(forKey: lastBatchDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([BatchItem].self, from: data)) ?? []
    }

    static func lastImportedNoteIDs(defaults: UserDefaults = .standard) -> [UUID] {
        lastImportBatch(defaults: defaults).map(\.noteID)
    }

    static func mappedImportBatch(defaults: UserDefaults = .standard) -> [BatchItem] {
        importedNoteIDsBySourceID(defaults: defaults)
            .map { BatchItem(sourceID: $0.key, noteID: $0.value) }
            .sorted { $0.sourceID < $1.sourceID }
    }

    static func recordImport(
        _ items: [BatchItem],
        defaults: UserDefaults = .standard
    ) {
        recordImport(created: items, updated: [], defaults: defaults)
    }

    /// Merges created and updated source IDs into the persistent map.
    /// `lastImportBatch` stores **created** notes only so undo does not archive updates.
    static func recordImport(
        created: [BatchItem],
        updated: [BatchItem],
        defaults: UserDefaults = .standard
    ) {
        mergeImportedMappings(created + updated, defaults: defaults)
        if let data = try? JSONEncoder().encode(created) {
            defaults.set(data, forKey: lastBatchDefaultsKey)
        }
    }

    static func mergeImportedMappings(
        _ items: [BatchItem],
        defaults: UserDefaults = .standard
    ) {
        guard items.isEmpty == false else { return }
        var map = importedNoteIDsBySourceID(defaults: defaults)
        var known = importedSourceIDs(defaults: defaults)
        known.formUnion(items.map(\.sourceID))
        defaults.set(Array(known).sorted(), forKey: importedIDsDefaultsKey)
        for item in items {
            map[item.sourceID] = item.noteID
        }
        saveImportedNoteMap(map, defaults: defaults)
    }

    static func forgetLastImport(defaults: UserDefaults = .standard) {
        let batch = lastImportBatch(defaults: defaults)
        guard batch.isEmpty == false else { return }
        var map = importedNoteIDsBySourceID(defaults: defaults)
        var known = importedSourceIDs(defaults: defaults)
        known.subtract(batch.map(\.sourceID))
        defaults.set(Array(known).sorted(), forKey: importedIDsDefaultsKey)
        defaults.removeObject(forKey: lastBatchDefaultsKey)
        for item in batch {
            map.removeValue(forKey: item.sourceID)
        }
        saveImportedNoteMap(map, defaults: defaults)
    }

    private static func saveImportedNoteMap(_ map: [String: UUID], defaults: UserDefaults) {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key, $0.value.uuidString) })
        defaults.set(try? JSONEncoder().encode(raw), forKey: importedNoteMapDefaultsKey)
    }

    private static func uniquedTagNames(_ names: [String]) -> [String] {
        names.reduce(into: [String]()) { result, name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            guard result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) == false else {
                return
            }
            result.append(trimmed)
        }
    }

    private static func tagNameSet(on note: Note) -> Set<String> {
        tagNameSet(note.tags.map(\.name))
    }

    private static func tagNameSet(_ names: [String]) -> Set<String> {
        Set(uniquedTagNames(names).map { $0.lowercased() })
    }

    private static func replaceTags(on note: Note, with names: [String]) {
        guard tagNameSet(on: note) != tagNameSet(names) else { return }
        note.tags = names.map { NoteTag(name: $0, suggestedByAI: false, note: note) }
    }

    struct DateReapplyResult: Equatable, Sendable {
        var updatedNoteIDs: [UUID] = []
        var missingDraftCount = 0
        var missingNoteCount = 0

        var updatedCount: Int { updatedNoteIDs.count }
    }

    /// Writes Simplenote created/updated dates onto notes from the import map.
    /// Title and body are left unchanged.
    @discardableResult
    static func reapplyDates(
        from drafts: [SimplenoteNoteDraft],
        onto notes: [Note],
        batch: [BatchItem]
    ) -> DateReapplyResult {
        guard batch.isEmpty == false else { return DateReapplyResult() }

        let draftsBySourceID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.sourceID, $0) })
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var result = DateReapplyResult()

        for item in batch {
            guard let note = notesByID[item.noteID] else {
                result.missingNoteCount += 1
                continue
            }
            guard let draft = draftsBySourceID[item.sourceID] else {
                result.missingDraftCount += 1
                continue
            }

            if note.createdAt != draft.createdAt || note.updatedAt != draft.updatedAt {
                note.createdAt = draft.createdAt
                note.updatedAt = draft.updatedAt
                result.updatedNoteIDs.append(note.id)
            }
        }

        return result
    }

    static func reapplyDates(
        from drafts: [SimplenoteNoteDraft],
        onto notes: [Note],
        defaults: UserDefaults = .standard
    ) -> DateReapplyResult {
        reapplyDates(from: drafts, onto: notes, batch: mappedImportBatch(defaults: defaults))
    }

    /// Extra live copies of the same Simplenote import. Groups by title, body,
    /// and Simplenote created/updated dates. Keeps mapped import IDs; if a
    /// group has none, keeps one note by stable UUID order.
    static func duplicateImportCopies(
        in notes: [Note],
        defaults: UserDefaults = .standard
    ) -> [Note] {
        let mappedIDs = Set(importedNoteIDsBySourceID(defaults: defaults).values)
        var groups: [DuplicateFingerprint: [Note]] = [:]
        for note in notes where note.deletedAt == nil {
            groups[DuplicateFingerprint(note), default: []].append(note)
        }

        var extras: [Note] = []
        for group in groups.values where group.count > 1 {
            let sorted = group.sorted { $0.id.uuidString < $1.id.uuidString }
            let keepers = Set(sorted.filter { mappedIDs.contains($0.id) }.map(\.id))
            if keepers.isEmpty {
                extras.append(contentsOf: sorted.dropFirst())
            } else {
                extras.append(contentsOf: sorted.filter { keepers.contains($0.id) == false })
            }
        }
        return extras.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

private struct DuplicateFingerprint: Hashable {
    var title: String
    var body: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    init(_ note: Note) {
        title = note.title
        body = note.body
        createdAt = note.createdAt.timeIntervalSinceReferenceDate
        updatedAt = note.updatedAt.timeIntervalSinceReferenceDate
    }
}
