import Foundation
import SwiftData

struct WiskNoteLinkListing: Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var deletedAt: Date?
    var searchHaystack: String

    init(
        id: UUID,
        title: String,
        updatedAt: Date,
        deletedAt: Date?,
        searchHaystack: String
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.searchHaystack = searchHaystack
    }

    init(note: Note) {
        self.init(
            id: note.id,
            title: note.title,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt,
            searchHaystack: (note.title + "\n" + note.body).lowercased()
        )
    }

    init(record: NoteLibraryRecord) {
        self.init(
            id: record.noteID,
            title: record.title,
            updatedAt: record.updatedAt,
            deletedAt: record.deletedAt,
            searchHaystack: record.searchText
        )
    }
}

enum WiskNoteLinkService {
    struct ResolvedLink: Equatable {
        var noteID: UUID
        var heading: String?
        var didCreate: Bool
    }

    @MainActor
    enum PendingJump {
        static var noteID: UUID?
        static var heading: String?

        static func set(noteID: UUID, heading: String?) {
            self.noteID = noteID
            self.heading = heading
        }

        static func consume(for noteID: UUID) -> String? {
            guard self.noteID == noteID else { return nil }
            let heading = self.heading
            self.noteID = nil
            self.heading = nil
            return heading
        }
    }

    static func parseTarget(_ raw: String) -> (title: String, heading: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.firstIndex(of: "#") else {
            return (trimmed, nil)
        }
        let title = String(trimmed[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = String(trimmed[trimmed.index(after: hash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, heading.isEmpty ? nil : heading)
    }

    static func outgoingWikiTargets(in body: String) -> [String] {
        WiskMarkdownDocumentEngine.parse(body).blocks
            .flatMap(\.inlineSpans)
            .flatMap(flattened)
            .compactMap { span -> String? in
                if case .wikilink(let target) = span.kind {
                    let title = parseTarget(target).title
                    return title.isEmpty ? nil : title
                }
                return nil
            }
    }

    static func matchesTitle(_ title: String, _ other: String) -> Bool {
        title.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func matchesTitle(_ note: Note, title: String) -> Bool {
        matchesTitle(note.title, title)
    }

    static func resolveExisting(title: String, in listings: [WiskNoteLinkListing]) -> WiskNoteLinkListing? {
        let matches = listings.filter { $0.deletedAt == nil && matchesTitle($0.title, title) }
        if let unique = matches.count == 1 ? matches.first : nil {
            return unique
        }
        return matches.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    static func resolveExisting(title: String, in notes: [Note]) -> Note? {
        guard let listing = resolveExisting(title: title, in: notes.map(WiskNoteLinkListing.init(note:))) else {
            return nil
        }
        return notes.first { $0.id == listing.id }
    }

    @MainActor
    static func resolveOrCreate(
        rawTarget: String,
        in listings: [WiskNoteLinkListing],
        context: ModelContext
    ) -> (note: Note, heading: String?, didCreate: Bool)? {
        let parsed = parseTarget(rawTarget)
        guard !parsed.title.isEmpty else { return nil }
        if let existing = resolveExisting(title: parsed.title, in: listings) {
            guard let note = WiskNoteFetch.note(id: existing.id, in: context) else { return nil }
            return (note, parsed.heading, false)
        }
        let note = Note(title: parsed.title, body: "", kind: .general)
        note.markdownEnabled = true
        note.syncStatus = .queued
        context.insert(note)
        try? context.save()
        NoteLibraryIndex.upsert(note, in: context)
        try? context.save()
        return (note, parsed.heading, true)
    }

    @MainActor
    static func resolveOrCreate(
        rawTarget: String,
        in notes: [Note],
        context: ModelContext
    ) -> (note: Note, heading: String?, didCreate: Bool)? {
        resolveOrCreate(rawTarget: rawTarget, in: notes.map(WiskNoteLinkListing.init(note:)), context: context)
    }

    static func wikiLinkNeedle(for title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "[[" + trimmed.lowercased()
    }

    static func backlinks(
        to title: String,
        excluding id: UUID,
        in listings: [WiskNoteLinkListing]
    ) -> [WiskNoteLinkListing] {
        guard let needle = wikiLinkNeedle(for: title) else { return [] }
        return listings.filter { candidate in
            candidate.id != id
                && candidate.deletedAt == nil
                && candidate.searchHaystack.contains(needle)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func backlinks(to note: Note, in notes: [Note]) -> [Note] {
        let ids = backlinks(
            to: note.title,
            excluding: note.id,
            in: notes.map(WiskNoteLinkListing.init(note:))
        ).map(\.id)
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    static func linkedNotes(from body: String, in listings: [WiskNoteLinkListing]) -> [WiskNoteLinkListing] {
        let titles = outgoingWikiTargets(in: body)
        var seen = Set<UUID>()
        return titles.compactMap { title in
            resolveExisting(title: title, in: listings)
        }
        .filter { seen.insert($0.id).inserted }
    }

    static func linkedNotes(from note: Note, in notes: [Note]) -> [Note] {
        let listings = linkedNotes(from: note.body, in: notes.map(WiskNoteLinkListing.init(note:)))
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return listings.compactMap { byID[$0.id] }
    }

    static func autocompleteTitles(
        query: String,
        in listings: [WiskNoteLinkListing],
        excluding noteID: UUID?
    ) -> [String] {
        let titleQuery = query.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? query
        let needle = titleQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return listings
            .filter { candidate in
                candidate.deletedAt == nil
                    && candidate.id != noteID
                    && !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (needle.isEmpty || candidate.title.lowercased().contains(needle))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)
            .map(\.title)
    }

    static func autocompleteTitles(query: String, in notes: [Note], excluding noteID: UUID?) -> [String] {
        autocompleteTitles(query: query, in: notes.map(WiskNoteLinkListing.init(note:)), excluding: noteID)
    }

    static func wikiURL(forTarget target: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wisk-note"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        return components.url
    }

    static func wikiTarget(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "wisk-note" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first(where: { $0.name == "target" })?.value
    }

    private static func flattened(_ span: WiskMarkdownInlineSpan) -> [WiskMarkdownInlineSpan] {
        [span] + span.children.flatMap(flattened)
    }
}
