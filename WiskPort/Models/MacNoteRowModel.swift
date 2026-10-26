import Foundation

struct MacNoteRowModel: Identifiable, Equatable {
    static let compactListRowHeight: CGFloat = 50
    static let excerptedListRowHeight: CGFloat = 68

    let id: UUID
    let title: String
    let excerpt: String
    let updatedAt: Date
    let pinned: Bool
    let kind: NoteKind
    let tagNames: [String]
    let deletedAt: Date?
    let hasShares: Bool

    var listRowHeight: CGFloat {
        excerpt.isEmpty ? Self.compactListRowHeight : Self.excerptedListRowHeight
    }

    init(note: Note) {
        self.init(
            id: note.id,
            title: NoteLibraryIndex.displayTitle(for: note),
            excerpt: NoteLibraryIndex.displayExcerpt(for: note),
            updatedAt: note.updatedAt,
            pinned: note.pinned,
            kind: note.kind,
            tagNames: Array(note.tags.prefix(2).map(\.name)),
            deletedAt: note.deletedAt,
            hasShares: note.shares.isEmpty == false
        )
    }

    init(record: NoteLibraryRecord) {
        self.init(
            id: record.noteID,
            title: record.title,
            excerpt: record.excerpt,
            updatedAt: record.updatedAt,
            pinned: record.pinned,
            kind: record.kind,
            tagNames: Array(record.tagNames.prefix(2)),
            deletedAt: record.deletedAt,
            hasShares: record.hasShares
        )
    }

    init(
        id: UUID,
        title: String,
        excerpt: String,
        updatedAt: Date,
        pinned: Bool,
        kind: NoteKind,
        tagNames: [String],
        deletedAt: Date?,
        hasShares: Bool
    ) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.kind = kind
        self.tagNames = tagNames
        self.deletedAt = deletedAt
        self.hasShares = hasShares
    }

    func replacingTitle(_ title: String) -> MacNoteRowModel {
        guard self.title != title else { return self }
        return MacNoteRowModel(
            id: id,
            title: title,
            excerpt: excerpt,
            updatedAt: updatedAt,
            pinned: pinned,
            kind: kind,
            tagNames: tagNames,
            deletedAt: deletedAt,
            hasShares: hasShares
        )
    }
}

struct MacLiveListTitle: Equatable {
    var noteID: UUID
    var title: String
}

enum MacNoteRowBudget {
    static let initial = 80
    static let chunkSize = 200

    static func notes(_ notes: [Note], budget: Int, selectedID: UUID?) -> [Note] {
        limited(notes, budget: budget, selectedID: selectedID, id: \.id)
    }

    static func records(_ records: [NoteLibraryRecord], budget: Int, selectedID: UUID?) -> [NoteLibraryRecord] {
        limited(records, budget: budget, selectedID: selectedID, id: \.noteID)
    }

    private static func limited<T>(
        _ items: [T],
        budget: Int,
        selectedID: UUID?,
        id: (T) -> UUID
    ) -> [T] {
        let limitedBudget = max(budget, 0)
        if items.count <= limitedBudget {
            return items
        }
        var result = Array(items.prefix(limitedBudget))
        if let selectedID,
           result.contains(where: { id($0) == selectedID }) == false,
           let selected = items.first(where: { id($0) == selectedID }) {
            result.append(selected)
        }
        return result
    }
}

struct MacNoteListRowSnapshot: Equatable {
    var models: [MacNoteRowModel]
    var visibleIDs: Set<UUID>
    var deletedIDs: Set<UUID>
    var pinnedIDs: Set<UUID>
}

final class MacNoteRowModelCache {
    private struct CheapFingerprint: Equatable {
        let id: UUID
        let updatedAt: Date
        let title: String
        let excerpt: String?
        let pinned: Bool
        let kind: NoteKind
        let deletedAt: Date?
    }

    private var fingerprints: [UUID: CheapFingerprint] = [:]
    private var models: [UUID: MacNoteRowModel] = [:]
    private var lastRowSnapshotKey: Int?
    private var lastRowSnapshot: MacNoteListRowSnapshot?

    func models(for notes: [Note]) -> [MacNoteRowModel] {
        cachedModels(for: notes, id: \.id) { note in
            CheapFingerprint(
                id: note.id,
                updatedAt: note.updatedAt,
                title: note.title,
                excerpt: nil,
                pinned: note.pinned,
                kind: note.kind,
                deletedAt: note.deletedAt
            )
        } make: { note in
            MacNoteRowModel(note: note)
        }
    }

    func models(for records: [NoteLibraryRecord]) -> [MacNoteRowModel] {
        cachedModels(for: records, id: \.noteID) { record in
            CheapFingerprint(
                id: record.noteID,
                updatedAt: record.updatedAt,
                title: record.title,
                excerpt: record.excerpt,
                pinned: record.pinned,
                kind: record.kind,
                deletedAt: record.deletedAt
            )
        } make: { record in
            MacNoteRowModel(record: record)
        }
    }

    func snapshot(for records: [NoteLibraryRecord]) -> MacNoteListRowSnapshot {
        let models = models(for: records)
        var hasher = Hasher()
        hasher.combine(models.count)
        for model in models {
            hasher.combine(model.id)
            hasher.combine(model.pinned)
            hasher.combine(model.deletedAt)
        }
        let key = hasher.finalize()
        if key == lastRowSnapshotKey, let lastRowSnapshot {
            return lastRowSnapshot
        }
        var visibleIDs = Set<UUID>()
        visibleIDs.reserveCapacity(models.count)
        var deletedIDs = Set<UUID>()
        var pinnedIDs = Set<UUID>()
        for model in models {
            visibleIDs.insert(model.id)
            if model.deletedAt != nil {
                deletedIDs.insert(model.id)
            }
            if model.pinned {
                pinnedIDs.insert(model.id)
            }
        }
        let snapshot = MacNoteListRowSnapshot(
            models: models,
            visibleIDs: visibleIDs,
            deletedIDs: deletedIDs,
            pinnedIDs: pinnedIDs
        )
        lastRowSnapshotKey = key
        lastRowSnapshot = snapshot
        return snapshot
    }

    private func cachedModels<T>(
        for items: [T],
        id: (T) -> UUID,
        fingerprint: (T) -> CheapFingerprint,
        make: (T) -> MacNoteRowModel
    ) -> [MacNoteRowModel] {
        var seen = Set<UUID>()
        let result = items.map { item -> MacNoteRowModel in
            let itemID = id(item)
            seen.insert(itemID)
            let nextFingerprint = fingerprint(item)
            if fingerprints[itemID] == nextFingerprint, let cached = models[itemID] {
                return cached
            }
            let model = make(item)
            fingerprints[itemID] = nextFingerprint
            models[itemID] = model
            return model
        }
        if fingerprints.count > seen.count {
            let staleIDs = fingerprints.keys.filter { seen.contains($0) == false }
            for staleID in staleIDs {
                fingerprints[staleID] = nil
                models[staleID] = nil
            }
        }
        return result
    }
}
