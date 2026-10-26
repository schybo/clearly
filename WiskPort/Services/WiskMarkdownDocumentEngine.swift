import Foundation

/// A source-preserving Markdown model for Wisk editors.
///
/// This intentionally implements Wisk's supported Markdown subset, not full
/// CommonMark. Unrecognized or malformed constructs remain paragraph text and
/// serialize byte-for-byte. Parsed constructs are never normalized; only an
/// explicit mutation changes source.
struct WiskMarkdownDocument: Sendable, Equatable {
    let source: String
    let blocks: [WiskMarkdownBlock]
    let visibleText: String
    let mappings: [WiskMarkdownTextMapping]

    var sourceRange: NSRange {
        NSRange(location: 0, length: source.utf16.count)
    }

    func serializedSource() -> String {
        blocks.map(\.rawSource).joined()
    }

    /// Converts a rendered-editor UTF-16 range to an exact Swift source range.
    ///
    /// Delimiters hidden from the editor are included when they surround the
    /// selection. A caret adjacent to hidden syntax is biased toward content.
    func sourceRange(forVisibleRange visibleRange: NSRange) -> Range<String.Index>? {
        guard let range = sourceNSRange(forVisibleRange: visibleRange) else { return nil }
        return Range(range, in: source)
    }

    func sourceNSRange(forVisibleRange requestedRange: NSRange) -> NSRange? {
        let visibleLength = visibleText.utf16.count
        guard requestedRange.location >= 0,
              requestedRange.length >= 0,
              requestedRange.location <= visibleLength,
              requestedRange.upperBound <= visibleLength,
              Range(requestedRange, in: visibleText) != nil else {
            return nil
        }

        if requestedRange.length == 0 {
            let offset = requestedRange.location
            if let exact = mappings.first(where: { $0.visibleRange.location == offset }) {
                // A caret at the end of a styled span's content is biased
                // toward content: keep it before the span's hidden closer
                // (the second `*` in *mom*) so typed text extends the styled
                // run. The leading edge is untouched — the exact match
                // already lands after a hidden opener.
                if let previous = mappings.last(where: {
                    $0.visibleRange.upperBound == offset
                        && $0.sourceRange.upperBound < exact.sourceRange.location
                }),
                   blocks.contains(where: { block in
                       block.inlineSpans.contains { span in
                           span.visibleRange.upperBound == offset
                               && span.sourceRange.upperBound > previous.sourceRange.upperBound
                       }
                   }) {
                    return NSRange(location: previous.sourceRange.upperBound, length: 0)
                }
                return NSRange(location: exact.sourceRange.location, length: 0)
            }
            if let containing = mappings.first(where: {
                offset > $0.visibleRange.location && offset < $0.visibleRange.upperBound
            }) {
                let delta = offset - containing.visibleRange.location
                return NSRange(location: containing.sourceRange.location + delta, length: 0)
            }
            if let previous = mappings.last(where: { $0.visibleRange.upperBound <= offset }) {
                return NSRange(location: previous.sourceRange.upperBound, length: 0)
            }
            return NSRange(location: 0, length: 0)
        }

        let intersecting = mappings.filter {
            NSIntersectionRange($0.visibleRange, requestedRange).length > 0
        }
        guard let first = intersecting.first, let last = intersecting.last else { return nil }

        let lowerVisible = max(requestedRange.location, first.visibleRange.location)
        let upperVisible = min(requestedRange.upperBound, last.visibleRange.upperBound)
        let lower = first.sourceRange.location + lowerVisible - first.visibleRange.location
        let upper = last.sourceRange.location + upperVisible - last.visibleRange.location
        guard lower <= upper else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    func visibleNSRange(forSourceRange requested: NSRange) -> NSRange? {
        let sourceLength = source.utf16.count
        guard requested.location >= 0,
              requested.length >= 0,
              requested.location <= sourceLength,
              requested.upperBound <= sourceLength else {
            return nil
        }

        let visibleLength = visibleText.utf16.count
        if requested.length == 0 {
            let offset = requested.location
            if let exact = mappings.first(where: { $0.sourceRange.location == offset }) {
                return NSRange(location: exact.visibleRange.location, length: 0)
            }
            if let containing = mappings.first(where: {
                offset > $0.sourceRange.location && offset < $0.sourceRange.upperBound
            }) {
                let delta = offset - containing.sourceRange.location
                return NSRange(location: containing.visibleRange.location + delta, length: 0)
            }
            if let previous = mappings.last(where: { $0.sourceRange.upperBound <= offset }) {
                return NSRange(location: previous.visibleRange.upperBound, length: 0)
            }
            return NSRange(location: 0, length: 0)
        }

        let intersecting = mappings.filter {
            NSIntersectionRange($0.sourceRange, requested).length > 0
        }
        guard let first = intersecting.first, let last = intersecting.last else {
            return NSRange(location: min(requested.location, visibleLength), length: 0)
        }
        let lowerSource = max(requested.location, first.sourceRange.location)
        let upperSource = min(requested.upperBound, last.sourceRange.upperBound)
        let lower = first.visibleRange.location + lowerSource - first.sourceRange.location
        let upper = last.visibleRange.location + upperSource - last.sourceRange.location
        guard lower <= upper else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    var outline: [WiskMarkdownOutlineItem] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let title = block.visibleText.trimmingCharacters(in: .newlines)
            return WiskMarkdownOutlineItem(level: level, title: title, sourceRange: block.sourceRange)
        }
    }

    var tables: [WiskMarkdownTable] {
        WiskMarkdownTableSyntax.tables(in: self)
    }
}

struct WiskMarkdownOutlineItem: Sendable, Equatable, Identifiable {
    let level: Int
    let title: String
    let sourceRange: NSRange

    var id: Int { sourceRange.location }
}

struct WiskMarkdownBlock: Sendable, Equatable, Identifiable {
    let id: Int
    let kind: WiskMarkdownBlockKind
    let sourceRange: NSRange
    let contentSourceRange: NSRange
    let rawSource: String
    let visibleText: String
    let inlineSpans: [WiskMarkdownInlineSpan]
    var tableCells: [WiskMarkdownTableCell] = []

    var sourceUTF16Range: Range<Int> {
        sourceRange.location..<sourceRange.upperBound
    }
}

enum WiskMarkdownBlockKind: Sendable, Equatable {
    case paragraph
    case heading(level: Int)
    case bullet
    case ordered(number: Int)
    case task(checked: Bool)
    case quote
    case separator
    case fencedCode(language: String?)
    case tableRow
    case tableDivider
    case footnoteDefinition(label: String)
    case callout(kind: String?)
    case attachment(WiskMarkdownAttachment)
    case blankLine
}

