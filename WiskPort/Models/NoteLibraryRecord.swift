import Foundation
import SwiftData

@Model
final class NoteLibraryRecord {
    @Attribute(.unique) var noteID: UUID = UUID()
    var title: String = ""
    var excerpt: String = ""
    var searchText: String = ""
    var tagNamesJoined: String = ""
    var imageAttachmentIDsJoined: String = ""
    var updatedAt: Date = Date()
    var createdAt: Date = Date()
    var pinned: Bool = false
    var kindRaw: String = NoteKind.general.rawValue
    var deletedAt: Date? = nil
    var archivedAt: Date? = nil
    var hasShares: Bool = false

    var kind: NoteKind {
        NoteKind(rawValue: kindRaw) ?? .general
    }

    var tagNames: [String] {
        tagNamesJoined
            .split(separator: NoteLibraryIndex.tagSeparator, omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// First image attachment IDs referenced by the note body, in body order.
    /// Drives note-list thumbnails without fetching full `Note` models.
    var imageAttachmentIDs: [UUID] {
        imageAttachmentIDsJoined
            .split(separator: NoteLibraryIndex.tagSeparator, omittingEmptySubsequences: true)
            .compactMap { UUID(uuidString: String($0)) }
    }

    init(noteID: UUID) {
        self.noteID = noteID
    }
}

enum WiskNoteFetch {
    static func note(id: UUID, in context: ModelContext) -> Note? {
        let target = id
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == target })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func notes(ids: Set<UUID>, in context: ModelContext) -> [Note] {
        ids.compactMap { note(id: $0, in: context) }
    }

    static func allNotes(in context: ModelContext) -> [Note] {
        let descriptor = FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
