import Foundation

/// Shared, platform-agnostic note search/filter matching, used by both
/// `MacNoteSearch` (`MacViews/MacSimplenoteViews.swift`) and `NotesHomeView`
/// (`Views/WiskFeatureViews.swift`). Before this extraction each platform
/// reimplemented "which fields count as a note's searchable content" and
/// "does this note match query X" independently, and iOS's copy had quietly
/// drifted from macOS's — missing the `tag:` query token and multi-term AND
/// matching that macOS already supported. This is the first slice of
/// Wisk's iOS/macOS de-duplication; the platform-specific pieces that
/// remain (sidebar-selection matching, sort order, tag aggregation for the
/// sidebar) still live in each platform's own view file since they depend
/// on Mac-only types or have UI-specific behavior that isn't a byte-for-byte
/// duplicate.
enum NoteSearchEngine {
    /// A raw search string split into free-text `terms` (AND-matched,
    /// case-insensitive) and an optional `tag:<name>` filter pulled out of a
    /// `tag:` token.
    struct ParsedSearch: Equatable {
        var terms: [String] = []
        var tagQuery: String?

        init(_ rawSearchText: String) {
            let tokens = rawSearchText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            for token in tokens {
                if token.lowercased().hasPrefix("tag:") {
                    let value = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        tagQuery = value
                    }
                } else {
                    let normalized = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
                    if !normalized.isEmpty {
                        terms.append(normalized)
                    }
                }
            }
        }
    }

    /// Whether `note` satisfies a `tag:<name>` query token (or `tag:untagged`
    /// for notes with no tags). `tagQuery == nil` means the search string had
    /// no `tag:` token, so every note passes.
    static func matchesTagQuery(_ note: Note, tagQuery: String?) -> Bool {
        guard let tagQuery else { return true }
        if tagQuery.caseInsensitiveCompare("untagged") == .orderedSame {
            return note.tags.isEmpty
        }
        return note.tags.contains { $0.name.caseInsensitiveCompare(tagQuery) == .orderedSame }
    }

    /// Whether `note` contains every term in `terms` (AND-matched, case
    /// insensitive) across its title, body, tag names, and kind-specific
    /// searchable text (structured sections, tracker entries), plus parsed
    /// AI-derived item titles when `includeAIFields` is true (gated by pro
    /// entitlement on both platforms). An empty `terms` array matches every
    /// note, matching how both platforms treat an empty/whitespace-only
    /// search string.
    static func matchesTerms(_ note: Note, terms: [String], includeAIFields: Bool) -> Bool {
        guard !terms.isEmpty else { return true }
        let aiFields = includeAIFields ? note.parsedItems.map(\.title) : []
        let trackerFields = note.kind == .tracker ? [NoteTrackerStore.searchableText(for: note.body)] : []
        let structuredFields = note.kind == .structured ? [NoteStructuredSections.aiText(from: note.title, body: note.body)] : []
        let haystack = ([note.title, note.body] + note.tags.map(\.name) + aiFields + trackerFields + structuredFields)
            .joined(separator: " ")
            .lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Case-insensitive UTF-16 ranges of every search term in already-visible text.
    /// Empty or whitespace queries produce no ranges. Same term tokenization as list filtering.
    static func visibleMatchRanges(in visibleText: String, searchText: String) -> [NSRange] {
        visibleMatchRanges(in: visibleText, terms: ParsedSearch(searchText).terms)
    }

    static func visibleMatchRanges(in visibleText: String, terms: [String]) -> [NSRange] {
        let ns = visibleText as NSString
        let haystackLength = ns.length
        guard haystackLength > 0 else { return [] }

        var ranges: [NSRange] = []
        for term in terms where term.isEmpty == false {
            let needleLength = (term as NSString).length
            guard needleLength > 0 else { continue }
            var searchRange = NSRange(location: 0, length: haystackLength)
            while searchRange.length >= needleLength {
                let found = ns.range(of: term, options: [.caseInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = found.upperBound
                if next >= haystackLength { break }
                searchRange = NSRange(location: next, length: haystackLength - next)
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }
}
