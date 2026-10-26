import Foundation

enum WiskMarkdownFolding {
    static func interiorSourceRange(
        forFoldAt location: Int,
        in document: WiskMarkdownDocument
    ) -> NSRange? {
        guard let block = document.blocks.first(where: { $0.sourceRange.location == location }) else {
            return nil
        }
        switch block.kind {
        case .heading(let level):
            let start = block.sourceRange.upperBound
            let next = document.blocks.first { candidate in
                candidate.sourceRange.location > block.sourceRange.location
                    && headingLevel(candidate).map { $0 <= level } == true
            }
            let end = next?.sourceRange.location ?? document.source.utf16.count
            let length = max(0, end - start)
            return length > 0 ? NSRange(location: start, length: length) : nil
        case .fencedCode:
            let openingLine = (document.source as NSString).lineRange(
                for: NSRange(location: block.sourceRange.location, length: 0)
            )
            let start = openingLine.upperBound
            let length = max(0, block.sourceRange.upperBound - start)
            return length > 0 ? NSRange(location: start, length: length) : nil
        default:
            return nil
        }
    }

    static func canFold(block: WiskMarkdownBlock) -> Bool {
        switch block.kind {
        case .heading, .fencedCode:
            return true
        default:
            return false
        }
    }

    static func hiddenSourceRanges(
        foldedLocations: Set<Int>,
        in document: WiskMarkdownDocument
    ) -> [NSRange] {
        foldedLocations.compactMap { interiorSourceRange(forFoldAt: $0, in: document) }
    }

    static func omittedSourceRanges(
        foldedLocations: Set<Int>,
        in document: WiskMarkdownDocument
    ) -> [NSRange] {
        hiddenSourceRanges(foldedLocations: foldedLocations, in: document)
            + document.tables.flatMap { table in
                table.rows.filter(\.isDivider).map(\.sourceRange)
            }
    }

    static func contains(_ location: Int, in ranges: [NSRange]) -> Bool {
        ranges.contains { location >= $0.location && location < $0.upperBound }
    }

    static func fullyContains(_ range: NSRange, in ranges: [NSRange]) -> Bool {
        guard range.length >= 0 else { return false }
        if range.length == 0 {
            return contains(range.location, in: ranges)
        }
        return ranges.contains {
            range.location >= $0.location && range.upperBound <= $0.upperBound
        }
    }

    static func unfoldLocations(
        intersecting sourceRange: NSRange,
        in document: WiskMarkdownDocument,
        folds: Set<Int>
    ) -> Set<Int> {
        var remaining = folds
        for location in folds {
            guard let interior = interiorSourceRange(forFoldAt: location, in: document) else { continue }
            let touchesBody = NSIntersectionRange(interior, sourceRange).length > 0
                || (sourceRange.length == 0 && contains(sourceRange.location, in: [interior]))
            if touchesBody {
                remaining.remove(location)
            }
        }
        return remaining
    }

    static func headingLevel(_ block: WiskMarkdownBlock) -> Int? {
        if case .heading(let level) = block.kind {
            return level
        }
        return nil
    }

    static func foldAnchor(
        atSource location: Int,
        in document: WiskMarkdownDocument
    ) -> Int? {
        document.blocks.first { block in
            canFold(block: block)
                && location >= block.sourceRange.location
                && location <= block.sourceRange.upperBound
        }?.sourceRange.location
    }
}