struct WiskMarkdownAttachment: Sendable, Equatable {
    let id: UUID
    let title: String
    let isImage: Bool

    var URLString: String {
        "wisk-attachment://\(id.uuidString)"
    }
}

struct WiskMarkdownInlineSpan: Sendable, Equatable, Identifiable {
    let id: Int
    let kind: WiskMarkdownInlineKind
    let sourceRange: NSRange
    let visibleRange: NSRange
    let rawSource: String
    let visibleText: String
    let children: [WiskMarkdownInlineSpan]
}

enum WiskMarkdownInlineKind: Sendable, Equatable {
    case bold
    case italic
    case underline
    case strikethrough
    case highlight
    case code
    case link(destination: String)
    case wikilink(target: String)
    case footnoteReference(label: String)
    case tag(name: String)
}

/// A one-to-one UTF-16 slice copied from source into rendered text.
struct WiskMarkdownTextMapping: Sendable, Equatable {
    let visibleRange: NSRange
    let sourceRange: NSRange
}

struct WiskMarkdownMutation: Sendable, Equatable {
    let source: String
    let selectedSourceRange: NSRange
}

struct WiskMarkdownListContinuation: Sendable, Equatable {
    let insertion: String
    let shouldTerminateList: Bool
}

enum WiskMarkdownDocumentEngine {
    private final class RegularExpressionCache: @unchecked Sendable {
        private let storage = NSCache<NSString, NSRegularExpression>()

        func expression(for pattern: String) -> NSRegularExpression? {
            let key = pattern as NSString
            if let cached = storage.object(forKey: key) {
                return cached
            }
            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            storage.setObject(compiled, forKey: key)
            return compiled
        }
    }

    private static let regularExpressionCache = RegularExpressionCache()

    static func parse(_ source: String) -> WiskMarkdownDocument {
        parseFull(source)
    }

    /// Reuses `previous` when `dirtySourceRange` is a single-line edit.
    /// Falls back to a full parse for newlines, fences, tables, or attachments.
    static func parse(
        _ source: String,
        previous: WiskMarkdownDocument?,
        dirtySourceRange: NSRange?
    ) -> WiskMarkdownDocument {
        if let previous, let dirtySourceRange,
           let spliced = spliceLineEdit(source, previous: previous, dirtySourceRange: dirtySourceRange) {
            return spliced
        }
        return parseFull(source)
    }

    /// Classifies every block, but runs inline parsing only inside `inlineSourceRange`.
    static func parseDeferringInline(_ source: String, inlineSourceRange: NSRange) -> WiskMarkdownDocument {
        parseFull(source, inlineSourceRange: inlineSourceRange)
    }

    static func parseFull(_ source: String, inlineSourceRange: NSRange? = nil) -> WiskMarkdownDocument {
        let lines = sourceLines(source)
        var blocks: [WiskMarkdownBlock] = []
        var documentVisibleParts: [String] = []
        documentVisibleParts.reserveCapacity(lines.count)
        var documentVisibleLength = 0
        var documentMappings: [WiskMarkdownTextMapping] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let body = substring(source, range: line.contentRange)

            if let fence = fencedCodeOpening(body) {
                var closingIndex: Int?
                var candidate = lineIndex + 1
                while candidate < lines.count {
                    let candidateBody = substring(source, range: lines[candidate].contentRange)
                    if isFenceClosing(candidateBody, marker: fence.marker) {
                        closingIndex = candidate
                        break
                    }
                    candidate += 1
                }

                let lastIndex = closingIndex ?? (lines.count - 1)
                let blockRange = NSRange(
                    location: line.fullRange.location,
                    length: lines[lastIndex].fullRange.upperBound - line.fullRange.location
                )
                let contentStart = line.fullRange.upperBound
                let contentEnd = closingIndex.map { lines[$0].fullRange.location } ?? blockRange.upperBound
                let contentRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
                let visible = substring(source, range: contentRange)
                let visibleStart = documentVisibleLength
                documentVisibleParts.append(visible)
                documentVisibleLength += visible.utf16.count
                if contentRange.length > 0 {
                    documentMappings.append(
                        WiskMarkdownTextMapping(
                            visibleRange: NSRange(location: visibleStart, length: contentRange.length),
                            sourceRange: contentRange
                        )
                    )
                }
                blocks.append(
                    WiskMarkdownBlock(
                        id: blocks.count,
                        kind: .fencedCode(language: fence.language),
                        sourceRange: blockRange,
                        contentSourceRange: contentRange,
                        rawSource: substring(source, range: blockRange),
                        visibleText: visible,
                        inlineSpans: []
                    )
                )
                lineIndex = lastIndex + 1
                continue
            }

            if let table = WiskMarkdownTableSyntax.table(
                startingAt: lineIndex,
                lines: lines,
                source: source
            ) {
                for row in table.rows {
                    let visibleStart = documentVisibleLength
                    if row.isDivider {
                        blocks.append(
                            WiskMarkdownBlock(
                                id: blocks.count,
                                kind: .tableDivider,
                                sourceRange: row.sourceRange,
                                contentSourceRange: row.contentRange,
                                rawSource: row.rawSource,
                                visibleText: "",
                                inlineSpans: [],
                                tableCells: row.cells
                            )
                        )
                        continue
                    }

                    var visible = ""
                    var rowMappings: [WiskMarkdownTextMapping] = []
                    for cell in row.cells {
                        let cellVisibleStart = visibleStart + visible.utf16.count
                        visible += cell.text
                        if cell.sourceRange.length > 0 {
                            rowMappings.append(
                                WiskMarkdownTextMapping(
                                    visibleRange: NSRange(location: cellVisibleStart, length: cell.text.utf16.count),
                                    sourceRange: cell.sourceRange
                                )
                            )
                        }
                    }
                    let newline = substring(source, range: row.newlineRange)
                    let newlineVisibleStart = visibleStart + visible.utf16.count
                    visible += newline
                    if row.newlineRange.length > 0 {
                        rowMappings.append(
                            WiskMarkdownTextMapping(
                                visibleRange: NSRange(location: newlineVisibleStart, length: row.newlineRange.length),
                                sourceRange: row.newlineRange
                            )
                        )
                    }
                    documentVisibleParts.append(visible)
                    documentVisibleLength += visible.utf16.count
                    documentMappings.append(contentsOf: rowMappings)
                    blocks.append(
                        WiskMarkdownBlock(
                            id: blocks.count,
                            kind: .tableRow,
                            sourceRange: row.sourceRange,
                            contentSourceRange: row.contentRange,
                            rawSource: row.rawSource,
                            visibleText: visible,
                            inlineSpans: [],
                            tableCells: row.cells
                        )
                    )
                }
                lineIndex += table.rows.count
                continue
            }

            let classification = classifyLine(body)
            let contentRange = NSRange(
                location: line.contentRange.location + classification.contentOffset,
                length: classification.contentLength
                    ?? max(0, line.contentRange.length - classification.contentOffset)
            )
            let shouldParseInline = shouldParseInline(
                contentRange: contentRange,
                inlineSourceRange: inlineSourceRange
            )
            let inline: InlineResult
            if shouldParseInline {
                inline = parseInline(
                    source: source,
                    range: contentRange,
                    visibleBase: documentVisibleLength,
                    nextID: 0
                )
            } else {
                inline = literalInline(
                    source: source,
                    range: contentRange,
                    visibleBase: documentVisibleLength
                )
            }
            let newline = substring(source, range: line.newlineRange)
            let newlineVisibleStart = documentVisibleLength + inline.visibleText.utf16.count
            let blockVisible = inline.visibleText + newline
            documentVisibleParts.append(blockVisible)
            documentVisibleLength += blockVisible.utf16.count
            documentMappings.append(contentsOf: inline.mappings)
            if line.newlineRange.length > 0 {
                documentMappings.append(
                    WiskMarkdownTextMapping(
                        visibleRange: NSRange(location: newlineVisibleStart, length: line.newlineRange.length),
                        sourceRange: line.newlineRange
                    )
                )
            }

            blocks.append(
                WiskMarkdownBlock(
                    id: blocks.count,
                    kind: classification.kind,
                    sourceRange: line.fullRange,
                    contentSourceRange: contentRange,
                    rawSource: substring(source, range: line.fullRange),
                    visibleText: blockVisible,
                    inlineSpans: inline.spans
                )
            )
            lineIndex += 1
        }

        return WiskMarkdownDocument(
            source: source,
            blocks: blocks,
            visibleText: documentVisibleParts.joined(),
            mappings: documentMappings
        )
    }

    private static func shouldParseInline(contentRange: NSRange, inlineSourceRange: NSRange?) -> Bool {
        guard let inlineSourceRange else { return true }
        if NSIntersectionRange(contentRange, inlineSourceRange).length > 0 {
            return true
        }
        if inlineSourceRange.length == 0,
           inlineSourceRange.location >= contentRange.location,
           inlineSourceRange.location <= contentRange.upperBound {
            return true
        }
        return false
    }

    private static func literalInline(
        source: String,
        range: NSRange,
        visibleBase: Int
    ) -> InlineResult {
        guard range.length > 0 else {
            return InlineResult(visibleText: "", spans: [], mappings: [], nextID: 0)
        }
        let visible = substring(source, range: range)
        return InlineResult(
            visibleText: visible,
            spans: [],
            mappings: [
                WiskMarkdownTextMapping(
                    visibleRange: NSRange(location: visibleBase, length: range.length),
                    sourceRange: range
                ),
            ],
            nextID: 0
        )
    }

    private static func spliceLineEdit(
        _ source: String,
        previous: WiskMarkdownDocument,
        dirtySourceRange: NSRange
    ) -> WiskMarkdownDocument? {
        let oldNS = previous.source as NSString
        let newNS = source as NSString
        guard dirtySourceRange.location >= 0,
              dirtySourceRange.upperBound <= oldNS.length else {
            return nil
        }

        let delta = newNS.length - oldNS.length
        let replacementLength = dirtySourceRange.length + delta
        guard replacementLength >= 0,
              dirtySourceRange.location + replacementLength <= newNS.length else {
            return nil
        }

        let oldSlice = oldNS.substring(with: dirtySourceRange)
        let newSlice = newNS.substring(with: NSRange(location: dirtySourceRange.location, length: replacementLength))
        if oldSlice.contains("\n") || newSlice.contains("\n") {
            return nil
        }

        guard let blockIndex = previous.blocks.firstIndex(where: { block in
            dirtySourceRange.location >= block.sourceRange.location
                && dirtySourceRange.location <= block.sourceRange.upperBound
        }) else {
            return nil
        }

        let oldBlock = previous.blocks[blockIndex]
        if isStructuralBlock(oldBlock.kind) {
            return nil
        }

        let newBlockSourceRange = NSRange(
            location: oldBlock.sourceRange.location,
            length: oldBlock.sourceRange.length + delta
        )
        guard newBlockSourceRange.location >= 0,
              newBlockSourceRange.upperBound <= newNS.length else {
            return nil
        }

        let newBlockSource = newNS.substring(with: newBlockSourceRange)
        let parsedLine = parseFull(newBlockSource)
        guard parsedLine.blocks.count == 1, let miniBlock = parsedLine.blocks.first else {
            return nil
        }
        if isStructuralBlock(miniBlock.kind) {
            return nil
        }

        let prefixVisibleLength = previous.blocks.prefix(blockIndex).reduce(0) { $0 + $1.visibleText.utf16.count }
        let rebuiltMini = offsetBlock(
            miniBlock,
            sourceBy: oldBlock.sourceRange.location,
            visibleBy: prefixVisibleLength,
            id: blockIndex
        )
        let visibleDelta = rebuiltMini.visibleText.utf16.count - oldBlock.visibleText.utf16.count

        var blocks: [WiskMarkdownBlock] = []
        blocks.reserveCapacity(previous.blocks.count)
        for (index, block) in previous.blocks.enumerated() {
            if index < blockIndex {
                blocks.append(reindexedBlock(block, id: index))
            } else if index == blockIndex {
                blocks.append(reindexedBlock(rebuiltMini, id: index))
            } else {
                blocks.append(
                    offsetBlock(block, sourceBy: delta, visibleBy: visibleDelta, id: index)
                )
            }
        }

        let prefixVisible = previous.blocks.prefix(blockIndex).map(\.visibleText).joined()
        let suffixVisible = previous.blocks.dropFirst(blockIndex + 1).map(\.visibleText).joined()
        let visibleText = prefixVisible + rebuiltMini.visibleText + suffixVisible

        let prefixMappings = previous.mappings.filter { $0.sourceRange.upperBound <= oldBlock.sourceRange.location }
        let middleMappings = parsedLine.mappings.map { mapping in
            WiskMarkdownTextMapping(
                visibleRange: offset(mapping.visibleRange, by: prefixVisibleLength),
                sourceRange: offset(mapping.sourceRange, by: oldBlock.sourceRange.location)
            )
        }
        let suffixMappings = previous.mappings.compactMap { mapping -> WiskMarkdownTextMapping? in
            guard mapping.sourceRange.location >= oldBlock.sourceRange.upperBound else { return nil }
            return WiskMarkdownTextMapping(
                visibleRange: offset(mapping.visibleRange, by: visibleDelta),
                sourceRange: offset(mapping.sourceRange, by: delta)
            )
        }

        return WiskMarkdownDocument(
            source: source,
            blocks: blocks,
            visibleText: visibleText,
            mappings: prefixMappings + middleMappings + suffixMappings
        )
    }

    private static func isStructuralBlock(_ kind: WiskMarkdownBlockKind) -> Bool {
        switch kind {
        case .fencedCode, .tableRow, .tableDivider, .attachment:
            return true
        default:
            return false
        }
    }

    private static func reindexedBlock(_ block: WiskMarkdownBlock, id: Int) -> WiskMarkdownBlock {
        WiskMarkdownBlock(
            id: id,
            kind: block.kind,
            sourceRange: block.sourceRange,
            contentSourceRange: block.contentSourceRange,
            rawSource: block.rawSource,
            visibleText: block.visibleText,
            inlineSpans: block.inlineSpans,
            tableCells: block.tableCells
        )
    }

    private static func offsetBlock(
        _ block: WiskMarkdownBlock,
        sourceBy sourceBy: Int,
        visibleBy visibleBy: Int,
        id: Int
    ) -> WiskMarkdownBlock {
        WiskMarkdownBlock(
            id: id,
            kind: block.kind,
            sourceRange: offset(block.sourceRange, by: sourceBy),
            contentSourceRange: offset(block.contentSourceRange, by: sourceBy),
            rawSource: block.rawSource,
            visibleText: block.visibleText,
            inlineSpans: block.inlineSpans.map { offsetSpan($0, sourceBy: sourceBy, visibleBy: visibleBy) },
            tableCells: block.tableCells.map { cell in
                WiskMarkdownTableCell(
                    sourceRange: offset(cell.sourceRange, by: sourceBy),
                    text: cell.text
                )
            }
        )
    }

    private static func offsetSpan(
        _ span: WiskMarkdownInlineSpan,
        sourceBy: Int,
        visibleBy: Int
    ) -> WiskMarkdownInlineSpan {
        WiskMarkdownInlineSpan(
            id: span.id,
            kind: span.kind,
            sourceRange: offset(span.sourceRange, by: sourceBy),
            visibleRange: offset(span.visibleRange, by: visibleBy),
            rawSource: span.rawSource,
            visibleText: span.visibleText,
            children: span.children.map { offsetSpan($0, sourceBy: sourceBy, visibleBy: visibleBy) }
        )
    }

    static func serialize(_ document: WiskMarkdownDocument) -> String {
        document.serializedSource()
    }

    /// Applies a formatting action to a rendered-editor selection.
    ///
    /// Inline wrappers toggle when the exact wrapper surrounds the selection.
    /// Block actions toggle prefixes on every selected line, including blank
    /// lines so a caret can start a list. Existing unrelated source is preserved.
    static func apply(
        _ action: WiskMarkdownFormattingAction,
        to source: String,
        visibleRange: NSRange
    ) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let selected = document.sourceNSRange(forVisibleRange: visibleRange) else { return nil }
        return apply(action, to: source, sourceRange: selected)
    }

    static func apply(
        _ action: WiskMarkdownFormattingAction,
        to source: String,
        sourceRange selected: NSRange
    ) -> WiskMarkdownMutation? {
        guard isValidSourceRange(selected, in: source) else { return nil }

        switch action {
        case .bold:
            return toggleWrapper("**", close: "**", in: source, range: selected)
        case .italic:
            return toggleWrapper("*", close: "*", in: source, range: selected)
        case .underline:
            return toggleWrapper("<u>", close: "</u>", in: source, range: selected)
        case .strikethrough:
            return toggleWrapper("~~", close: "~~", in: source, range: selected)
        case .highlight:
            return toggleWrapper("==", close: "==", in: source, range: selected)
        case .code:
            if substring(source, range: selected).contains("\n") {
                return toggleWrapper("```\n", close: "\n```", in: source, range: selected)
            }
            return toggleWrapper("`", close: "`", in: source, range: selected)
        case .heading:
            return toggleLinePrefix(in: source, range: selected, prefix: "# ", familyPattern: #"^\s{0,3}#{1,6}\s+"#)
        case .bullet:
            return toggleLinePrefix(in: source, range: selected, prefix: "- ", familyPattern: #"^\s*[-+*]\s+"#)
        case .numberedList:
            return toggleNumberedPrefixes(in: source, range: selected)
        case .checklist:
            return toggleLinePrefix(in: source, range: selected, prefix: "- [ ] ", familyPattern: #"^\s*[-+*]\s+\[[ xX]\]\s+"#)
        case .quote:
            return toggleLinePrefix(in: source, range: selected, prefix: "> ", familyPattern: #"^\s*>\s?"#)
        case .link:
            return toggleLink(in: source, range: selected)
        case .table:
            let selectedText = substring(source, range: selected)
            let insertion: String
            if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertion = "| Item | Notes |\n| --- | --- |\n| Example | Detail |"
            } else {
                let rows = selectedText.components(separatedBy: .newlines).filter {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }
                insertion = "| Item | Notes |\n| --- | --- |\n" + rows.map { "| \($0) |  |" }.joined(separator: "\n")
            }
            return replacing(source, range: selected, with: insertion, selectionOffset: 0, selectionLength: insertion.utf16.count)
        }
    }

    /// Returns the prefix to insert after Return for a supported list line.
    /// Empty list items request termination and removal of the current prefix.
    static func listContinuation(after line: String) -> WiskMarkdownListContinuation? {
        let text = line.trimmingCharacters(in: .newlines)
        if let match = firstMatch(#"^(\s*)[-+*]\s+\[([ xX])\]\s*(.*)$"#, in: text) {
            let indent = capture(match, 1, in: text)
            let content = capture(match, 3, in: text)
            return WiskMarkdownListContinuation(
                insertion: content.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\(indent)- [ ] ",
                shouldTerminateList: content.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        if let match = firstMatch(#"^(\s*)(\d+)([.)])\s+(.*)$"#, in: text),
           let number = Int(capture(match, 2, in: text)) {
            let indent = capture(match, 1, in: text)
            let punctuation = capture(match, 3, in: text)
            let content = capture(match, 4, in: text)
            return WiskMarkdownListContinuation(
                insertion: content.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\(indent)\(number + 1)\(punctuation) ",
                shouldTerminateList: content.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        if let match = firstMatch(#"^(\s*)([-+*])\s+(.*)$"#, in: text) {
            let indent = capture(match, 1, in: text)
            let marker = capture(match, 2, in: text)
            let content = capture(match, 3, in: text)
            return WiskMarkdownListContinuation(
                insertion: content.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\(indent)\(marker) ",
                shouldTerminateList: content.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        return nil
    }

    static func indentLines(
        in source: String,
        sourceRange: NSRange,
        outdent: Bool = false
    ) -> WiskMarkdownMutation? {
        guard sourceRange.location >= 0,
              sourceRange.length >= 0,
              sourceRange.upperBound <= source.utf16.count,
              Range(sourceRange, in: source) != nil else {
            return nil
        }
        return mutateSelectedLines(in: source, range: sourceRange) { lines in
            lines.map { line in
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return line }
                if outdent {
                    if line.hasPrefix("\t") {
                        return String(line.dropFirst())
                    }
                    let removableSpaces = min(2, line.prefix(while: { $0 == " " }).count)
                    return String(line.dropFirst(removableSpaces))
                }
                return "  " + line
            }
        }
    }

    /// Allows only user-navigation schemes used by Wisk. Relative URLs are
    /// accepted; protocol-relative, credential-bearing, malformed, and active
    /// content URLs are rejected. Attachment URLs must contain only a UUID.
    static func isSafeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("//"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: trimmed) else {
            return false
        }
        guard let scheme = components.scheme?.lowercased() else {
            return !trimmed.hasPrefix("\\")
        }
        guard components.user == nil, components.password == nil else { return false }
        switch scheme {
        case "https", "http":
            return components.host?.isEmpty == false
        case "mailto":
            return !components.path.isEmpty
        case "tel":
            return !components.path.isEmpty
        case "wisk-attachment":
            let rawID = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return UUID(uuidString: rawID) != nil
                && components.query == nil
                && components.fragment == nil
        case "wisk-note":
            return components.host != nil || !components.path.isEmpty
        default:
            return false
        }
    }

    static func isSafeURL(_ url: URL) -> Bool {
        isSafeURL(url.absoluteString)
    }

    /// Replaces a rendered visible UTF-16 range by editing the exact mapped source slice.
    static func replaceVisibleRange(
        in source: String,
        visibleRange: NSRange,
        with replacement: String
    ) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let sourceRange = document.sourceNSRange(forVisibleRange: visibleRange) else { return nil }
        return replaceSourceRange(in: source, sourceRange: sourceRange, with: replacement)
    }

    /// Toggles `- [ ]` / `- [x]` on the source line that contains `sourceLocation`.
    static func toggleChecklist(in source: String, sourceLocation: Int) -> WiskMarkdownMutation? {
        guard let lineRange = lineContentRange(containing: sourceLocation, in: source) else { return nil }
        let line = substring(source, range: lineRange)
        guard let match = firstMatch(#"^(\s*[-+*]\s+\[)([ xX])(\])"#, in: line) else { return nil }
        let boxRange = match.range(at: 2)
        guard boxRange.location != NSNotFound else { return nil }
        let checked = capture(match, 2, in: line).lowercased() == "x"
        let replacement = checked ? " " : "x"
        let absolute = NSRange(location: lineRange.location + boxRange.location, length: boxRange.length)
        return replacing(
            source,
            range: absolute,
            with: replacement,
            selectionOffset: replacement.utf16.count,
            selectionLength: 0
        )
    }

    static func checklistMarkerRange(in line: String) -> NSRange? {
        firstMatch(#"^(\s*[-+*]\s+)(\[[ xX]\])"#, in: line)?.range(at: 2)
    }

    static func replaceSourceRange(
        in source: String,
        sourceRange: NSRange,
        with replacement: String
    ) -> WiskMarkdownMutation? {
        guard isValidSourceRange(sourceRange, in: source) else { return nil }
        return replacing(
            source,
            range: sourceRange,
            with: replacement,
            selectionOffset: (replacement as NSString).length,
            selectionLength: 0
        )
    }

    /// Inserts a newline, continuing or terminating the current list from the source caret.
    static func applyReturn(in source: String, sourceRange: NSRange) -> WiskMarkdownMutation? {
        guard isValidSourceRange(sourceRange, in: source) else { return nil }
        let afterDelete = (source as NSString).replacingCharacters(in: sourceRange, with: "")
        let caret = sourceRange.location
        guard let lineRange = lineContentRange(containing: caret, in: afterDelete) else {
            return replacing(afterDelete, range: NSRange(location: caret, length: 0), with: "\n", selectionOffset: 1, selectionLength: 0)
        }
        let lineText = substring(afterDelete, range: lineRange)
        if let tableMutation = applyTableReturn(in: afterDelete, caret: caret) {
            return tableMutation
        }
        if let continuation = listContinuation(after: lineText) {
            if continuation.shouldTerminateList {
                return replacing(afterDelete, range: lineRange, with: "", selectionOffset: 0, selectionLength: 0)
            }
            let insertion = "\n" + continuation.insertion
            return replacing(
                afterDelete,
                range: NSRange(location: caret, length: 0),
                with: insertion,
                selectionOffset: (insertion as NSString).length,
                selectionLength: 0
            )
        }
        return replacing(
            afterDelete,
            range: NSRange(location: caret, length: 0),
            with: "\n",
            selectionOffset: 1,
            selectionLength: 0
        )
    }

    static func headingSourceRange(_ heading: String, in source: String) -> NSRange? {
        parse(source).outline.first { item in
            item.title.compare(heading, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }?.sourceRange
    }

    static func wikiLinkPartial(in source: String, sourceCaret: Int) -> String? {
        guard sourceCaret >= 0, sourceCaret <= source.utf16.count else { return nil }
        let prefix = (source as NSString).substring(to: sourceCaret)
        guard let open = prefix.range(of: "[[", options: .backwards) else { return nil }
        let afterOpen = String(prefix[open.upperBound...])
        if afterOpen.contains("]]") { return nil }
        return afterOpen
    }

    static func wikiLinkReplacement(title: String, partial: String) -> String {
        if let pipe = partial.firstIndex(of: "|") {
            let alias = String(partial[partial.index(after: pipe)...])
            return "[[\(title)|\(alias)]]"
        }
        return "[[\(title)]]"
    }
}

extension WiskMarkdownDocumentEngine {
    struct SourceLine: Sendable, Equatable {
        let fullRange: NSRange
        let contentRange: NSRange
        let newlineRange: NSRange
    }
}

extension WiskMarkdownDocumentEngine {
    struct LineClassification {
        let kind: WiskMarkdownBlockKind
        let contentOffset: Int
        let contentLength: Int?

        init(kind: WiskMarkdownBlockKind, contentOffset: Int, contentLength: Int? = nil) {
            self.kind = kind
            self.contentOffset = contentOffset
            self.contentLength = contentLength
        }
    }

    struct FenceOpening {
        let marker: String
        let language: String?
    }

    struct InlineResult {
        let visibleText: String
        let spans: [WiskMarkdownInlineSpan]
        let mappings: [WiskMarkdownTextMapping]
        let nextID: Int
    }

    struct InlineToken {
        let kind: WiskMarkdownInlineKind
        let fullRange: NSRange
        let contentRange: NSRange
        let recursivelyParsesContent: Bool
    }

    static func lineContentRange(containing location: Int, in source: String) -> NSRange? {
        let lines = sourceLines(source)
        guard !lines.isEmpty else {
            return source.isEmpty ? NSRange(location: 0, length: 0) : nil
        }
        if let line = lines.first(where: { location >= $0.fullRange.location && location <= $0.fullRange.upperBound }) {
            return line.contentRange
        }
        if location >= (source as NSString).length, let last = lines.last {
            return last.contentRange
        }
        return lines.last?.contentRange
    }

    static func sourceLines(_ source: String) -> [SourceLine] {
        let ns = source as NSString
        guard ns.length > 0 else { return [] }
        var result: [SourceLine] = []
        var cursor = 0
        while cursor < ns.length {
            var end = cursor
            while end < ns.length {
                let unit = ns.character(at: end)
                if unit == 10 || unit == 13 { break }
                end += 1
            }
            var newlineEnd = end
            if newlineEnd < ns.length {
                if ns.character(at: newlineEnd) == 13,
                   newlineEnd + 1 < ns.length,
                   ns.character(at: newlineEnd + 1) == 10 {
                    newlineEnd += 2
                } else {
                    newlineEnd += 1
                }
            }
            result.append(
                SourceLine(
                    fullRange: NSRange(location: cursor, length: newlineEnd - cursor),
                    contentRange: NSRange(location: cursor, length: end - cursor),
                    newlineRange: NSRange(location: end, length: newlineEnd - end)
                )
            )
            cursor = newlineEnd
        }
        return result
    }

    static func classifyLine(_ line: String) -> LineClassification {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            return LineClassification(kind: .blankLine, contentOffset: 0)
        }
        if let attachment = attachment(from: line) {
            return LineClassification(
                kind: .attachment(attachment.value),
                contentOffset: attachment.contentRange.location,
                contentLength: attachment.contentRange.length
            )
        }
        if let match = firstMatch(#"^\s{0,3}(#{1,6})[ \t]+(.*)$"#, in: line) {
            return LineClassification(
                kind: .heading(level: capture(match, 1, in: line).utf16.count),
                contentOffset: match.range(at: 2).location
            )
        }
        if let match = firstMatch(#"^(\s*)[-+*]\s+\[([ xX])\]\s+(.*)$"#, in: line) {
            return LineClassification(
                kind: .task(checked: capture(match, 2, in: line).lowercased() == "x"),
                contentOffset: match.range(at: 3).location
            )
        }
        if let match = firstMatch(#"^(\s*)[-+*]\s+(.*)$"#, in: line) {
            return LineClassification(kind: .bullet, contentOffset: match.range(at: 2).location)
        }
        if let match = firstMatch(#"^(\s*)(\d+)[.)]\s+(.*)$"#, in: line) {
            return LineClassification(
                kind: .ordered(number: Int(capture(match, 2, in: line)) ?? 1),
                contentOffset: match.range(at: 3).location
            )
        }
        if let match = firstMatch(#"^\s*>\s*\[!([A-Za-z][A-Za-z0-9_-]*)\]\s*(.*)$"#, in: line) {
            return LineClassification(
                kind: .callout(kind: capture(match, 1, in: line).uppercased()),
                contentOffset: match.range(at: 2).location
            )
        }
        if let match = firstMatch(#"^\s*>\s?(.*)$"#, in: line) {
            return LineClassification(kind: .quote, contentOffset: match.range(at: 1).location)
        }
        if isSeparator(line) {
            return LineClassification(kind: .separator, contentOffset: line.utf16.count)
        }
        if let match = firstMatch(#"^\s*\[\^([^\]\r\n]+)\]:\s*(.*)$"#, in: line) {
            return LineClassification(
                kind: .footnoteDefinition(label: capture(match, 1, in: line)),
                contentOffset: match.range(at: 2).location
            )
        }
        if isTableDivider(line) {
            return LineClassification(kind: .tableDivider, contentOffset: 0)
        }
        if isTableRow(line) {
            return LineClassification(kind: .tableRow, contentOffset: 0)
        }
        return LineClassification(kind: .paragraph, contentOffset: 0)
    }

    static func fencedCodeOpening(_ line: String) -> FenceOpening? {
        guard let match = firstMatch(#"^\s{0,3}(`{3,}|~{3,})\s*([^`]*)$"#, in: line) else { return nil }
        let marker = capture(match, 1, in: line)
        let languageText = capture(match, 2, in: line).trimmingCharacters(in: .whitespaces)
        return FenceOpening(marker: marker, language: languageText.isEmpty ? nil : languageText)
    }

    static func isFenceClosing(_ line: String, marker: String) -> Bool {
        let character = marker.first.map(String.init) ?? "`"
        let escaped = NSRegularExpression.escapedPattern(for: character)
        return firstMatch("^\\s{0,3}\(escaped){\(marker.count),}\\s*$", in: line) != nil
    }

    static func isSeparator(_ line: String) -> Bool {
        firstMatch(#"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#, in: line) != nil
    }

    static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|")
            && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
            && !isTableDivider(line)
    }

    static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|")
        return !cells.isEmpty && cells.allSatisfy {
            firstMatch(#"^\s*:?-{3,}:?\s*$"#, in: $0) != nil
        }
    }

    static func attachment(from line: String) -> (value: WiskMarkdownAttachment, contentRange: NSRange)? {
        guard let match = firstMatch(#"^\s*(!?)\[([^\]]*)\]\(wisk-attachment://([0-9A-Fa-f-]+)\)\s*$"#, in: line),
              let id = UUID(uuidString: capture(match, 3, in: line)) else {
            return nil
        }
        return (
            WiskMarkdownAttachment(
                id: id,
                title: capture(match, 2, in: line),
                isImage: capture(match, 1, in: line) == "!"
            ),
            match.range(at: 2)
        )
    }

    static func parseInline(
        source: String,
        range: NSRange,
        visibleBase: Int,
        nextID: Int
    ) -> InlineResult {
        guard range.length > 0 else {
            return InlineResult(visibleText: "", spans: [], mappings: [], nextID: nextID)
        }
        var visible = ""
        var spans: [WiskMarkdownInlineSpan] = []
        var mappings: [WiskMarkdownTextMapping] = []
        var cursor = range.location
        var identifier = nextID

        while cursor < range.upperBound {
            let searchRange = NSRange(location: cursor, length: range.upperBound - cursor)
            guard let token = nextInlineToken(source: source, searchRange: searchRange) else {
                appendLiteral(
                    source: source,
                    sourceRange: searchRange,
                    visibleBase: visibleBase,
                    visible: &visible,
                    mappings: &mappings
                )
                break
            }

            if token.fullRange.location > cursor {
                appendLiteral(
                    source: source,
                    sourceRange: NSRange(location: cursor, length: token.fullRange.location - cursor),
                    visibleBase: visibleBase,
                    visible: &visible,
                    mappings: &mappings
                )
            }

            let spanVisibleStart = visibleBase + visible.utf16.count
            var children: [WiskMarkdownInlineSpan] = []
            let tokenVisible: String
            if token.recursivelyParsesContent {
                let nested = parseInline(
                    source: source,
                    range: token.contentRange,
                    visibleBase: spanVisibleStart,
                    nextID: identifier + 1
                )
                tokenVisible = nested.visibleText
                children = nested.spans
                mappings.append(contentsOf: nested.mappings)
                identifier = nested.nextID
            } else {
                tokenVisible = substring(source, range: token.contentRange)
                if token.contentRange.length > 0 {
                    mappings.append(
                        WiskMarkdownTextMapping(
                            visibleRange: NSRange(location: spanVisibleStart, length: token.contentRange.length),
                            sourceRange: token.contentRange
                        )
                    )
                }
                identifier += 1
            }

            spans.append(
                WiskMarkdownInlineSpan(
                    id: identifier,
                    kind: token.kind,
                    sourceRange: token.fullRange,
                    visibleRange: NSRange(location: spanVisibleStart, length: tokenVisible.utf16.count),
                    rawSource: substring(source, range: token.fullRange),
                    visibleText: tokenVisible,
                    children: children
                )
            )
            identifier += 1
            visible += tokenVisible
            cursor = token.fullRange.upperBound
        }
        return InlineResult(visibleText: visible, spans: spans, mappings: mappings, nextID: identifier)
    }

    static func nextInlineToken(source: String, searchRange: NSRange) -> InlineToken? {
        let searched = substring(source, range: searchRange)
        var candidates: [InlineToken] = []

        func addWrapper(_ pattern: String, kind: WiskMarkdownInlineKind, recursive: Bool = true) {
            guard let match = firstMatch(pattern, in: searched) else { return }
            let full = offset(match.range(at: 0), by: searchRange.location)
            let content = offset(match.range(at: 1), by: searchRange.location)
            candidates.append(InlineToken(kind: kind, fullRange: full, contentRange: content, recursivelyParsesContent: recursive))
        }

        addWrapper(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, kind: .bold)
        addWrapper(#"~~(?=\S)(.+?)(?<=\S)~~"#, kind: .strikethrough)
        addWrapper(#"==(?=\S)(.+?)(?<=\S)=="#, kind: .highlight)
        addWrapper(#"<u>(.+?)</u>"#, kind: .underline)
        addWrapper(#"`([^`\r\n]+)`"#, kind: .code, recursive: false)
        addWrapper(#"(?<!\*)\*(?=\S)(.+?)(?<=\S)\*(?!\*)"#, kind: .italic)
        // CommonMark flanking for underscores: an intra-word `_`
        // (snake_case_test) must stay literal, otherwise the engine hides
        // markers the visible renderer keeps printing and every caret map
        // on the line drifts by the hidden marker width. The content may
        // not begin or end with `_` either, so triple-underscore runs
        // ("___", "___x") stay literal instead of parsing as emphasis.
        addWrapper(
            #"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=\S)(?<!_)_(?![\p{L}\p{N}_])"#,
            kind: .italic
        )

        if let match = firstMatch(#"\[([^\]\r\n]+)\]\(([^)\s]+)\)"#, in: searched) {
            let destination = capture(match, 2, in: searched)
            if !destination.lowercased().hasPrefix("wisk-attachment://") {
                candidates.append(
                    InlineToken(
                        kind: .link(destination: destination),
                        fullRange: offset(match.range(at: 0), by: searchRange.location),
                        contentRange: offset(match.range(at: 1), by: searchRange.location),
                        recursivelyParsesContent: true
                    )
                )
            }
        }
        if let match = firstMatch(#"\[\[([^\]|\r\n]+)(?:\|([^\]\r\n]+))?\]\]"#, in: searched) {
            let labelRange = match.range(at: 2).location == NSNotFound ? match.range(at: 1) : match.range(at: 2)
            candidates.append(
                InlineToken(
                    kind: .wikilink(target: capture(match, 1, in: searched)),
                    fullRange: offset(match.range(at: 0), by: searchRange.location),
                    contentRange: offset(labelRange, by: searchRange.location),
                    recursivelyParsesContent: true
                )
            )
        }
        if let match = firstMatch(#"\[\^([^\]\r\n]+)\]"#, in: searched) {
            candidates.append(
                InlineToken(
                    kind: .footnoteReference(label: capture(match, 1, in: searched)),
                    fullRange: offset(match.range(at: 0), by: searchRange.location),
                    contentRange: offset(match.range(at: 1), by: searchRange.location),
                    recursivelyParsesContent: false
                )
            )
        }
        if let match = firstMatch(#"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_][\p{L}\p{N}_-]*)"#, in: searched) {
            candidates.append(
                InlineToken(
                    kind: .tag(name: capture(match, 1, in: searched)),
                    fullRange: offset(match.range(at: 0), by: searchRange.location),
                    contentRange: offset(match.range(at: 0), by: searchRange.location),
                    recursivelyParsesContent: false
                )
            )
        }

        return candidates.min {
            if $0.fullRange.location == $1.fullRange.location {
                return $0.fullRange.length > $1.fullRange.length
            }
            return $0.fullRange.location < $1.fullRange.location
        }
    }

    static func appendLiteral(
        source: String,
        sourceRange: NSRange,
        visibleBase: Int,
        visible: inout String,
        mappings: inout [WiskMarkdownTextMapping]
    ) {
        guard sourceRange.length > 0 else { return }
        let start = visibleBase + visible.utf16.count
        visible += substring(source, range: sourceRange)
        mappings.append(
            WiskMarkdownTextMapping(
                visibleRange: NSRange(location: start, length: sourceRange.length),
                sourceRange: sourceRange
            )
        )
    }

    static func toggleWrapper(
        _ open: String,
        close: String,
        in source: String,
        range: NSRange
    ) -> WiskMarkdownMutation {
        let ns = source as NSString
        let openLength = open.utf16.count
        let closeLength = close.utf16.count
        let hasWrapper = range.location >= openLength
            && range.upperBound + closeLength <= ns.length
            && ns.substring(with: NSRange(location: range.location - openLength, length: openLength)) == open
            && ns.substring(with: NSRange(location: range.upperBound, length: closeLength)) == close

        if hasWrapper {
            let full = NSRange(
                location: range.location - openLength,
                length: openLength + range.length + closeLength
            )
            return replacing(
                source,
                range: full,
                with: substring(source, range: range),
                selectionOffset: 0,
                selectionLength: range.length
            )
        }

        let selectedText = substring(source, range: range)
        return replacing(
            source,
            range: range,
            with: open + selectedText + close,
            selectionOffset: openLength,
            selectionLength: range.length
        )
    }

    static func toggleLink(in source: String, range: NSRange) -> WiskMarkdownMutation {
        let selectedText = substring(source, range: range)
        if let match = firstMatch(#"^\[([^\]]+)\]\(([^)]+)\)$"#, in: selectedText) {
            let label = capture(match, 1, in: selectedText)
            return replacing(source, range: range, with: label, selectionOffset: 0, selectionLength: label.utf16.count)
        }
        let replacement = "[\(selectedText)](https://)"
        return replacing(
            source,
            range: range,
            with: replacement,
            selectionOffset: 1,
            selectionLength: selectedText.utf16.count
        )
    }

    static func toggleLinePrefix(
        in source: String,
        range: NSRange,
        prefix: String,
        familyPattern: String
    ) -> WiskMarkdownMutation {
        mutateSelectedLines(in: source, range: range) { lines in
            let populated = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let shouldRemove = !populated.isEmpty && populated.allSatisfy {
                firstMatch(familyPattern, in: $0) != nil
            }
            return lines.map { line in
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return shouldRemove ? line : prefix
                }
                if shouldRemove, let match = firstMatch(familyPattern, in: line) {
                    return (line as NSString).replacingCharacters(in: match.range(at: 0), with: "")
                }
                return shouldRemove ? line : prefix + line
            }
        }
    }

    static func toggleNumberedPrefixes(in source: String, range: NSRange) -> WiskMarkdownMutation {
        mutateSelectedLines(in: source, range: range) { lines in
            let pattern = #"^\s*\d+[.)]\s+"#
            let populated = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let shouldRemove = !populated.isEmpty && populated.allSatisfy {
                firstMatch(pattern, in: $0) != nil
            }
            var number = 1
            return lines.map { line in
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard shouldRemove == false else { return line }
                    defer { number += 1 }
                    return "\(number). "
                }
                if shouldRemove, let match = firstMatch(pattern, in: line) {
                    return (line as NSString).replacingCharacters(in: match.range(at: 0), with: "")
                }
                defer { number += 1 }
                return "\(number). \(line)"
            }
        }
    }

    static func mutateSelectedLines(
        in source: String,
        range: NSRange,
        transform: ([String]) -> [String]
    ) -> WiskMarkdownMutation {
        let ns = source as NSString
        var start = range.location
        while start > 0 {
            let unit = ns.character(at: start - 1)
            if unit == 10 || unit == 13 { break }
            start -= 1
        }
        var end = range.upperBound
        while end < ns.length {
            let unit = ns.character(at: end)
            if unit == 10 || unit == 13 { break }
            end += 1
        }
        let lineRange = NSRange(location: start, length: end - start)
        let original = ns.substring(with: lineRange)
        let lines = original.components(separatedBy: "\n")
        let transformed = transform(lines)
        let replacement = transformed.joined(separator: "\n")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        let selectedSourceRange: NSRange
        if range.length == 0 {
            let originalLine = lines.first ?? ""
            let newLine = transformed.first ?? ""
            let caretInLine = caretOffsetAfterLineMutation(
                originalLine: originalLine,
                newLine: newLine,
                originalOffsetInLine: range.location - start
            )
            selectedSourceRange = NSRange(location: start + caretInLine, length: 0)
        } else {
            selectedSourceRange = NSRange(location: start, length: (replacement as NSString).length)
        }
        return WiskMarkdownMutation(source: updated, selectedSourceRange: selectedSourceRange)
    }

    static func isValidSourceRange(_ selected: NSRange, in source: String) -> Bool {
        guard selected.location >= 0,
              selected.length >= 0,
              selected.upperBound <= source.utf16.count else {
            return false
        }
        if source.isEmpty {
            return selected.location == 0 && selected.length == 0
        }
        return Range(selected, in: source) != nil
    }

    static func caretOffsetAfterLineMutation(
        originalLine: String,
        newLine: String,
        originalOffsetInLine: Int
    ) -> Int {
        let originalLength = (originalLine as NSString).length
        let newLength = (newLine as NSString).length
        let clampedOriginalOffset = min(max(originalOffsetInLine, 0), originalLength)

        if originalLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return newLength
        }
        if newLength >= originalLength, newLine.hasSuffix(originalLine) {
            if clampedOriginalOffset == 0 {
                return 0
            }
            return (newLength - originalLength) + clampedOriginalOffset
        }
        if originalLength >= newLength {
            return min(max(clampedOriginalOffset - (originalLength - newLength), 0), newLength)
        }
        return min(clampedOriginalOffset, newLength)
    }

    static func replacing(
        _ source: String,
        range: NSRange,
        with replacement: String,
        selectionOffset: Int,
        selectionLength: Int
    ) -> WiskMarkdownMutation {
        let updated = (source as NSString).replacingCharacters(in: range, with: replacement)
        return WiskMarkdownMutation(
            source: updated,
            selectedSourceRange: NSRange(
                location: range.location + selectionOffset,
                length: selectionLength
            )
        )
    }

    static func firstMatch(_ pattern: String, in string: String) -> NSTextCheckingResult? {
        guard let expression = regularExpressionCache.expression(for: pattern) else { return nil }
        return expression.firstMatch(
            in: string,
            range: NSRange(location: 0, length: string.utf16.count)
        )
    }

    static func capture(_ match: NSTextCheckingResult, _ index: Int, in string: String) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (string as NSString).substring(with: range)
    }

    static func substring(_ source: String, range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    static func offset(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
