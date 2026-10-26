import Foundation
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension NSAttributedString.Key {
    static let wiskMarkdownHeadingLevel = NSAttributedString.Key("wisk.markdown.headingLevel")
    static let wiskMarkdownBlockKind = NSAttributedString.Key("wisk.markdown.blockKind")
    static let wiskMarkdownListNumber = NSAttributedString.Key("wisk.markdown.listNumber")
    static let wiskMarkdownAttachmentID = NSAttributedString.Key("wisk.markdown.attachmentID")
    static let wiskMarkdownAttachmentTitle = NSAttributedString.Key("wisk.markdown.attachmentTitle")
    static let wiskMarkdownAttachmentIsImage = NSAttributedString.Key("wisk.markdown.attachmentIsImage")
    static let wiskMarkdownInlineBold = NSAttributedString.Key("wisk.markdown.inlineBold")
    static let wiskMarkdownInlineItalic = NSAttributedString.Key("wisk.markdown.inlineItalic")
    static let wiskMarkdownInlineCode = NSAttributedString.Key("wisk.markdown.inlineCode")
    static let wiskMarkdownInlineHighlight = NSAttributedString.Key("wisk.markdown.inlineHighlight")
    static let wiskSearchHighlight = NSAttributedString.Key("wisk.search.highlight")
    static let wiskMarkdownLinkDestination = NSAttributedString.Key("wisk.markdown.linkDestination")
    static let wiskMarkdownWikiLink = NSAttributedString.Key("wisk.markdown.wikiLink")
    static let wiskMarkdownFootnoteReference = NSAttributedString.Key("wisk.markdown.footnoteReference")
    static let wiskMarkdownTag = NSAttributedString.Key("wisk.markdown.tag")
    static let wiskMarkdownBlockSourceLocation = NSAttributedString.Key("wisk.markdown.blockSourceLocation")
    static let wiskMarkdownFoldable = NSAttributedString.Key("wisk.markdown.foldable")
}

enum WiskRichMarkdownDocument {
    enum FontWeight {
        case regular
        case medium
        case semibold
        case bold
    }

    enum BlockKind: String {
        case paragraph
        case heading
        case bullet
        case numbered
        case checklistUnchecked
        case checklistChecked
        case quote
        case separator
        case codeFence
        case table
        case footnote
        case callout
        case attachmentImage
        case attachmentFile
    }

    private struct RenderedBlock {
        var kind: BlockKind
        var headingLevel: Int?
        var listNumber: Int?
        var attachmentID: UUID?
        var attachmentTitle: String?
        var attachmentIsImage: Bool?
        var visibleText: String
        var hiddenPrefixLength: Int
    }

    private struct BlockShortcut {
        var kind: BlockKind
        var level: Int?
        var listNumber: Int?
        var leadingWhitespaceLength: Int
        var markdownPrefixLength: Int
        var visiblePrefix: String
    }

    static func isChecklistToggleLocation(_ location: Int, in attributedString: NSAttributedString) -> Bool {
        guard attributedString.length > 0 else { return false }
        let ns = attributedString.string as NSString
        let clamped = min(max(location, 0), ns.length - 1)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        let lineRange = NSRange(location: lineStart, length: max(contentsEnd - lineStart, 0))
        guard lineRange.length > 0 else { return false }

        if let kindRaw = attributedString.attribute(.wiskMarkdownBlockKind, at: lineStart, effectiveRange: nil) as? String,
           kindRaw == BlockKind.checklistUnchecked.rawValue || kindRaw == BlockKind.checklistChecked.rawValue {
            let markerLength = min(2, lineRange.length)
            return NSLocationInRange(clamped, NSRange(location: lineStart, length: markerLength))
        }

        let line = ns.substring(with: lineRange)
        guard let marker = WiskMarkdownDocumentEngine.checklistMarkerRange(in: line),
              marker.location != NSNotFound else {
            return false
        }
        let absolute = NSRange(location: lineRange.location + marker.location, length: marker.length)
        return NSLocationInRange(clamped, absolute)
    }

    static func attributedString(
        from markdown: String,
        attachments: [NoteAttachment] = [],
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize),
        availableWidth: CGFloat = WiskAttachmentImageLayout.defaultAvailableWidth,
        showSourceMarkers: Bool = false,
        document: WiskMarkdownDocument? = nil,
        foldedLocations: Set<Int> = [],
        eagerStyleUTF16Range: NSRange? = nil
    ) -> NSAttributedString {
        if showSourceMarkers {
            return NSAttributedString(
                string: markdown,
                attributes: typingAttributes(
                    headingLevel: nil,
                    fontSelection: fontSelection,
                    baseFontSize: baseFontSize
                )
            )
        }
        let parsedDocument = document ?? WiskMarkdownDocumentEngine.parse(markdown)
        let tables = parsedDocument.tables
        let omitted = WiskMarkdownFolding.omittedSourceRanges(
            foldedLocations: foldedLocations,
            in: parsedDocument
        )
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var insideFencedCode = false
        var sourceCursor = 0

        for (index, line) in lines.enumerated() {
            let lineLength = (line as NSString).length
            let newlineLength = index < lines.count - 1 ? 1 : 0
            let contentRange = NSRange(location: sourceCursor, length: lineLength)
            defer { sourceCursor += lineLength + newlineLength }

            if WiskMarkdownFolding.fullyContains(contentRange, in: omitted)
                || (lineLength == 0 && WiskMarkdownFolding.contains(sourceCursor, in: omitted)) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    insideFencedCode.toggle()
                }
                continue
            }

            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            var parsed = block(from: line)
            if let tableRow = tableRow(at: contentRange.location, tables: tables) {
                if tableRow.isDivider {
                    continue
                }
                parsed.kind = .table
                parsed.visibleText = WiskMarkdownTableSyntax.visibleLine(for: tableRow)
                parsed.hiddenPrefixLength = 0
            }
            if insideFencedCode, !isFence {
                parsed = RenderedBlock(
                    kind: .codeFence,
                    headingLevel: nil,
                    listNumber: nil,
                    attachmentID: nil,
                    attachmentTitle: nil,
                    attachmentIsImage: nil,
                    visibleText: line,
                    hiddenPrefixLength: 0
                )
            }
            let visibleLine = parsed.visibleText
            let start = output.length
            let visibleLength = (visibleLine as NSString).length
            let lineVisibleRange = NSRange(location: start, length: max(visibleLength, 1))
            let shouldFullyStyle: Bool = {
                guard let eagerStyleUTF16Range else { return true }
                if NSIntersectionRange(eagerStyleUTF16Range, NSRange(location: start, length: visibleLength)).length > 0 {
                    return true
                }
                if eagerStyleUTF16Range.length == 0,
                   NSLocationInRange(eagerStyleUTF16Range.location, lineVisibleRange) {
                    return true
                }
                return false
            }()
            let resolvedAttachment = shouldFullyStyle ? parsed.attachmentID.flatMap { id in
                attachments.first(where: { $0.id == id })
            } : nil
            let lineAttributedString: NSAttributedString
            if let attachment = resolvedAttachment {
                lineAttributedString = attributedAttachmentString(
                    attachment,
                    fallbackText: visibleLine,
                    availableWidth: availableWidth
                )
            } else if parsed.kind == .codeFence || shouldFullyStyle == false {
                lineAttributedString = NSAttributedString(string: visibleLine)
            } else {
                lineAttributedString = attributedInlineString(from: visibleLine)
            }
            output.append(lineAttributedString)
            let lineRange = NSRange(location: start, length: lineAttributedString.length)
            applyAttributes(
                to: output,
                lineRange: lineRange,
                block: parsed,
                fontSelection: fontSelection,
                baseFontSize: baseFontSize
            )
            if shouldFullyStyle {
                applyInlineVisualAttributes(
                    to: output,
                    range: lineRange,
                    fontSelection: fontSelection,
                    baseFontSize: baseFontSize
                )
            }
            if lineRange.length > 0 || output.length >= start {
                let attributeRange = NSRange(location: start, length: max(lineRange.length, 0))
                if attributeRange.upperBound <= output.length {
                    output.addAttribute(.wiskMarkdownBlockSourceLocation, value: contentRange.location, range: attributeRange)
                    if parsed.kind == .heading || parsed.kind == .codeFence {
                        output.addAttribute(.wiskMarkdownFoldable, value: true, range: attributeRange)
                    }
                }
            }
            if parsed.kind == .table, lineRange.length > 0 {
                let paragraphStyle = (output.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                var tabLocation: CGFloat = 96
                paragraphStyle.tabStops = (0..<8).map { _ in
                    let tab = NSTextTab(textAlignment: .left, location: tabLocation)
                    tabLocation += 120
                    return tab
                }
                output.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
            }
            if let attachment = resolvedAttachment, lineRange.length > 0 {
                let paragraphStyle = NSMutableParagraphStyle()
                switch attachment.alignment {
                case .leading: paragraphStyle.alignment = .left
                case .center: paragraphStyle.alignment = .center
                case .trailing: paragraphStyle.alignment = .right
                }
                paragraphStyle.paragraphSpacing = 8
                output.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
            }

            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
            if isFence {
                insideFencedCode.toggle()
            }
        }

        return output
    }

    struct IncrementalLineEdit {
        var visibleRange: NSRange
        var attributedLine: NSAttributedString
        var sourceDelta: Int
    }

    /// Restyles a single-line source mutation in place. Returns `nil` for
    /// returns, fences, tables, attachments, folds, or kind-changing edits.
    static func incrementalLineEdit(
        previousMarkdown: String,
        mutation: WiskMarkdownMutation,
        editedSourceRange: NSRange,
        replacement: String,
        attachments: [NoteAttachment] = [],
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize),
        availableWidth: CGFloat = WiskAttachmentImageLayout.defaultAvailableWidth,
        showSourceMarkers: Bool = false,
        foldedLocations: Set<Int> = [],
        previousDocument: WiskMarkdownDocument? = nil
    ) -> IncrementalLineEdit? {
        guard replacement.contains("\n") == false,
              (previousMarkdown as NSString).substring(with: editedSourceRange).contains("\n") == false
        else {
            return nil
        }

        let previousLines = WiskMarkdownDocumentEngine.sourceLines(previousMarkdown)
        let nextLines = WiskMarkdownDocumentEngine.sourceLines(mutation.source)
        guard previousLines.count == nextLines.count,
              let lineIndex = previousLines.firstIndex(where: { lineContainsEdit($0, editedSourceRange: editedSourceRange) })
        else {
            return nil
        }

        let previousLine = previousLines[lineIndex]
        let nextLine = nextLines[lineIndex]
        let previousLineText = (previousMarkdown as NSString).substring(with: previousLine.contentRange)
        let nextLineText = (mutation.source as NSString).substring(with: nextLine.contentRange)
        let previousBlock = block(from: previousLineText)
        let nextBlock = block(from: nextLineText)
        guard previousBlock.kind == nextBlock.kind,
              incrementallyEditableKinds.contains(previousBlock.kind)
        else {
            return nil
        }

        let previousDocument = previousDocument
            ?? WiskMarkdownDocumentEngine.parse(previousMarkdown)
        guard let visibleRange = renderedVisibleRange(
            forSourceLocation: previousLine.contentRange.location,
            in: previousMarkdown,
            document: previousDocument,
            foldedLocations: foldedLocations,
            showSourceMarkers: showSourceMarkers
        ) else {
            return nil
        }

        let attributedLine: NSAttributedString
        if showSourceMarkers {
            attributedLine = NSAttributedString(
                string: nextLineText,
                attributes: typingAttributes(
                    headingLevel: nil,
                    fontSelection: fontSelection,
                    baseFontSize: baseFontSize
                )
            )
        } else {
            let rendered = attributedString(
                from: nextLineText,
                attachments: attachments,
                fontSelection: fontSelection,
                baseFontSize: baseFontSize,
                availableWidth: availableWidth,
                showSourceMarkers: false,
                document: WiskMarkdownDocumentEngine.parse(nextLineText),
                foldedLocations: []
            )
            let mutable = NSMutableAttributedString(attributedString: rendered)
            if mutable.length > 0 {
                mutable.addAttribute(
                    .wiskMarkdownBlockSourceLocation,
                    value: nextLine.contentRange.location,
                    range: NSRange(location: 0, length: mutable.length)
                )
            }
            attributedLine = mutable
        }

        return IncrementalLineEdit(
            visibleRange: visibleRange,
            attributedLine: attributedLine,
            sourceDelta: (nextLineText as NSString).length - (previousLineText as NSString).length
        )
    }

    @discardableResult
    static func applyIncrementalLineEdit(
        _ edit: IncrementalLineEdit,
        to attributedString: NSMutableAttributedString,
        replacingRange overrideRange: NSRange? = nil
    ) -> Bool {
        // `overrideRange` is for commits where the attributed string already
        // contains the new line's characters (native UIKit typing): the patch
        // replaces that span instead of the old render's range.
        let range = overrideRange ?? edit.visibleRange
        let length = attributedString.length
        guard range.location >= 0,
              range.length >= 0,
              range.upperBound <= length
        else {
            return false
        }
        if attributedString.attributedSubstring(from: range).string == edit.attributedLine.string {
            // Characters unchanged (most plain-typing keystrokes only
            // re-render attributes). Rewriting identical characters via
            // replaceCharacters fires an .editedCharacters storage change
            // right after the native keystroke, resets UIKit's input
            // composition, and blanks the QuickType suggestions and
            // autocorrect. Patch attributes in place instead so the text
            // system sees an attribute-only edit.
            edit.attributedLine.enumerateAttributes(
                in: NSRange(location: 0, length: edit.attributedLine.length)
            ) { attrs, subRange, _ in
                attributedString.setAttributes(
                    attrs,
                    range: NSRange(
                        location: range.location + subRange.location,
                        length: subRange.length
                    )
                )
            }
        } else {
            attributedString.replaceCharacters(in: range, with: edit.attributedLine)
        }
        shiftBlockSourceLocations(
            in: attributedString,
            after: range.location + edit.attributedLine.length,
            by: edit.sourceDelta
        )
        return true
    }

    private static let incrementallyEditableKinds: Set<BlockKind> = [
        .paragraph,
        .heading,
        .bullet,
        .numbered,
        .checklistUnchecked,
        .checklistChecked,
        .quote,
    ]

    private static func lineContainsEdit(_ line: WiskMarkdownDocumentEngine.SourceLine, editedSourceRange: NSRange) -> Bool {
        let location = editedSourceRange.location
        let end = editedSourceRange.upperBound
        let lineStart = line.contentRange.location
        let lineEnd = line.fullRange.upperBound
        guard location >= lineStart, end <= lineEnd else { return false }
        // A zero-length edit sitting exactly on this line's trailing newline
        // belongs to the next line (it is the next line's start), not to this
        // one. Keep `<=` for the document's final line, which has no trailing
        // newline, so end-of-document typing keeps the fast path.
        if location == lineEnd, end == lineEnd, line.newlineRange.length > 0 { return false }
        return true
    }

    private static func renderedVisibleRange(
        forSourceLocation sourceLocation: Int,
        in markdown: String,
        document: WiskMarkdownDocument,
        foldedLocations: Set<Int>,
        showSourceMarkers: Bool
    ) -> NSRange? {
        if showSourceMarkers {
            let lines = WiskMarkdownDocumentEngine.sourceLines(markdown)
            guard let line = lines.first(where: {
                sourceLocation >= $0.contentRange.location && sourceLocation <= $0.fullRange.upperBound
            }) else {
                return nil
            }
            return line.contentRange
        }

        let omitted = WiskMarkdownFolding.omittedSourceRanges(
            foldedLocations: foldedLocations,
            in: document
        )
        let tables = document.tables
        let lines = markdown.components(separatedBy: "\n")
        var insideFencedCode = false
        var sourceCursor = 0
        var visibleCursor = 0

        for (index, line) in lines.enumerated() {
            let lineLength = (line as NSString).length
            let newlineLength = index < lines.count - 1 ? 1 : 0
            let contentRange = NSRange(location: sourceCursor, length: lineLength)
            defer { sourceCursor += lineLength + newlineLength }

            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if WiskMarkdownFolding.fullyContains(contentRange, in: omitted)
                || (lineLength == 0 && WiskMarkdownFolding.contains(sourceCursor, in: omitted)) {
                if isFence {
                    insideFencedCode.toggle()
                }
                continue
            }
            if let tableRow = tableRow(at: contentRange.location, tables: tables), tableRow.isDivider {
                if isFence {
                    insideFencedCode.toggle()
                }
                continue
            }

            var parsed = block(from: line)
            if insideFencedCode, !isFence {
                parsed.kind = .codeFence
                parsed.visibleText = line
            } else if let tableRow = tableRow(at: contentRange.location, tables: tables), tableRow.isDivider == false {
                parsed.kind = .table
                parsed.visibleText = WiskMarkdownTableSyntax.visibleLine(for: tableRow)
            }

            let visibleLength = (parsed.visibleText as NSString).length
            if sourceLocation >= contentRange.location && sourceLocation <= contentRange.upperBound {
                if parsed.kind == .codeFence || parsed.kind == .table || parsed.kind == .attachmentImage || parsed.kind == .attachmentFile {
                    return nil
                }
                return NSRange(location: visibleCursor, length: visibleLength)
            }
            visibleCursor += visibleLength + newlineLength
            if isFence {
                insideFencedCode.toggle()
            }
        }
        return nil
    }

    private static func shiftBlockSourceLocations(
        in attributedString: NSMutableAttributedString,
        after location: Int,
        by delta: Int
    ) {
        guard delta != 0, location < attributedString.length else { return }
        let range = NSRange(location: location, length: attributedString.length - location)
        var replacements: [(NSRange, Int)] = []
        attributedString.enumerateAttribute(.wiskMarkdownBlockSourceLocation, in: range) { value, attrRange, _ in
            guard let sourceLocation = value as? Int else { return }
            replacements.append((attrRange, sourceLocation + delta))
        }
        for (attrRange, sourceLocation) in replacements {
            attributedString.addAttribute(.wiskMarkdownBlockSourceLocation, value: sourceLocation, range: attrRange)
        }
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        let string = attributedString.string as NSString
        guard string.length > 0 else { return "" }

        var lines: [String] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, enclosingRange, _ in
            lines.append(markdownLine(from: attributedString, lineRange: range))

            if enclosingRange.upperBound == string.length,
               range.upperBound < enclosingRange.upperBound {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func markdownRange(
        forVisibleRange visibleRange: NSRange,
        in markdown: String,
        document: WiskMarkdownDocument? = nil,
        foldedLocations: Set<Int> = []
    ) -> Range<String.Index>? {
        guard visibleRange.location != NSNotFound else { return nil }

        let nsMarkdown = markdown as NSString
        let parsedDocument = document ?? WiskMarkdownDocumentEngine.parse(markdown)
        let tables = parsedDocument.tables
        let omitted = WiskMarkdownFolding.omittedSourceRanges(
            foldedLocations: foldedLocations,
            in: parsedDocument
        )
        var visibleCursor = 0
        var markdownSelectionStart: Int?
        var markdownSelectionEnd: Int?
        var endSetByNewline = false
        var newlineEndConsumed = false
        var previousNewlineSourceRange: NSRange?

        nsMarkdown.enumerateSubstrings(in: NSRange(location: 0, length: nsMarkdown.length), options: [.byLines, .substringNotRequired]) { _, range, enclosingRange, stop in
            if WiskMarkdownFolding.fullyContains(range, in: omitted)
                || (range.length == 0 && WiskMarkdownFolding.contains(range.location, in: omitted)) {
                return
            }
            if let tableRow = tableRow(at: range.location, tables: tables), tableRow.isDivider {
                return
            }

            let rawLine = nsMarkdown.substring(with: range)
            let parsed = block(from: rawLine)
            let visibleLine: String
            let cellMap: [(visibleOffset: Int, sourceLocation: Int, length: Int)]
            if let tableRow = tableRow(at: range.location, tables: tables), tableRow.isDivider == false {
                visibleLine = WiskMarkdownTableSyntax.visibleLine(for: tableRow)
                var offset = 0
                var maps: [(Int, Int, Int)] = []
                for cell in tableRow.cells {
                    maps.append((offset, cell.sourceRange.location, cell.text.utf16.count))
                    offset += cell.text.utf16.count
                }
                cellMap = maps
            } else {
                visibleLine = parsed.visibleText
                cellMap = []
            }
            let hiddenPrefixLength = parsed.hiddenPrefixLength
            let visibleLineLength = (visibleLine as NSString).length
            let visibleReplacementPrefixLength = visibleLineLength - range.length + hiddenPrefixLength
            let visibleLineRange = NSRange(location: visibleCursor, length: visibleLineLength)
            let markdownContentStart = range.location + hiddenPrefixLength

            if NSIntersectionRange(visibleRange, visibleLineRange).length > 0 || visibleRange.length == 0 && NSLocationInRange(visibleRange.location, NSRange(location: visibleLineRange.location, length: visibleLineRange.length + 1)) {
                let startOffset = max(visibleRange.location - visibleLineRange.location, 0)
                let endOffset = min(max(visibleRange.upperBound - visibleLineRange.location, 0), visibleLineLength)
                if cellMap.isEmpty {
                    // An empty marker-bearing item (rendered "• ", "☐ ", "1. ",
                    // "❝ ") whose last rendered character the range consumes is
                    // being deleted whole: extend the mapping over the hidden
                    // markdown prefix and the joining line break so the
                    // deletion removes the item instead of leaving an orphan
                    // "-" / "1." marker as literal text after the join.
                    let engineBlock = parsedDocument.blocks.first { $0.sourceRange.location == range.location }
                    let swallowsEmptyItem = endOffset > startOffset
                        && endOffset == visibleLineLength
                        && engineBlock?.contentSourceRange.length == 0
                        && swallowsItemPrefixOnDeletion(parsed.kind)
                    if swallowsEmptyItem {
                        let itemSourceRange: NSRange
                        if enclosingRange.upperBound > range.upperBound {
                            // The item owns a trailing line break: delete the
                            // whole line plus it.
                            itemSourceRange = NSRange(
                                location: range.location,
                                length: enclosingRange.upperBound - range.location
                            )
                        } else if let previousNewline = previousNewlineSourceRange {
                            // Document-final item has no break of its own:
                            // absorb the preceding break instead.
                            itemSourceRange = NSRange(
                                location: previousNewline.location,
                                length: range.upperBound - previousNewline.location
                            )
                        } else {
                            itemSourceRange = range
                        }
                        markdownSelectionStart = markdownSelectionStart ?? itemSourceRange.location
                        markdownSelectionEnd = itemSourceRange.upperBound
                        endSetByNewline = false
                    } else {
                        let startSourceOffset = sourceOffsetByDocumentMapping(
                            forVisibleOffset: startOffset,
                            lineRange: range,
                            hiddenPrefixLength: hiddenPrefixLength,
                            visibleReplacementPrefixLength: visibleReplacementPrefixLength,
                            visibleLineLength: visibleLineLength,
                            document: parsedDocument
                        ) ?? sourceCaretOffset(
                            forVisibleOffset: startOffset,
                            hiddenPrefixLength: hiddenPrefixLength,
                            visibleReplacementPrefixLength: visibleReplacementPrefixLength,
                            sourceLineLength: range.length
                        )
                        let endSourceOffset = sourceOffsetByDocumentMapping(
                            forVisibleOffset: endOffset,
                            lineRange: range,
                            hiddenPrefixLength: hiddenPrefixLength,
                            visibleReplacementPrefixLength: visibleReplacementPrefixLength,
                            visibleLineLength: visibleLineLength,
                            document: parsedDocument
                        ) ?? sourceCaretOffset(
                            forVisibleOffset: endOffset,
                            hiddenPrefixLength: hiddenPrefixLength,
                            visibleReplacementPrefixLength: visibleReplacementPrefixLength,
                            sourceLineLength: range.length
                        )
                        markdownSelectionStart = markdownSelectionStart ?? range.location + startSourceOffset
                        markdownSelectionEnd = range.location + endSourceOffset
                        endSetByNewline = false
                    }
                } else {
                    markdownSelectionStart = markdownSelectionStart ?? sourceLocation(
                        forVisibleOffset: startOffset,
                        cells: cellMap,
                        fallback: markdownContentStart
                    )
                    markdownSelectionEnd = sourceLocation(
                        forVisibleOffset: endOffset,
                        cells: cellMap,
                        fallback: markdownContentStart + endOffset
                    )
                    endSetByNewline = false
                }
            }

            visibleCursor += visibleLineLength
            if enclosingRange.upperBound > range.upperBound {
                let newlineSpan = NSRange(location: visibleCursor, length: 1)
                let newlineHit = NSIntersectionRange(visibleRange, newlineSpan)
                if newlineHit.length > 0 {
                    // A rendered line break maps to this line's source newline.
                    // Without this, a backspace at a line start (whose affected
                    // range is exactly the break above the caret) falls through
                    // to the engine mapping, whose visible space strips glyphs
                    // ("• ", "☐ ", "❝ ") and mis-maps the range to a different
                    // line's newline.
                    markdownSelectionStart = markdownSelectionStart ?? range.upperBound
                    endSetByNewline = true
                    newlineEndConsumed = visibleRange.upperBound >= newlineSpan.upperBound
                    markdownSelectionEnd = range.upperBound + (newlineEndConsumed ? 1 : 0)
                }
                if visibleRange.length == 0, visibleRange.location == visibleCursor {
                    markdownSelectionStart = markdownSelectionStart ?? range.upperBound
                    markdownSelectionEnd = range.upperBound
                    endSetByNewline = false
                    stop.pointee = true
                    return
                }
                previousNewlineSourceRange = NSRange(
                    location: range.upperBound,
                    length: enclosingRange.upperBound - range.upperBound
                )
                visibleCursor += 1
            }

            if let markdownSelectionEnd, markdownSelectionEnd >= 0, visibleCursor > visibleRange.upperBound {
                stop.pointee = true
            }
        }

        // A caret exactly at the end of the rendered document — the position
        // after a trailing line break (list exit, "Tail line\n") — matches no
        // line body (their windows stop at the break) and no newline span
        // (an empty range does not intersect), so the walk above ends with
        // nothing mapped. Typing there must append at the source end; without
        // this, the mapping returns nil, the edit falls to the native text
        // path, and the coordinator cannot reconcile it into the markdown
        // source (typed characters vanish or land mid-word).
        if markdownSelectionStart == nil, markdownSelectionEnd == nil,
           visibleRange.length == 0, visibleRange.location == visibleCursor {
            markdownSelectionStart = nsMarkdown.length
            markdownSelectionEnd = nsMarkdown.length
        }

        // When the requested range ends exactly after a rendered line break (a
        // backspace joining the line below), also swallow the next line's
        // hidden markdown prefix so "- a" + backspace at "• b" becomes
        // "- ab" instead of leaking "- b" inline into the merged line.
        if endSetByNewline, newlineEndConsumed, let currentEnd = markdownSelectionEnd,
           let nextLine = parsedDocument.blocks.first(where: { $0.sourceRange.location == currentEnd }),
           joinSwallowsHiddenPrefix(nextLine.kind) {
            markdownSelectionEnd = max(nextLine.contentSourceRange.location, currentEnd)
        }

        guard let start = markdownSelectionStart, let end = markdownSelectionEnd else { return nil }
        let clampedStart = min(max(start, 0), nsMarkdown.length)
        let clampedEnd = min(max(end, clampedStart), nsMarkdown.length)
        guard let stringStart = String.Index(utf16Offset: clampedStart, in: markdown).samePosition(in: markdown),
              let stringEnd = String.Index(utf16Offset: clampedEnd, in: markdown).samePosition(in: markdown) else {
            return nil
        }
        return stringStart..<stringEnd
    }

    static func visibleRange(
        forMarkdownRange markdownRange: Range<String.Index>,
        in markdown: String,
        document: WiskMarkdownDocument? = nil,
        foldedLocations: Set<Int> = []
    ) -> NSRange? {
        let requested = NSRange(markdownRange, in: markdown)
        guard requested.location != NSNotFound else { return nil }
        if markdown.isEmpty {
            return NSRange(location: 0, length: 0)
        }
        let parsedDocument = document ?? WiskMarkdownDocumentEngine.parse(markdown)
        guard let start = visibleLocation(
            forMarkdownLocation: requested.location,
            in: markdown,
            document: parsedDocument,
            foldedLocations: foldedLocations
        ),
              let end = visibleLocation(
                forMarkdownLocation: requested.upperBound,
                in: markdown,
                document: parsedDocument,
                foldedLocations: foldedLocations
              ) else {
            return nil
        }
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// Block kinds whose hidden markdown prefix (`- `, `2. `, `- [ ] `, `> `)
    /// is removed when a rendered line break above them is deleted, so a join
    /// does not leak marker syntax into the merged line. Structural blocks
    /// (attachments, tables, fences, separators) keep their raw newline join.
    private static func joinSwallowsHiddenPrefix(_ kind: WiskMarkdownBlockKind) -> Bool {
        switch kind {
        case .paragraph, .heading, .bullet, .ordered, .task, .quote, .callout:
            return true
        case .separator, .fencedCode, .tableRow, .tableDivider, .footnoteDefinition, .attachment, .blankLine:
            return false
        }
    }

    /// Deletion kinds whose EMPTY rendered item ("• ", "☐ ", "1. ", "❝ ") is
    /// removed whole — hidden prefix and joining break included — when the
    /// deletion consumes the item's last rendered character. Without this the
    /// visible-to-source map deletes only the 1:1 trailing space and the
    /// marker survives as literal text ("- Alpha item\n-").
    private static func swallowsItemPrefixOnDeletion(_ kind: BlockKind) -> Bool {
        switch kind {
        case .bullet, .numbered, .checklistUnchecked, .checklistChecked, .quote, .callout:
            return true
        case .paragraph, .heading, .separator, .codeFence, .table, .footnote, .attachmentImage, .attachmentFile:
            return false
        }
    }

    static func visibleSelection(
        forMarkdownRange markdownRange: Range<String.Index>?,
        in markdown: String,
        fallback: NSRange,
        textLength: Int,
        showSourceMarkers: Bool = false,
        document: WiskMarkdownDocument? = nil,
        foldedLocations: Set<Int> = []
    ) -> NSRange {
        let raw: NSRange
        if showSourceMarkers {
            raw = markdownRange.map { NSRange($0, in: markdown) } ?? fallback
        } else if let markdownRange, let visible = visibleRange(
            forMarkdownRange: markdownRange,
            in: markdown,
            document: document,
            foldedLocations: foldedLocations
        ) {
            raw = visible
        } else {
            raw = fallback
        }
        let location = min(max(raw.location, 0), textLength)
        let length = min(max(raw.length, 0), max(textLength - location, 0))
        return NSRange(location: location, length: length)
    }

    private static func visibleLocation(
        forMarkdownLocation location: Int,
        in markdown: String,
        document: WiskMarkdownDocument? = nil,
        foldedLocations: Set<Int> = []
    ) -> Int? {
        let nsMarkdown = markdown as NSString
        guard location >= 0, location <= nsMarkdown.length else { return nil }
        if nsMarkdown.length == 0 {
            return 0
        }
        let parsedDocument = document ?? WiskMarkdownDocumentEngine.parse(markdown)
        let tables = parsedDocument.tables
        let omitted = WiskMarkdownFolding.omittedSourceRanges(
            foldedLocations: foldedLocations,
            in: parsedDocument
        )

        var visibleCursor = 0
        var mapped: Int?

        nsMarkdown.enumerateSubstrings(
            in: NSRange(location: 0, length: nsMarkdown.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, enclosingRange, stop in
            if WiskMarkdownFolding.fullyContains(range, in: omitted)
                || (range.length == 0 && WiskMarkdownFolding.contains(range.location, in: omitted)) {
                if location >= range.location && location <= enclosingRange.upperBound {
                    mapped = visibleCursor
                    stop.pointee = true
                }
                return
            }
            if let tableRow = tableRow(at: range.location, tables: tables), tableRow.isDivider {
                if location >= range.location && location <= enclosingRange.upperBound {
                    mapped = visibleCursor
                    stop.pointee = true
                }
                return
            }

            let rawLine = nsMarkdown.substring(with: range)
            let parsed = block(from: rawLine)
            let visibleLine: String
            let cellMap: [(visibleOffset: Int, sourceLocation: Int, length: Int)]
            if let tableRow = tableRow(at: range.location, tables: tables), tableRow.isDivider == false {
                visibleLine = WiskMarkdownTableSyntax.visibleLine(for: tableRow)
                var offset = 0
                var maps: [(Int, Int, Int)] = []
                for cell in tableRow.cells {
                    maps.append((offset, cell.sourceRange.location, cell.text.utf16.count))
                    offset += cell.text.utf16.count
                }
                cellMap = maps
            } else {
                visibleLine = parsed.visibleText
                cellMap = []
            }
            let hiddenPrefixLength = parsed.hiddenPrefixLength
            let visibleLineLength = (visibleLine as NSString).length
            let visibleReplacementPrefixLength = visibleLineLength - range.length + hiddenPrefixLength

            if location >= range.location && location <= range.upperBound {
                if cellMap.isEmpty {
                    let visibleOffset = visibleOffsetByDocumentMapping(
                        forSourceLocation: location,
                        lineRange: range,
                        hiddenPrefixLength: hiddenPrefixLength,
                        visibleReplacementPrefixLength: visibleReplacementPrefixLength,
                        visibleLineLength: visibleLineLength,
                        document: parsedDocument
                    ) ?? visibleCaretOffset(
                        forSourceOffset: location - range.location,
                        hiddenPrefixLength: hiddenPrefixLength,
                        visibleReplacementPrefixLength: visibleReplacementPrefixLength,
                        visibleLineLength: visibleLineLength
                    )
                    mapped = visibleCursor + visibleOffset
                } else {
                    mapped = visibleCursor + visibleOffset(
                        forSourceLocation: location,
                        cells: cellMap
                    )
                }
                stop.pointee = true
                return
            }

            visibleCursor += visibleLineLength
            if enclosingRange.upperBound > range.upperBound {
                if location == enclosingRange.upperBound {
                    mapped = visibleCursor + 1
                    stop.pointee = true
                    return
                }
                visibleCursor += 1
            }
        }

        return mapped ?? visibleCursor
    }

    static func applyFormatting(
        _ action: WiskMarkdownFormattingAction,
        to markdown: String,
        visibleRange: NSRange,
        visibleText: String? = nil
    ) -> WiskMarkdownMutation? {
        let resolvedVisibleText = visibleText ?? attributedString(from: markdown).string
        switch action {
        case .heading, .bullet, .numberedList, .checklist, .quote:
            let line = lineIndex(containingUTF16Offset: visibleRange.location, in: resolvedVisibleText)
            let sourceLine = utf16RangeOfLine(at: line, in: markdown)
            return WiskMarkdownDocumentEngine.apply(
                action,
                to: markdown,
                sourceRange: NSRange(location: sourceLine.location, length: 0)
            )
        case .bold, .italic, .underline, .strikethrough, .highlight, .code, .link, .table:
            let sourceRange: NSRange
            if let mapped = markdownRange(forVisibleRange: visibleRange, in: markdown) {
                sourceRange = NSRange(mapped, in: markdown)
            } else {
                sourceRange = NSRange(location: 0, length: 0)
            }
            return WiskMarkdownDocumentEngine.apply(action, to: markdown, sourceRange: sourceRange)
        }
    }

    /// Toolbar clicks often move the live selection to the end of the document
    /// or onto the last visible line. Keep the in-note caret unless this move
    /// was caused by a click or keypress in the editor.
    static func shouldPreserveRememberedVisibleRange(
        incoming: NSRange,
        remembered: NSRange,
        textLength: Int,
        isUserInitiated: Bool
    ) -> Bool {
        guard !isUserInitiated, textLength > 0 else { return false }
        guard isCollapsedEndOfDocument(incoming, textLength: textLength) else { return false }
        return remembered.location != textLength || remembered.length != 0
    }

    static func shouldPreserveRememberedVisibleRange(
        incoming: NSRange,
        remembered: NSRange,
        text: String,
        isUserInitiated: Bool
    ) -> Bool {
        guard !isUserInitiated, (text as NSString).length > 0 else { return false }
        guard isOnLastLine(incoming, in: text) else { return false }
        return isOnLastLine(remembered, in: text) == false
    }

    static func shouldSkipEditingCaretSnapshotUpdate(
        incoming: NSRange,
        snapshot: NSRange?,
        text: String,
        isUserInitiated: Bool
    ) -> Bool {
        guard !isUserInitiated, let snapshot else { return false }
        guard isOnLastLine(incoming, in: text) else { return false }
        return isOnLastLine(snapshot, in: text) == false
    }

    static func isCollapsedEndOfDocument(_ range: NSRange, textLength: Int) -> Bool {
        textLength > 0 && range.length == 0 && range.location == textLength
    }

    static func isOnLastLine(_ range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        guard ns.length > 0, range.location != NSNotFound else { return false }
        if isCollapsedEndOfDocument(range, textLength: ns.length) {
            return true
        }
        let lastContentOffset = max(ns.length - 1, 0)
        let incomingOffset = min(max(range.location, 0), ns.length)
        return lineIndex(containingUTF16Offset: incomingOffset, in: text)
            == lineIndex(containingUTF16Offset: lastContentOffset, in: text)
    }

    static func selectionAfterProposedChange(
        from oldRange: NSRange,
        to newRange: NSRange,
        textLength: Int,
        isUserInitiated: Bool
    ) -> NSRange {
        if shouldPreserveRememberedVisibleRange(
            incoming: newRange,
            remembered: oldRange,
            textLength: textLength,
            isUserInitiated: isUserInitiated
        ) {
            return oldRange
        }
        return newRange
    }

    static func selectionAfterProposedChange(
        from oldRange: NSRange,
        to newRange: NSRange,
        text: String,
        isUserInitiated: Bool
    ) -> NSRange {
        if shouldPreserveRememberedVisibleRange(
            incoming: newRange,
            remembered: oldRange,
            text: text,
            isUserInitiated: isUserInitiated
        ) {
            return oldRange
        }
        return newRange
    }

    static func visibleRangeForFormatting(
        snapshot: NSRange?,
        remembered: NSRange,
        live: NSRange,
        textLength: Int
    ) -> NSRange {
        if let snapshot, snapshot.location != NSNotFound {
            return snapshot
        }
        let usable: (NSRange) -> Bool = { range in
            range.location != NSNotFound && !isCollapsedEndOfDocument(range, textLength: textLength)
        }
        if usable(remembered) {
            return remembered
        }
        if usable(live) {
            return live
        }
        return remembered
    }

    static func replacingCollapsedDocumentEnd(_ range: NSRange, textLength: Int) -> NSRange {
        if isCollapsedEndOfDocument(range, textLength: textLength) {
            return NSRange(location: 0, length: 0)
        }
        return range
    }

    static func lineIndex(containingUTF16Offset offset: Int, in string: String) -> Int {
        let ns = string as NSString
        let clamped = min(max(offset, 0), ns.length)
        var count = 0
        var index = 0
        while index < clamped {
            if ns.character(at: index) == 10 {
                count += 1
            }
            index += 1
        }
        return count
    }

    static func utf16RangeOfLine(at lineIndex: Int, in string: String) -> NSRange {
        let ns = string as NSString
        var current = 0
        var start = 0
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 10 {
                if current == lineIndex {
                    return NSRange(location: start, length: index - start)
                }
                current += 1
                start = index + 1
            }
            index += 1
        }
        if current <= lineIndex {
            return NSRange(location: start, length: ns.length - start)
        }
        return NSRange(location: 0, length: 0)
    }

    static func applyHeadingShortcutIfNeeded(
        to attributedString: NSMutableAttributedString,
        selectedRange: NSRange,
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    ) -> (selectedRange: NSRange, headingLevel: Int)? {
        guard let result = applyBlockShortcutIfNeeded(
            to: attributedString,
            selectedRange: selectedRange,
            fontSelection: fontSelection,
            baseFontSize: baseFontSize
        ),
            let headingLevel = result.headingLevel
        else {
            return nil
        }
        return (selectedRange: result.selectedRange, headingLevel: headingLevel)
    }

    static func applyBlockShortcutIfNeeded(
        to attributedString: NSMutableAttributedString,
        selectedRange: NSRange,
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    ) -> (selectedRange: NSRange, headingLevel: Int?)? {
        guard selectedRange.location != NSNotFound else { return nil }
        let string = attributedString.string as NSString
        let cursor = min(selectedRange.location, string.length)
        let lineRange = string.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = string.substring(with: lineRange)

        guard let shortcut = typedBlockShortcut(in: lineText) else { return nil }
        let markerRange = NSRange(location: lineRange.location + shortcut.leadingWhitespaceLength, length: shortcut.markdownPrefixLength)
        attributedString.replaceCharacters(in: markerRange, with: shortcut.visiblePrefix)

        let updatedLineRange = (attributedString.string as NSString).lineRange(for: NSRange(
            location: min(lineRange.location, attributedString.length),
            length: 0
        ))
        let parsed = RenderedBlock(
            kind: shortcut.kind,
            headingLevel: shortcut.level,
            listNumber: shortcut.listNumber,
            attachmentID: nil,
            attachmentTitle: nil,
            attachmentIsImage: nil,
            visibleText: (attributedString.string as NSString).substring(with: updatedLineRange).trimmingCharacters(in: .newlines),
            hiddenPrefixLength: 0
        )
        applyAttributes(
            to: attributedString,
            lineRange: NSRange(location: updatedLineRange.location, length: max(updatedLineRange.length - (updatedLineRange.length > 0 ? 1 : 0), 0)),
            block: parsed,
            fontSelection: fontSelection,
            baseFontSize: baseFontSize
        )

        let delta = shortcut.visiblePrefix.utf16.count - shortcut.markdownPrefixLength
        return (
            selectedRange: NSRange(location: max(selectedRange.location + delta, updatedLineRange.location), length: 0),
            headingLevel: shortcut.level
        )
    }

    private static func applyHeadingShortcutLegacyIfNeeded(
        to attributedString: NSMutableAttributedString,
        selectedRange: NSRange,
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    ) -> (selectedRange: NSRange, headingLevel: Int)? {
        guard selectedRange.location != NSNotFound else { return nil }
        let string = attributedString.string as NSString
        let cursor = min(selectedRange.location, string.length)
        let lineRange = string.lineRange(for: NSRange(location: cursor, length: 0))
        let lineText = string.substring(with: lineRange)

        guard let shortcut = typedHeadingShortcut(in: lineText) else { return nil }
        let deleteRange = NSRange(location: lineRange.location + shortcut.leadingWhitespaceLength, length: shortcut.markdownPrefixLength)
        attributedString.deleteCharacters(in: deleteRange)

        let updatedLineRange = NSRange(
            location: lineRange.location,
            length: max(lineRange.length - shortcut.markdownPrefixLength, 0)
        )
        applyAttributes(
            to: attributedString,
            lineRange: updatedLineRange,
            block: RenderedBlock(
                kind: .heading,
                headingLevel: shortcut.level,
                listNumber: nil,
                attachmentID: nil,
                attachmentTitle: nil,
                attachmentIsImage: nil,
                visibleText: (attributedString.string as NSString).substring(with: updatedLineRange).trimmingCharacters(in: .newlines),
                hiddenPrefixLength: 0
            ),
            fontSelection: fontSelection,
            baseFontSize: baseFontSize
        )

        return (
            selectedRange: NSRange(location: max(selectedRange.location - shortcut.markdownPrefixLength, lineRange.location), length: 0),
            headingLevel: shortcut.level
        )
    }

    static func normalizeAttributes(
        in attributedString: NSMutableAttributedString,
        editedRange: NSRange? = nil,
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    ) {
        let string = attributedString.string as NSString
        guard string.length > 0 else { return }

        let requestedRange = editedRange ?? NSRange(location: 0, length: string.length)
        let clampedLocation = min(max(requestedRange.location, 0), string.length)
        let clampedLength = min(max(requestedRange.length, 0), string.length - clampedLocation)
        let lineRange = string.lineRange(for: NSRange(location: clampedLocation, length: clampedLength))
        string.enumerateSubstrings(in: lineRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let block = block(in: attributedString, lineRange: range)
            applyAttributes(
                to: attributedString,
                lineRange: range,
                block: block,
                fontSelection: fontSelection,
                baseFontSize: baseFontSize
            )
        }
    }

    static func applyReturnContinuationIfNeeded(
        to attributedString: NSMutableAttributedString,
        selectedRange: NSRange,
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    ) -> NSRange? {
        guard selectedRange.length == 0,
              selectedRange.location <= attributedString.length,
              attributedString.length > 0 else { return nil }

        let string = attributedString.string as NSString
        let probeLocation = min(max(selectedRange.location - 1, 0), max(string.length - 1, 0))
        let lineRange = string.lineRange(for: NSRange(location: probeLocation, length: 0))
        let block = block(in: attributedString, lineRange: lineRange)
        let visibleLine = string.substring(with: lineRange).trimmingCharacters(in: .newlines)

        let continuation: (prefix: String, nextBlock: RenderedBlock)?
        switch block.kind {
        case .bullet:
            continuation = ("• ", RenderedBlock(kind: .bullet, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "", hiddenPrefixLength: 0))
        case .numbered:
            let nextNumber = (block.listNumber ?? 1) + 1
            continuation = ("\(nextNumber). ", RenderedBlock(kind: .numbered, headingLevel: nil, listNumber: nextNumber, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "", hiddenPrefixLength: 0))
        case .checklistUnchecked, .checklistChecked:
            continuation = ("☐ ", RenderedBlock(kind: .checklistUnchecked, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "", hiddenPrefixLength: 0))
        case .quote:
            continuation = ("❝ ", RenderedBlock(kind: .quote, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "", hiddenPrefixLength: 0))
        default:
            continuation = nil
        }
        guard let continuation else { return nil }

        let currentPrefixLength: Int
        switch block.kind {
        case .bullet, .checklistUnchecked, .checklistChecked, .quote:
            currentPrefixLength = min(2, (visibleLine as NSString).length)
        case .numbered:
            currentPrefixLength = min(visibleLine.firstIndex(of: " ").map { visibleLine.distance(from: visibleLine.startIndex, to: $0) + 1 } ?? 0, (visibleLine as NSString).length)
        default:
            currentPrefixLength = 0
        }
        let content = (visibleLine as NSString).substring(from: currentPrefixLength)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let markerRange = NSRange(location: lineRange.location, length: currentPrefixLength)
            attributedString.replaceCharacters(in: markerRange, with: "")
            let remainingLineRange = (attributedString.string as NSString).lineRange(for: NSRange(location: lineRange.location, length: 0))
            applyAttributes(
                to: attributedString,
                lineRange: NSRange(location: remainingLineRange.location, length: max(remainingLineRange.length - (remainingLineRange.length > 0 ? 1 : 0), 0)),
                block: RenderedBlock(kind: .paragraph, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "", hiddenPrefixLength: 0),
                fontSelection: fontSelection,
                baseFontSize: baseFontSize
            )
            return NSRange(location: lineRange.location, length: 0)
        }

        let insertion = "\n\(continuation.prefix)"
        attributedString.replaceCharacters(in: selectedRange, with: insertion)
        let insertedLineRange = NSRange(
            location: selectedRange.location + 1,
            length: (continuation.prefix as NSString).length
        )
        applyAttributes(
            to: attributedString,
            lineRange: insertedLineRange,
            block: continuation.nextBlock,
            fontSelection: fontSelection,
            baseFontSize: baseFontSize
        )
        return NSRange(location: selectedRange.location + (insertion as NSString).length, length: 0)
    }

    static func typingAttributes(
        headingLevel: Int?,
        fontSelection: WiskEditorFontSelection = .system,
        baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: platformFont(
                fontSelection: fontSelection,
                size: fontSize(forHeadingLevel: headingLevel, baseFontSize: baseFontSize),
                weight: fontWeight(forHeadingLevel: headingLevel)
            ),
            .foregroundColor: platformTextColor,
            .paragraphStyle: paragraphStyle(forHeadingLevel: headingLevel),
        ]
        if let headingLevel {
            attributes[.wiskMarkdownHeadingLevel] = headingLevel
        }
        return attributes
    }

    private static func applyAttributes(
        to attributedString: NSMutableAttributedString,
        lineRange: NSRange,
        block: RenderedBlock,
        fontSelection: WiskEditorFontSelection,
        baseFontSize: CGFloat
    ) {
        let effectiveRange = NSRange(location: lineRange.location, length: max(lineRange.length, 0))
        guard effectiveRange.location <= attributedString.length,
              effectiveRange.upperBound <= attributedString.length else { return }

        attributedString.removeAttribute(.font, range: effectiveRange)
        attributedString.removeAttribute(.foregroundColor, range: effectiveRange)
        attributedString.removeAttribute(.paragraphStyle, range: effectiveRange)
        attributedString.removeAttribute(.wiskMarkdownHeadingLevel, range: effectiveRange)
        attributedString.removeAttribute(.wiskMarkdownBlockKind, range: effectiveRange)
        attributedString.removeAttribute(.wiskMarkdownListNumber, range: effectiveRange)
        attributedString.removeAttribute(.wiskMarkdownAttachmentID, range: effectiveRange)
        attributedString.removeAttribute(.wiskMarkdownAttachmentTitle, range: effectiveRange)
        attributedString.removeAttribute(.wiskMarkdownAttachmentIsImage, range: effectiveRange)
        attributedString.addAttributes(typingAttributes(headingLevel: block.headingLevel, fontSelection: fontSelection, baseFontSize: baseFontSize), range: effectiveRange)
        attributedString.addAttribute(.wiskMarkdownBlockKind, value: block.kind.rawValue, range: effectiveRange)
        if block.kind == .codeFence {
            attributedString.addAttributes(
                [
                    .font: platformMonospacedFont(size: baseFontSize),
                    .backgroundColor: platformCodeBackgroundColor,
                ],
                range: effectiveRange
            )
        }
        if let listNumber = block.listNumber {
            attributedString.addAttribute(.wiskMarkdownListNumber, value: listNumber, range: effectiveRange)
        }
        if let attachmentID = block.attachmentID {
            attributedString.addAttribute(.wiskMarkdownAttachmentID, value: attachmentID.uuidString, range: effectiveRange)
        }
        if let attachmentTitle = block.attachmentTitle {
            attributedString.addAttribute(.wiskMarkdownAttachmentTitle, value: attachmentTitle, range: effectiveRange)
        }
        if let attachmentIsImage = block.attachmentIsImage {
            attributedString.addAttribute(.wiskMarkdownAttachmentIsImage, value: attachmentIsImage, range: effectiveRange)
        }
    }

    private static func tableRow(at sourceLocation: Int, tables: [WiskMarkdownTable]) -> WiskMarkdownTableRow? {
        for table in tables {
            if let row = table.rows.first(where: { $0.sourceRange.location == sourceLocation || $0.contentRange.location == sourceLocation }) {
                return row
            }
        }
        return nil
    }

    private static func tableRow(at sourceLocation: Int, in document: WiskMarkdownDocument) -> WiskMarkdownTableRow? {
        tableRow(at: sourceLocation, tables: document.tables)
    }

    /// Maps a source location inside a rendered line through document mappings so
    /// hidden inline markers (`**`, `*`, `` ` ``, `[]()`) do not shift the caret.
    /// Returns nil for line prefixes, fenced interiors, and other cases where the
    /// line-walk's prefix mapping should stay in charge.
    private static func visibleOffsetByDocumentMapping(
        forSourceLocation location: Int,
        lineRange: NSRange,
        hiddenPrefixLength: Int,
        visibleReplacementPrefixLength: Int,
        visibleLineLength: Int,
        document: WiskMarkdownDocument
    ) -> Int? {
        let block = document.blocks.first { candidate in
            location >= candidate.sourceRange.location && location <= candidate.sourceRange.upperBound
        }
        let contentStart = block?.contentSourceRange.location ?? lineRange.location
        guard contentStart >= lineRange.location,
              contentStart <= lineRange.upperBound,
              location >= contentStart,
              let mapped = document.visibleNSRange(forSourceRange: NSRange(location: location, length: 0)),
              let contentMapped = document.visibleNSRange(
                forSourceRange: NSRange(location: contentStart, length: 0)
              ) else {
            return nil
        }
        let renderedContentStart = visibleCaretOffset(
            forSourceOffset: contentStart - lineRange.location,
            hiddenPrefixLength: hiddenPrefixLength,
            visibleReplacementPrefixLength: visibleReplacementPrefixLength,
            visibleLineLength: visibleLineLength
        )
        return min(max(renderedContentStart + mapped.location - contentMapped.location, 0), visibleLineLength)
    }

    /// Maps a source caret inside a rendered line onto the visible line.
    /// Hidden markdown prefixes such as `-` are replaced by a visible marker (`•`);
    /// a caret at the start of that source line stays in front of the marker.
    private static func visibleCaretOffset(
        forSourceOffset offsetInSourceLine: Int,
        hiddenPrefixLength: Int,
        visibleReplacementPrefixLength: Int,
        visibleLineLength: Int
    ) -> Int {
        if offsetInSourceLine <= 0 {
            return 0
        }
        return min(
            max(offsetInSourceLine - hiddenPrefixLength, 0) + max(visibleReplacementPrefixLength, 0),
            visibleLineLength
        )
    }

    /// Inverse of `visibleCaretOffset`. A caret in front of a visible list marker
    /// maps back to the start of the markdown line so typing is not one character late.
    private static func sourceCaretOffset(
        forVisibleOffset visibleOffset: Int,
        hiddenPrefixLength: Int,
        visibleReplacementPrefixLength: Int,
        sourceLineLength: Int
    ) -> Int {
        let visReplace = max(visibleReplacementPrefixLength, 0)
        if visibleOffset <= 0 {
            return visReplace > 0 ? 0 : min(hiddenPrefixLength, sourceLineLength)
        }
        if visibleOffset < visReplace {
            return min(visibleOffset, sourceLineLength)
        }
        return min(max(visibleOffset - visReplace + hiddenPrefixLength, 0), sourceLineLength)
    }

    /// Document-based visible→source caret mapping for a rendered line.
    /// The arithmetic `sourceCaretOffset` is blind to renderer-hidden inline
    /// markers (`*`, `~~`, `==`, backticks, `_`): a caret after a hidden span
    /// maps `markerWidth` characters early and typed text lands mid-word.
    /// This bridges the block prefix arithmetically (mirroring
    /// `visibleOffsetByDocumentMapping`) and maps the content delta through
    /// the engine's document mappings. Returns nil when the document model
    /// cannot map the offset, so callers fall back to the arithmetic.
    private static func sourceOffsetByDocumentMapping(
        forVisibleOffset visibleOffset: Int,
        lineRange: NSRange,
        hiddenPrefixLength: Int,
        visibleReplacementPrefixLength: Int,
        visibleLineLength: Int,
        document: WiskMarkdownDocument
    ) -> Int? {
        let block = document.blocks.first { candidate in
            lineRange.location >= candidate.sourceRange.location
                && lineRange.location < candidate.sourceRange.upperBound
        }
        let contentStart = block?.contentSourceRange.location ?? lineRange.location
        // Separator/blank blocks carry no mappings — the engine model and
        // the visible renderer disagree there (the renderer keeps "___" as
        // literal text), so the document probe would degenerate to offset 0.
        // Return nil and let the arithmetic fallback map the caret.
        guard document.mappings.contains(where: { NSIntersectionRange($0.sourceRange, lineRange).length > 0 }) else {
            return nil
        }
        guard contentStart >= lineRange.location,
              contentStart <= lineRange.upperBound,
              let contentVisible = document.visibleNSRange(forSourceRange: NSRange(location: contentStart, length: 0)) else {
            return nil
        }
        let renderedContentStart = visibleCaretOffset(
            forSourceOffset: contentStart - lineRange.location,
            hiddenPrefixLength: hiddenPrefixLength,
            visibleReplacementPrefixLength: visibleReplacementPrefixLength,
            visibleLineLength: visibleLineLength
        )
        guard visibleOffset >= renderedContentStart,
              visibleLineLength >= renderedContentStart else {
            return nil
        }
        let docVisibleLocation = contentVisible.location + (visibleOffset - renderedContentStart)
        guard let mapped = document.sourceNSRange(forVisibleRange: NSRange(location: docVisibleLocation, length: 0)) else {
            return nil
        }
        guard mapped.location >= lineRange.location, mapped.location <= lineRange.upperBound else { return nil }
        return mapped.location - lineRange.location
    }

    private static func sourceLocation(
        forVisibleOffset offset: Int,
        cells: [(visibleOffset: Int, sourceLocation: Int, length: Int)],
        fallback: Int
    ) -> Int {
        guard cells.isEmpty == false else { return fallback }
        for cell in cells {
            if offset < cell.visibleOffset + cell.length {
                return cell.sourceLocation + max(offset - cell.visibleOffset, 0)
            }
        }
        if let last = cells.last {
            return last.sourceLocation + last.length
        }
        return fallback
    }

    private static func visibleOffset(
        forSourceLocation location: Int,
        cells: [(visibleOffset: Int, sourceLocation: Int, length: Int)]
    ) -> Int {
        for cell in cells {
            if location <= cell.sourceLocation + cell.length {
                return cell.visibleOffset + max(location - cell.sourceLocation, 0)
            }
        }
        return cells.last.map { $0.visibleOffset + $0.length } ?? 0
    }

    private static func block(from line: String) -> RenderedBlock {
        if let attachment = attachmentImage(from: line) {
            return RenderedBlock(
                kind: .attachmentImage,
                headingLevel: nil,
                listNumber: nil,
                attachmentID: attachment.id,
                attachmentTitle: attachment.title,
                attachmentIsImage: true,
                visibleText: "[Image] \(attachment.title)",
                hiddenPrefixLength: (line as NSString).length
            )
        }
        if let attachment = attachmentFile(from: line) {
            return RenderedBlock(
                kind: .attachmentFile,
                headingLevel: nil,
                listNumber: nil,
                attachmentID: attachment.id,
                attachmentTitle: attachment.title,
                attachmentIsImage: false,
                visibleText: "[Attachment] \(attachment.title)",
                hiddenPrefixLength: (line as NSString).length
            )
        }
        if line.trimmingCharacters(in: .whitespaces) == "---" {
            return RenderedBlock(kind: .separator, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "────────", hiddenPrefixLength: 0)
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            return RenderedBlock(kind: .codeFence, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: line, hiddenPrefixLength: 0)
        }
        if line.hasPrefix("[^"), line.contains("]:") {
            return RenderedBlock(kind: .footnote, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: line, hiddenPrefixLength: 0)
        }
        if line.hasPrefix("> [!"), line.contains("]") {
            return RenderedBlock(kind: .callout, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "▌ " + String(line.dropFirst(2)), hiddenPrefixLength: 0)
        }
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("|"), trimmedLine.hasSuffix("|") {
            return RenderedBlock(kind: .table, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: line, hiddenPrefixLength: 0)
        }
        if let heading = heading(from: line) {
            return RenderedBlock(kind: .heading, headingLevel: heading.level, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: heading.content, hiddenPrefixLength: heading.markdownPrefixLength)
        }
        if line.hasPrefix("- [ ] ") {
            return RenderedBlock(kind: .checklistUnchecked, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "☐ " + String(line.dropFirst(6)), hiddenPrefixLength: 4)
        }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return RenderedBlock(kind: .checklistChecked, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "☑ " + String(line.dropFirst(6)), hiddenPrefixLength: 4)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return RenderedBlock(kind: .bullet, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "• " + String(line.dropFirst(2)), hiddenPrefixLength: 1)
        }
        if let numbered = numbered(from: line) {
            return RenderedBlock(kind: .numbered, headingLevel: nil, listNumber: numbered.number, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "\(numbered.number). \(numbered.content)", hiddenPrefixLength: 0)
        }
        if line.hasPrefix("> ") {
            return RenderedBlock(kind: .quote, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: "❝ " + String(line.dropFirst(2)), hiddenPrefixLength: 0)
        }
        return RenderedBlock(kind: .paragraph, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: line, hiddenPrefixLength: 0)
    }

    private static func block(in attributedString: NSAttributedString, lineRange: NSRange) -> RenderedBlock {
        let string = attributedString.string as NSString
        let line = string.substring(with: lineRange)
        guard lineRange.length > 0, lineRange.location < attributedString.length else {
            return RenderedBlock(kind: .paragraph, headingLevel: nil, listNumber: nil, attachmentID: nil, attachmentTitle: nil, attachmentIsImage: nil, visibleText: line, hiddenPrefixLength: 0)
        }
        let rawKind = attributedString.attribute(.wiskMarkdownBlockKind, at: lineRange.location, effectiveRange: nil) as? String
        let kind = rawKind.flatMap(BlockKind.init(rawValue:)) ?? .paragraph
        let headingLevel = attributedString.attribute(.wiskMarkdownHeadingLevel, at: lineRange.location, effectiveRange: nil) as? Int
        let listNumber = attributedString.attribute(.wiskMarkdownListNumber, at: lineRange.location, effectiveRange: nil) as? Int
        let attachmentIDString = attributedString.attribute(.wiskMarkdownAttachmentID, at: lineRange.location, effectiveRange: nil) as? String
        let attachmentTitle = attributedString.attribute(.wiskMarkdownAttachmentTitle, at: lineRange.location, effectiveRange: nil) as? String
        let attachmentIsImage = attributedString.attribute(.wiskMarkdownAttachmentIsImage, at: lineRange.location, effectiveRange: nil) as? Bool
        return RenderedBlock(
            kind: kind,
            headingLevel: headingLevel,
            listNumber: listNumber,
            attachmentID: attachmentIDString.flatMap(UUID.init(uuidString:)),
            attachmentTitle: attachmentTitle,
            attachmentIsImage: attachmentIsImage,
            visibleText: line,
            hiddenPrefixLength: 0
        )
    }

    private static func markdownLine(from attributedString: NSAttributedString, lineRange: NSRange) -> String {
        let block = block(in: attributedString, lineRange: lineRange)
        if let attachmentID = block.attachmentID {
            let title = nonEmpty(block.attachmentTitle) ?? block.visibleText
            if block.attachmentIsImage ?? (block.kind == .attachmentImage) {
                return "![\(escapeMarkdownTitle(title))](wisk-attachment://\(attachmentID.uuidString))"
            }
            return "[\(escapeMarkdownTitle(title))](wisk-attachment://\(attachmentID.uuidString))"
        }

        let content = inlineMarkdown(from: attributedString, range: lineRange)
        switch block.kind {
        case .heading:
            guard let headingLevel = block.headingLevel, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return content }
            return String(repeating: "#", count: headingLevel) + " " + content
        case .bullet:
            return "- " + content.removingPrefix("• ")
        case .numbered:
            let number = block.listNumber ?? Int(content.split(separator: ".", maxSplits: 1).first ?? "") ?? 1
            return "\(number). " + content.removingNumberedVisiblePrefix()
        case .checklistUnchecked:
            return "- [ ] " + content.removingPrefix("☐ ")
        case .checklistChecked:
            return "- [x] " + content.removingPrefix("☑ ")
        case .quote:
            return "> " + content.removingPrefix("❝ ")
        case .separator:
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "────────" || trimmed == "---" ? "---" : content
        case .callout:
            return "> " + content.removingPrefix("▌ ")
        case .codeFence, .table, .footnote, .paragraph, .attachmentImage, .attachmentFile:
            return content
        }
    }

    private static func attributedInlineString(from markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var remaining = markdown

        while !remaining.isEmpty {
            if let match = firstInlineMatch(in: remaining) {
                let prefix = String(remaining[..<match.fullRange.lowerBound])
                output.append(NSAttributedString(string: prefix))
                let start = output.length
                output.append(attributedInlineString(from: match.content))
                let range = NSRange(location: start, length: output.length - start)
                applyInlineStyle(match.style, to: output, range: range)
                remaining = String(remaining[match.fullRange.upperBound...])
            } else {
                output.append(NSAttributedString(string: remaining))
                remaining = ""
            }
        }

        return output
    }

    private static func attributedAttachmentString(
        _ attachment: NoteAttachment,
        fallbackText: String,
        availableWidth: CGFloat
    ) -> NSAttributedString {
        guard attachment.isPreviewVisible else {
            return NSAttributedString(string: fallbackText)
        }

        let imageStore = WiskAttachmentImageStore.shared

        if attachment.contentType == "application/pdf" {
            guard let data = imageStore.resolvedData(for: attachment) else {
                return attachmentPlaceholderString(
                    attachment,
                    fallbackText: fallbackText,
                    availableWidth: availableWidth
                )
            }
            #if os(iOS)
            guard let document = PDFDocument(data: data),
                  let page = document.page(at: 0) else {
                return NSAttributedString(string: fallbackText)
            }
            let thumbnail = page.thumbnail(of: CGSize(width: 640, height: 480), for: .mediaBox)
            let textAttachment = NSTextAttachment()
            textAttachment.image = thumbnail
            let requestedWidth = min(CGFloat(thumbnail.size.width), availableWidth)
            let ratio = thumbnail.size.height / max(thumbnail.size.width, 1)
            textAttachment.bounds = CGRect(x: 0, y: 0, width: requestedWidth, height: requestedWidth * ratio)
            return NSAttributedString(attachment: textAttachment)
            #elseif os(macOS)
            guard let document = PDFDocument(data: data),
                  let page = document.page(at: 0) else {
                return NSAttributedString(string: fallbackText)
            }
            let thumbnail = page.thumbnail(of: CGSize(width: 640, height: 480), for: .mediaBox)
            let requestedWidth = min(thumbnail.size.width, availableWidth)
            let ratio = thumbnail.size.height / max(thumbnail.size.width, 1)
            let requestedSize = NSSize(width: requestedWidth, height: requestedWidth * ratio)
            thumbnail.size = requestedSize
            let textAttachment = NSTextAttachment()
            textAttachment.image = thumbnail
            textAttachment.bounds = CGRect(origin: .zero, size: requestedSize)
            textAttachment.attachmentCell = NSTextAttachmentCell(imageCell: thumbnail)
            return NSAttributedString(attachment: textAttachment)
            #endif
        }

        guard attachment.isImage else {
            return NSAttributedString(string: fallbackText)
        }

        let requestedWidth = attachmentDisplayWidth(attachment, availableWidth: availableWidth)

        #if os(iOS)
        if let image = imageStore.displayImage(for: attachment, displayWidth: requestedWidth) {
            let textAttachment = NSTextAttachment()
            textAttachment.image = image
            let ratio = image.size.height / max(image.size.width, 1)
            textAttachment.bounds = CGRect(x: 0, y: 0, width: requestedWidth, height: requestedWidth * ratio)
            return NSAttributedString(attachment: textAttachment)
        }
        return attachmentPlaceholderString(
            attachment,
            fallbackText: fallbackText,
            availableWidth: availableWidth
        )
        #elseif os(macOS)
        if let image = imageStore.displayImage(for: attachment, displayWidth: requestedWidth) {
            let ratio = image.size.height / max(image.size.width, 1)
            let requestedSize = NSSize(width: requestedWidth, height: requestedWidth * ratio)
            image.size = requestedSize
            let textAttachment = NSTextAttachment()
            textAttachment.image = image
            textAttachment.bounds = CGRect(origin: .zero, size: requestedSize)
            textAttachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            return NSAttributedString(attachment: textAttachment)
        }
        return attachmentPlaceholderString(
            attachment,
            fallbackText: fallbackText,
            availableWidth: availableWidth
        )
        #endif
    }

    /// Placeholder block shown while an attachment downloads (or after a
    /// failure), sized to the attachment's display dimensions so layout stays
    /// stable when the real image arrives.
    private static func attachmentPlaceholderString(
        _ attachment: NoteAttachment,
        fallbackText: String,
        availableWidth: CGFloat
    ) -> NSAttributedString {
        let imageStore = WiskAttachmentImageStore.shared
        let phase = imageStore.phase(for: attachment)
        let output = NSMutableAttributedString()

        if let placeholder = WiskAttachmentPlaceholder.image(
            for: attachment,
            displayWidth: attachmentDisplayWidth(attachment, availableWidth: availableWidth),
            state: phase
        ) {
            let textAttachment = NSTextAttachment()
            let boundsWidth = min(attachmentDisplayWidth(attachment, availableWidth: availableWidth), availableWidth)
            let ratio = placeholder.size.height / max(placeholder.size.width, 1)
            #if os(macOS)
            let size = NSSize(width: boundsWidth, height: boundsWidth * ratio)
            placeholder.size = size
            textAttachment.bounds = CGRect(origin: .zero, size: size)
            textAttachment.attachmentCell = NSTextAttachmentCell(imageCell: placeholder)
            #else
            // iOS needs the image assigned directly; an NSTextAttachment with
            // bounds but no image renders UIKit's default document glyph
            // (the blank-page-with-folded-corner blob) instead of the
            // placeholder artwork.
            textAttachment.image = placeholder
            textAttachment.bounds = CGRect(x: 0, y: 0, width: boundsWidth, height: boundsWidth * ratio)
            #endif
            output.append(NSAttributedString(attachment: textAttachment))
        }

        if phase == .failed {
            if output.length > 0 {
                output.append(NSAttributedString(string: "  "))
            }
            output.append(NSAttributedString(string: fallbackText))
        }
        return output.length > 0 ? output : NSAttributedString(string: fallbackText)
    }

    private static func attachmentDisplayWidth(_ attachment: NoteAttachment, availableWidth: CGFloat) -> CGFloat {
        attachment.renderedDisplayWidth(availableWidth: availableWidth)
    }

    private enum InlineStyle {
        case bold
        case italic
        case code
        case underline
        case strikethrough
        case highlight
        case link(String)
        case wikiLink(String)
        case footnoteReference(String)
        case tag
    }

    private static func firstInlineMatch(in string: String) -> (fullRange: Range<String.Index>, content: String, style: InlineStyle)? {
        var semanticMatches: [(fullRange: Range<String.Index>, content: String, style: InlineStyle)] = []

        if let open = string.range(of: "[["),
           let close = string[open.upperBound...].range(of: "]]") {
            let inner = String(string[open.upperBound..<close.lowerBound])
            if !inner.isEmpty {
                let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                let target = parts[0]
                let label = parts.count > 1 ? parts[1] : target
                semanticMatches.append((open.lowerBound..<close.upperBound, label, .wikiLink(target)))
            }
        }

        if let open = string.range(of: "[^"),
           let close = string[open.upperBound...].firstIndex(of: "]") {
            let content = String(string[open.upperBound..<close])
            if !content.isEmpty {
                semanticMatches.append((open.lowerBound..<string.index(after: close), content, .footnoteReference(content)))
            }
        }

        if let open = string.firstIndex(of: "["),
           !string[open...].hasPrefix("[["),
           !string[open...].hasPrefix("[^"),
           let titleEnd = string[open...].firstIndex(of: "]"),
           titleEnd < string.endIndex {
            let afterTitle = string.index(after: titleEnd)
            if afterTitle < string.endIndex,
               string[afterTitle] == "(",
               let destinationEnd = string[string.index(after: afterTitle)...].firstIndex(of: ")") {
                let title = String(string[string.index(after: open)..<titleEnd])
                let destination = String(string[string.index(after: afterTitle)..<destinationEnd])
                if !title.isEmpty, isSafeLinkDestination(destination) {
                    semanticMatches.append((open..<string.index(after: destinationEnd), title, .link(destination)))
                }
            }
        }

        if let hash = string.firstIndex(of: "#"),
           (hash == string.startIndex || string[string.index(before: hash)].isWhitespace) {
            let end = string[hash...].firstIndex(where: { $0.isWhitespace || $0.isPunctuation && $0 != "-" && $0 != "_" }) ?? string.endIndex
            let tag = String(string[hash..<end])
            if tag.count > 1 {
                semanticMatches.append((hash..<end, tag, .tag))
            }
        }

        let tokens: [(open: String, close: String, style: InlineStyle)] = [
            ("**", "**", .bold),
            ("`", "`", .code),
            ("~~", "~~", .strikethrough),
            ("==", "==", .highlight),
            ("<u>", "</u>", .underline),
            ("*", "*", .italic),
        ]

        var tokenMatches: [(fullRange: Range<String.Index>, content: String, style: InlineStyle)] = tokens.compactMap { token in
            guard let openRange = string.range(of: token.open) else { return nil }
            let contentStart = openRange.upperBound
            guard let closeRange = string[contentStart...].range(of: token.close) else { return nil }
            let content = String(string[contentStart..<closeRange.lowerBound])
            guard !content.isEmpty else { return nil }
            return (openRange.lowerBound..<closeRange.upperBound, content, token.style)
        }
        // "_italic_" — mirrors the engine's flanking rule: intra-word
        // underscores (snake_case_test) stay literal, otherwise the engine
        // hides markers the visible text keeps printing and caret maps
        // drift by the hidden marker width.
        if let underscoreMatch = underscoreItalicMatch(in: string) {
            tokenMatches.append(underscoreMatch)
        }
        return (semanticMatches + tokenMatches).min { lhs, rhs in
            lhs.fullRange.lowerBound < rhs.fullRange.lowerBound
        }
    }

    private static func underscoreItalicMatch(in string: String) -> (fullRange: Range<String.Index>, content: String, style: InlineStyle)? {
        var searchStart = string.startIndex
        while let open = string.range(of: "_", range: searchStart..<string.endIndex) {
            searchStart = open.upperBound
            // Opening flanking: not preceded by an alphanumeric/underscore.
            if open.lowerBound > string.startIndex {
                let preceding = string[string.index(before: open.lowerBound)]
                if preceding.isLetter || preceding.isNumber || preceding == "_" {
                    continue
                }
            }
            // Content must start with a non-space and be non-empty.
            guard open.upperBound < string.endIndex, !string[open.upperBound].isWhitespace else { continue }
            // Find the closing underscore: the first one with non-space
            // content before it that is not followed by an
            // alphanumeric/underscore (mirrors (?=\S).+?(?<=\S)_).
            var closeSearch = open.upperBound
            while let close = string.range(of: "_", range: closeSearch..<string.endIndex) {
                let content = string[open.upperBound..<close.lowerBound]
                // Content must not start or end with `_` — that keeps
                // triple-underscore runs ("___", "___x") literal, matching
                // the engine's underscore wrapper regex.
                guard !content.isEmpty,
                      content.first! != "_",
                      content.last! != "_",
                      !content.first!.isWhitespace,
                      !content.last!.isWhitespace else {
                    closeSearch = close.upperBound
                    continue
                }
                if close.upperBound < string.endIndex {
                    let following = string[close.upperBound]
                    if following.isLetter || following.isNumber || following == "_" {
                        closeSearch = close.upperBound
                        continue
                    }
                }
                return (open.lowerBound..<close.upperBound, String(content), .italic)
            }
        }
        return nil
    }

    private static func applyInlineStyle(_ style: InlineStyle, to attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        switch style {
        case .bold:
            attributedString.addAttribute(.wiskMarkdownInlineBold, value: true, range: range)
        case .italic:
            attributedString.addAttribute(.wiskMarkdownInlineItalic, value: true, range: range)
        case .code:
            attributedString.addAttribute(.wiskMarkdownInlineCode, value: true, range: range)
            attributedString.addAttribute(.font, value: platformMonospacedFont(size: CGFloat(WiskEditorDefaults.defaultFontSize)), range: range)
        case .underline:
            attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .strikethrough:
            attributedString.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .highlight:
            attributedString.addAttribute(.wiskMarkdownInlineHighlight, value: true, range: range)
            attributedString.addAttribute(.backgroundColor, value: platformHighlightColor, range: range)
        case .link(let destination):
            attributedString.addAttribute(.wiskMarkdownLinkDestination, value: destination, range: range)
            if let url = URL(string: destination) {
                attributedString.addAttribute(.link, value: url, range: range)
            }
            attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .wikiLink(let title):
            attributedString.addAttribute(.wiskMarkdownWikiLink, value: title, range: range)
            if let url = WiskNoteLinkService.wikiURL(forTarget: title) {
                attributedString.addAttribute(.link, value: url, range: range)
            }
            attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .footnoteReference(let label):
            attributedString.addAttribute(.wiskMarkdownFootnoteReference, value: label, range: range)
            attributedString.addAttribute(.baselineOffset, value: 4, range: range)
        case .tag:
            attributedString.addAttribute(.wiskMarkdownTag, value: true, range: range)
        }
    }

    private static func applyInlineVisualAttributes(
        to attributedString: NSMutableAttributedString,
        range: NSRange,
        fontSelection: WiskEditorFontSelection,
        baseFontSize: CGFloat
    ) {
        guard range.length > 0 else { return }
        var operations: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        attributedString.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            var visualAttributes: [NSAttributedString.Key: Any] = [:]
            if attributes[.wiskMarkdownInlineCode] as? Bool == true {
                visualAttributes[.font] = platformMonospacedFont(size: baseFontSize)
            } else if attributes[.wiskMarkdownInlineBold] as? Bool == true {
                visualAttributes[.font] = platformFont(fontSelection: fontSelection, size: baseFontSize, weight: .bold)
            }
            if attributes[.wiskMarkdownInlineItalic] as? Bool == true {
                visualAttributes[.obliqueness] = 0.14
            }
            if attributes[.wiskMarkdownInlineHighlight] as? Bool == true {
                visualAttributes[.backgroundColor] = platformHighlightColor
            }
            if !visualAttributes.isEmpty {
                operations.append((subrange, visualAttributes))
            }
        }
        for operation in operations {
            attributedString.addAttributes(operation.attributes, range: operation.range)
        }
    }

    /// Marks every visible search hit without using `.wiskMarkdownInlineHighlight`,
    /// so `markdown(from:)` will not wrap matches in `==`. Returns the first match.
    @discardableResult
    static func applySearchHighlights(
        to attributedString: NSMutableAttributedString,
        searchText: String
    ) -> NSRange? {
        removeSearchHighlights(from: attributedString)
        let ranges = NoteSearchEngine.visibleMatchRanges(in: attributedString.string, searchText: searchText)
        let color = platformSearchHighlightColor
        for range in ranges {
            attributedString.addAttribute(.wiskSearchHighlight, value: true, range: range)
            attributedString.addAttribute(.backgroundColor, value: color, range: range)
        }
        return ranges.first
    }

    static func copyWithoutSearchHighlights(_ attributedString: NSAttributedString) -> NSAttributedString {
        guard attributedString.length > 0 else { return attributedString }
        var hasSearch = false
        attributedString.enumerateAttribute(
            .wiskSearchHighlight,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            if value as? Bool == true {
                hasSearch = true
                stop.pointee = true
            }
        }
        guard hasSearch else { return attributedString }
        let mutable = attributedString.mutableCopy() as! NSMutableAttributedString
        removeSearchHighlights(from: mutable)
        return mutable
    }

    private static func removeSearchHighlights(from attributedString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        guard fullRange.length > 0 else { return }
        var previous: [NSRange] = []
        attributedString.enumerateAttribute(.wiskSearchHighlight, in: fullRange) { value, range, _ in
            if value as? Bool == true {
                previous.append(range)
            }
        }
        for range in previous {
            attributedString.removeAttribute(.wiskSearchHighlight, range: range)
            attributedString.removeAttribute(.backgroundColor, range: range)
            var restore: [NSRange] = []
            attributedString.enumerateAttribute(.wiskMarkdownInlineHighlight, in: range) { value, subrange, _ in
                if value as? Bool == true {
                    restore.append(subrange)
                }
            }
            for subrange in restore {
                attributedString.addAttribute(.backgroundColor, value: platformHighlightColor, range: subrange)
            }
        }
    }

    private static func inlineMarkdown(from attributedString: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var output = ""
        attributedString.enumerateAttributes(in: range) { attributes, subrange, _ in
            let text = (attributedString.string as NSString).substring(with: subrange)
            var wrapped = text
            if attributes[.wiskMarkdownInlineCode] as? Bool == true {
                wrapped = "`\(wrapped)`"
            }
            if attributes[.wiskMarkdownInlineBold] as? Bool == true {
                wrapped = "**\(wrapped)**"
            }
            if attributes[.wiskMarkdownInlineItalic] as? Bool == true {
                wrapped = "*\(wrapped)*"
            }
            if attributes[.underlineStyle] != nil,
               attributes[.wiskMarkdownLinkDestination] == nil,
               attributes[.wiskMarkdownWikiLink] == nil {
                wrapped = "<u>\(wrapped)</u>"
            }
            if attributes[.strikethroughStyle] != nil {
                wrapped = "~~\(wrapped)~~"
            }
            if attributes[.wiskMarkdownInlineHighlight] as? Bool == true {
                wrapped = "==\(wrapped)=="
            }
            if let destination = attributes[.wiskMarkdownLinkDestination] as? String {
                wrapped = "[\(wrapped)](\(destination))"
            }
            if let title = attributes[.wiskMarkdownWikiLink] as? String {
                if wrapped == title {
                    wrapped = "[[\(title)]]"
                } else {
                    wrapped = "[[\(title)|\(wrapped)]]"
                }
            }
            if let label = attributes[.wiskMarkdownFootnoteReference] as? String {
                wrapped = "[^\(label)]"
            }
            output += wrapped
        }
        return output
    }

    private static func isSafeLinkDestination(_ destination: String) -> Bool {
        guard let components = URLComponents(string: destination) else { return false }
        guard let scheme = components.scheme?.lowercased() else {
            return !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return ["http", "https", "mailto", "tel"].contains(scheme)
    }

    private static func escapeMarkdownTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "]", with: "\\]")
    }

    private static func attachmentImage(from line: String) -> (id: UUID, title: String)? {
        guard line.hasPrefix("!["),
              let altEnd = line.firstIndex(of: "]"),
              line[line.index(after: altEnd)...].hasPrefix("(wisk-attachment://"),
              line.hasSuffix(")") else {
            return nil
        }
        let title = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd])
        let urlStart = line.index(altEnd, offsetBy: 2)
        let urlEnd = line.index(before: line.endIndex)
        let prefix = "wisk-attachment://"
        let rawURL = String(line[urlStart..<urlEnd])
        guard rawURL.hasPrefix(prefix),
              let id = UUID(uuidString: String(rawURL.dropFirst(prefix.count))) else {
            return nil
        }
        return (id, nonEmpty(title) ?? "Image")
    }

    private static func attachmentFile(from line: String) -> (id: UUID, title: String)? {
        guard line.hasPrefix("["),
              let titleEnd = line.firstIndex(of: "]"),
              line[line.index(after: titleEnd)...].hasPrefix("(wisk-attachment://"),
              line.hasSuffix(")") else {
            return nil
        }
        let title = String(line[line.index(after: line.startIndex)..<titleEnd])
        let urlStart = line.index(titleEnd, offsetBy: 2)
        let urlEnd = line.index(before: line.endIndex)
        let prefix = "wisk-attachment://"
        let rawURL = String(line[urlStart..<urlEnd])
        guard rawURL.hasPrefix(prefix),
              let id = UUID(uuidString: String(rawURL.dropFirst(prefix.count))) else {
            return nil
        }
        return (id, nonEmpty(title) ?? "Attachment")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func numbered(from line: String) -> (number: Int, content: String)? {
        let components = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let number = Int(components[0].trimmingCharacters(in: .whitespaces)),
              components[1].hasPrefix(" ") else {
            return nil
        }
        return (number, String(components[1].dropFirst()))
    }

    private static func heading(from line: String) -> (level: Int, content: String, markdownPrefixLength: Int)? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount),
              line.dropFirst(markerCount).first == " " else {
            return nil
        }

        return (
            level: markerCount,
            content: String(line.dropFirst(markerCount + 1)),
            markdownPrefixLength: markerCount + 1
        )
    }

    private static func typedHeadingShortcut(in line: String) -> (level: Int, leadingWhitespaceLength: Int, markdownPrefixLength: Int)? {
        let nsLine = line as NSString
        let trimmed = line.trimmingCharacters(in: .newlines)
        let leadingWhitespaceLength = trimmed.prefix(while: { $0 == " " || $0 == "\t" }).count
        let candidate = String(trimmed.dropFirst(leadingWhitespaceLength))
        let markerCount = candidate.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount),
              candidate.dropFirst(markerCount).first == " ",
              candidate.dropFirst(markerCount + 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return (
            level: markerCount,
            leadingWhitespaceLength: min(leadingWhitespaceLength, nsLine.length),
            markdownPrefixLength: markerCount + 1
        )
    }

    private static func typedBlockShortcut(in line: String) -> BlockShortcut? {
        let nsLine = line as NSString
        let trimmed = line.trimmingCharacters(in: .newlines)
        let leadingWhitespaceLength = trimmed.prefix(while: { $0 == " " || $0 == "\t" }).count
        let candidate = String(trimmed.dropFirst(leadingWhitespaceLength))

        if let heading = typedHeadingShortcut(in: line) {
            return BlockShortcut(
                kind: .heading,
                level: heading.level,
                listNumber: nil,
                leadingWhitespaceLength: heading.leadingWhitespaceLength,
                markdownPrefixLength: heading.markdownPrefixLength,
                visiblePrefix: ""
            )
        }

        let shortcuts: [(prefix: String, kind: BlockKind, visiblePrefix: String)] = [
            ("- ", .bullet, "• "),
            ("* ", .bullet, "• "),
            ("[] ", .checklistUnchecked, "☐ "),
            ("[ ] ", .checklistUnchecked, "☐ "),
            ("[x] ", .checklistChecked, "☑ "),
            ("[X] ", .checklistChecked, "☑ "),
            ("> ", .quote, "❝ "),
        ]

        for shortcut in shortcuts where candidate == shortcut.prefix {
            return BlockShortcut(
                kind: shortcut.kind,
                level: nil,
                listNumber: nil,
                leadingWhitespaceLength: min(leadingWhitespaceLength, nsLine.length),
                markdownPrefixLength: (shortcut.prefix as NSString).length,
                visiblePrefix: shortcut.visiblePrefix
            )
        }

        if candidate == "1. " {
            return BlockShortcut(
                kind: .numbered,
                level: nil,
                listNumber: 1,
                leadingWhitespaceLength: min(leadingWhitespaceLength, nsLine.length),
                markdownPrefixLength: 3,
                visiblePrefix: "1. "
            )
        }

        return nil
    }

    private static func headingLevel(in attributedString: NSAttributedString, lineRange: NSRange) -> Int? {
        guard lineRange.location < attributedString.length else { return nil }
        let level = attributedString.attribute(.wiskMarkdownHeadingLevel, at: lineRange.location, effectiveRange: nil) as? Int
        return level.flatMap { (1...6).contains($0) ? $0 : nil }
    }

    static func fontSize(forHeadingLevel level: Int?, baseFontSize: CGFloat) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 14
        case 2: return baseFontSize + 10
        case 3: return baseFontSize + 7
        case 4: return baseFontSize + 5
        case 5: return baseFontSize + 3
        case 6: return baseFontSize + 1
        default: return baseFontSize
        }
    }

    static func swiftUIFontWeight(forHeadingLevel level: Int?) -> Font.Weight {
        switch level {
        case 1, 2:
            return .bold
        case 3, 4:
            return .semibold
        case 5, 6:
            return .medium
        default:
            return .regular
        }
    }

    private static func fontWeight(forHeadingLevel level: Int?) -> FontWeight {
        switch level {
        case 1, 2:
            return .bold
        case 3, 4:
            return .semibold
        case 5, 6:
            return .medium
        default:
            return .regular
        }
    }

    private static func paragraphStyle(forHeadingLevel level: Int?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        guard let level else { return style }

        switch level {
        case 1:
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 7
        case 2:
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 6
        case 3:
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 5
        case 4:
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 4
        case 5:
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 3
        case 6:
            style.paragraphSpacingBefore = 5
            style.paragraphSpacing = 3
        default:
            break
        }
        return style
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func removingNumberedVisiblePrefix() -> String {
        let components = split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              Int(components[0].trimmingCharacters(in: .whitespaces)) != nil,
              components[1].hasPrefix(" ") else {
            return self
        }
        return String(components[1].dropFirst())
    }
}

#if os(iOS) || os(macOS)
private func wiskAttachmentRenderFingerprint(_ attachments: [NoteAttachment]) -> String {
    let imageStore = WiskAttachmentImageStore.shared
    return attachments
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map {
            [
                $0.id.uuidString,
                $0.localCachePath ?? "",
                $0.uploadStatusRaw,
                imageStore.phase(for: $0).renderToken,
                $0.displayWidth.map { String($0) } ?? "fit",
                $0.alignment.rawValue,
                $0.isPreviewVisible ? "preview" : "hidden",
                $0.fileName,
                $0.altText,
                String($0.storedWidth),
                String($0.storedHeight),
                String($0.byteSize),
                String($0.updatedAt.timeIntervalSinceReferenceDate),
            ].joined(separator: ":")
        }
        .joined(separator: "|")
}

private func wiskRichEditorAvailableWidth(
    boundsWidth: CGFloat,
    horizontalInset: CGFloat,
    lineFragmentPadding: CGFloat
) -> CGFloat {
    let width = boundsWidth - horizontalInset - (lineFragmentPadding * 2)
    return width > 80 ? width : WiskAttachmentImageLayout.defaultAvailableWidth
}

private func wiskImageAttachment(
    at index: Int,
    in attributedString: NSAttributedString,
    attachments: [NoteAttachment]
) -> NoteAttachment? {
    guard let attachment = wiskEditorAttachment(at: index, in: attributedString, attachments: attachments),
          attachment.isImage else {
        return nil
    }
    return attachment
}

private func wiskEditorAttachment(
    at index: Int,
    in attributedString: NSAttributedString,
    attachments: [NoteAttachment]
) -> NoteAttachment? {
    guard attributedString.length > 0 else { return nil }
    let location = min(max(index, 0), attributedString.length - 1)
    guard let idString = attributedString.attribute(.wiskMarkdownAttachmentID, at: location, effectiveRange: nil) as? String,
          let id = UUID(uuidString: idString) else {
        return nil
    }
    return attachments.first(where: { $0.id == id })
}

enum WiskRichEditorSourceEditing {
    static func mappedSourceRange(
        visibleRange: NSRange,
        source: String,
        showSourceMarkers: Bool,
        document: WiskMarkdownDocument? = nil,
        foldedLocations: Set<Int> = []
    ) -> NSRange? {
        if showSourceMarkers {
            let length = (source as NSString).length
            let location = min(max(visibleRange.location, 0), length)
            let lengthClamped = min(max(visibleRange.length, 0), max(length - location, 0))
            return NSRange(location: location, length: lengthClamped)
        }
        let parsed = document ?? WiskMarkdownDocumentEngine.parse(source)
        if let rendererRange = WiskRichMarkdownDocument.markdownRange(
            forVisibleRange: visibleRange,
            in: source,
            document: parsed,
            foldedLocations: foldedLocations
        ) {
            return NSRange(rendererRange, in: source)
        }
        return parsed.sourceNSRange(forVisibleRange: visibleRange)
    }

    static func selectedMarkdownRange(
        from sourceRange: NSRange,
        in source: String
    ) -> Range<String.Index>? {
        Range(sourceRange, in: source)
    }
}

enum WiskAttachmentEditorAction {
    case displayWidth(Double?)
    case alignment(NoteAttachmentAlignment)
    case previewVisible(Bool)
    case editDetails
    case crop
}

private func wiskEditorAttachment(
    near range: NSRange,
    in attributedString: NSAttributedString,
    attachments: [NoteAttachment]
) -> NoteAttachment? {
    let candidates = [
        range.location,
        max(range.location - 1, 0),
        min(range.location + max(range.length, 1) - 1, max(attributedString.length - 1, 0)),
    ]
    for index in candidates {
        if let attachment = wiskEditorAttachment(at: index, in: attributedString, attachments: attachments) {
            return attachment
        }
    }
    return nil
}

private func wiskImageAttachment(
    near range: NSRange,
    in attributedString: NSAttributedString,
    attachments: [NoteAttachment]
) -> NoteAttachment? {
    guard let attachment = wiskEditorAttachment(near: range, in: attributedString, attachments: attachments),
          attachment.isImage else {
        return nil
    }
    return attachment
}

enum WiskActiveMarkdownEditor {
    static weak var textView: AnyObject?

    static func claim(_ editor: AnyObject) {
        textView = editor
    }

    static func canHandle(from editor: AnyObject, request: WiskMarkdownFormattingRequest) -> Bool {
        guard request.handled == false else { return false }
        if textView === editor { return true }
        return textView == nil
    }

    @discardableResult
    static func apply(_ action: WiskMarkdownFormattingAction) -> Bool {
        let request = WiskMarkdownFormattingRequest(action: action)
        #if os(macOS)
        if let textView = textView as? WiskMarkdownNSTextView {
            textView.handleFormattingRequest(request)
            return request.handled
        }
        #endif
        NotificationCenter.default.post(name: .wiskApplyMarkdownEditorFormatting, object: request)
        return request.handled
    }
}

struct WiskRichMarkdownEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService

    @Binding var markdownText: String
    @Binding var selectedMarkdownRange: Range<String.Index>?

    var attachments: [NoteAttachment] = []
    var fontSelection: WiskEditorFontSelection = .system
    var baseFontSize: CGFloat = CGFloat(WiskEditorDefaults.defaultFontSize)
    var minHeight: CGFloat? = nil
    var isEditable: Bool = true
    var showSourceMarkers: Bool = false
    var searchHighlightText: String = ""
    var contentGutter: CGFloat = 0
    var wikiLinkTitles: [String] = []
    var jumpToSourceRange: NSRange? = nil
    var foldedSourceLocations: Binding<Set<Int>> = .constant([])
    var documentIdentity: UUID? = nil
    var accessibilityIdentifier: String = "wisk.richMarkdownEditor"
    var onFocusChange: ((Bool) -> Void)? = nil
    var onOpenWikiLink: ((String) -> Void)? = nil
    var onJumpHandled: (() -> Void)? = nil
    var onWikiQueryChanged: ((String?) -> Void)? = nil
    var onEditAttachmentDetails: ((NoteAttachment) -> Void)? = nil
    var onPasteImage: (() -> Void)? = nil
    var bodyFocusRequestID: UUID? = nil
    var onBodyFocusHandled: (() -> Void)? = nil

    @Environment(WiskAttachmentService.self) private var attachmentService
    @State private var wikiCaretOffset = CGSize.zero
    @State private var croppingAttachment: NoteAttachment?
    @State private var cropImageData: Data?
    @State private var markerCaretUTF16: Int?
    @State private var markerCaretDocumentID: UUID?
    @State private var attachmentResolutionTick = 0

    var body: some View {
        // attachmentResolutionTick updates whenever an attachment's resolution
        // phase changes, so updateUIView re-applies the markdown (and swaps
        // placeholders for real images) when downloads complete or fail.
        let _ = attachmentResolutionTick
        PlatformRichMarkdownTextView(
            markdownText: $markdownText,
            selectedMarkdownRange: $selectedMarkdownRange,
            attachments: attachments,
            fontSelection: fontSelection,
            baseFontSize: baseFontSize,
            isEditable: isEditable,
            minHeight: minHeight,
            showSourceMarkers: showSourceMarkers,
            searchHighlightText: searchHighlightText,
            contentGutter: contentGutter,
            wikiLinkTitles: wikiLinkTitles,
            jumpToSourceRange: jumpToSourceRange,
            foldedSourceLocations: foldedSourceLocations,
            documentIdentity: documentIdentity,
            accessibilityIdentifier: accessibilityIdentifier,
            onFocusChange: onFocusChange,
            onOpenWikiLink: onOpenWikiLink,
            onJumpHandled: onJumpHandled,
            onWikiQueryChanged: onWikiQueryChanged,
            onWikiCaretOffset: { wikiCaretOffset = $0 },
            onMarkerCaret: { caret in
                markerCaretUTF16 = caret
                markerCaretDocumentID = caret == nil ? nil : documentIdentity
            },
            onAttachmentDisplayWidthChange: { id, width in
                applyAttachmentAction(id, .displayWidth(width))
            },
            onAttachmentAction: applyAttachmentAction,
            onPasteImage: onPasteImage,
            bodyFocusRequestID: bodyFocusRequestID,
            onBodyFocusHandled: onBodyFocusHandled
        )
        .frame(minHeight: minHeight)
        .onReceive(
            NotificationCenter.default
                .publisher(for: WiskAttachmentImageStore.resolutionDidChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            attachmentResolutionTick += 1
        }
        .overlay(alignment: .topLeading) {
            if !wikiLinkTitles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(wikiLinkTitles, id: \.self) { title in
                        Button(title) {
                            insertWikiLinkSuggestion(title)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .offset(wikiCaretOffset)
                .padding(8)
                .accessibilityIdentifier("wisk.editor.wikiLinkSuggestions")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let activeMarkerLabel, !showSourceMarkers {
                Text(activeMarkerLabel)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityLabel("Active Markdown syntax: \(activeMarkerLabel)")
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(
            get: { croppingAttachment != nil && cropImageData != nil },
            set: { if !$0 { croppingAttachment = nil } }
        )) {
            if let cropImageData, let attachment = croppingAttachment {
                WiskImageCropSheet(
                    imageData: cropImageData,
                    onCrop: { rect in
                        applyCrop(attachment, normalizedRect: rect)
                        croppingAttachment = nil
                    },
                    onCancel: { croppingAttachment = nil }
                )
            }
        }
        .onAppear {
            WiskAttachmentImageStore.shared.configure(service: attachmentService)
        }
    }

    private func applyAttachmentAction(_ attachmentID: UUID, _ action: WiskAttachmentEditorAction) {
        guard let attachment = attachments.first(where: { $0.id == attachmentID }) else { return }
        switch action {
        case .displayWidth(let width):
            attachment.displayWidth = width
        case .alignment(let alignment):
            attachment.alignment = alignment
        case .previewVisible(let visible):
            attachment.isPreviewVisible = visible
        case .editDetails:
            onEditAttachmentDetails?(attachment)
            return
        case .crop:
            Task {
                cropImageData = await attachmentService.data(for: attachment)
                croppingAttachment = attachment
            }
            return
        }
        persistAttachment(attachment)
    }

    private func applyCrop(_ attachment: NoteAttachment, normalizedRect: CGRect) {
        guard let cropImageData else { return }
        do {
            let cropped = try WiskAttachmentService.crop(imageData: cropImageData, normalizedRect: normalizedRect)
            let normalized = try attachmentService.replaceCroppedImage(attachment, croppedData: cropped)
            persistAttachment(attachment)
            if let note = attachment.note {
                Task {
                    await attachmentService.upload(attachment, data: normalized.data, noteID: note.id)
                    persistAttachment(attachment)
                }
            }
        } catch {
            attachment.lastError = error.localizedDescription
        }
        self.cropImageData = nil
    }

    private func persistAttachment(_ attachment: NoteAttachment) {
        attachment.updatedAt = Date()
        guard let note = attachment.note else {
            try? modelContext.save()
            return
        }
        note.updatedAt = Date()
        note.syncStatus = .queued
        do {
            try modelContext.save()
            syncService.enqueue(note: note, context: modelContext)
        } catch {
            attachment.lastError = error.localizedDescription
        }
    }

    private func insertWikiLinkSuggestion(_ title: String) {
        let ns = markdownText as NSString
        let caret = markerSourceCaretUTF16 ?? ns.length
        guard let partial = WiskMarkdownDocumentEngine.wikiLinkPartial(in: markdownText, sourceCaret: caret) else { return }
        let open = "[[\(partial)"
        let found = ns.range(of: open, options: .backwards, range: NSRange(location: 0, length: caret))
        guard found.location != NSNotFound else { return }
        var length = found.length
        let after = found.upperBound
        if after + 2 <= ns.length, ns.substring(with: NSRange(location: after, length: 2)) == "]]" {
            length += 2
        }
        guard let mutation = WiskMarkdownDocumentEngine.replaceSourceRange(
            in: markdownText,
            sourceRange: NSRange(location: found.location, length: length),
            with: WiskMarkdownDocumentEngine.wikiLinkReplacement(title: title, partial: partial)
        ) else { return }
        markdownText = mutation.source
        selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
        onWikiQueryChanged?(nil)
    }

    /// UTF-16 caret for overlays. Never convert a leftover `Range<String.Index>` against a new note.
    private var markerSourceCaretUTF16: Int? {
        guard markerCaretDocumentID == documentIdentity, let caret = markerCaretUTF16 else { return nil }
        let length = (markdownText as NSString).length
        guard caret >= 0, caret <= length else { return nil }
        return caret
    }

    private var activeMarkerLabel: String? {
        guard let caret = markerSourceCaretUTF16 else { return nil }
        let document = WiskMarkdownDocumentEngine.parse(markdownText)
        let block = document.blocks.first {
            caret >= $0.sourceRange.location && caret <= $0.sourceRange.upperBound
        }
        guard let block else { return nil }

        if let inline = flattened(block.inlineSpans).last(where: {
            caret >= $0.sourceRange.location && caret <= $0.sourceRange.upperBound
        }) {
            switch inline.kind {
            case .bold: return "** Bold"
            case .italic: return "* Italic"
            case .underline: return "<u> Underline"
            case .strikethrough: return "~~ Strikethrough"
            case .highlight: return "== Highlight"
            case .code: return "` Code"
            case .link: return "[]() Link"
            case .wikilink: return "[[]] WikiLink"
            case .footnoteReference: return "[^] Footnote"
            case .tag: return "# Tag"
            }
        }

        switch block.kind {
        case .heading(let level): return "\(String(repeating: "#", count: level)) Heading"
        case .bullet: return "- List"
        case .ordered: return "1. List"
        case .task: return "- [ ] Task"
        case .quote: return "> Quote"
        case .callout: return "> [!] Callout"
        case .fencedCode: return "``` Code block"
        case .tableRow, .tableDivider: return "| Table"
        case .footnoteDefinition: return "[^]: Footnote"
        case .separator: return "--- Separator"
        case .attachment: return "wisk-attachment://"
        case .paragraph, .blankLine: return nil
        }
    }

    private func flattened(_ spans: [WiskMarkdownInlineSpan]) -> [WiskMarkdownInlineSpan] {
        spans.flatMap { [$0] + flattened($0.children) }
    }
}
#endif

#if os(iOS)
private final class WiskMarkdownUITextView: UITextView, UIGestureRecognizerDelegate {
    var onIndent: ((Bool) -> Void)?
    var onLayout: (() -> Void)?
    var onAttachmentDisplayWidthChange: ((UUID, Double?) -> Void)?
    var onApplyFormatting: ((WiskMarkdownFormattingRequest) -> Void)?
    var markCaretUserInitiated: (() -> Void)?
    var commitCaret: ((NSRange) -> Void)?
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    fileprivate var isHandlingKeyInput = false
    var imageAttachmentsProvider: () -> [NoteAttachment] = { [] }

    let imageResizeController = WiskImageAttachmentResizeController()
    private var observesEditorCommands = false
    private var resizePan: UIPanGestureRecognizer?
    private var imageTap: UITapGestureRecognizer?
    private var checklistTap: UITapGestureRecognizer?
    var onToggleChecklist: ((Int) -> Void)?

    func observeEditorCommands() {
        guard !observesEditorCommands else { return }
        observesEditorCommands = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoEditing),
            name: .wiskUndoMarkdownEditor,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redoEditing),
            name: .wiskRedoMarkdownEditor,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyEditorFormatting(_:)),
            name: .wiskApplyMarkdownEditorFormatting,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentInNoteFind),
            name: .wiskFindInNote,
            object: nil
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            observeEditorCommands()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        markCaretUserInitiated?()
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        commitCaret?(selectedRange)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        markCaretUserInitiated?()
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        commitCaret?(selectedRange)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
        refreshImageResizeChrome()
    }

    override func insertText(_ text: String) {
        markCaretUserInitiated?()
        if markedTextRange != nil {
            super.insertText(text)
            return
        }
        // Newlines keep the engine path so Return semantics (list/checklist/
        // quote continuation) apply synchronously. Everything else goes
        // through UIKit's native input pipeline (super) so spell check,
        // QuickType, and autocorrection keep working; the engine stays the
        // source of truth via the shouldChangeTextIn / textViewDidChange
        // commit machinery.
        if text == "\n", let onInsertText {
            isHandlingKeyInput = true
            defer { isHandlingKeyInput = false }
            onInsertText(text)
            return
        }
        super.insertText(text)
    }

    override func deleteBackward() {
        markCaretUserInitiated?()
        if markedTextRange != nil {
            super.deleteBackward()
            return
        }
        if let onDeleteBackward {
            isHandlingKeyInput = true
            defer { isHandlingKeyInput = false }
            onDeleteBackward()
            return
        }
        super.deleteBackward()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configureImageResize() {
        imageResizeController.attach(to: self)
        guard resizePan == nil else { return }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleImageResizePan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        addGestureRecognizer(pan)
        panGestureRecognizer.require(toFail: pan)
        resizePan = pan

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleImageResizeTap(_:)))
        tap.delegate = self
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
        imageTap = tap

        let checklist = UITapGestureRecognizer(target: self, action: #selector(handleChecklistTap(_:)))
        checklist.delegate = self
        checklist.cancelsTouchesInView = true
        addGestureRecognizer(checklist)
        checklistTap = checklist
    }

    func currentAvailableWidth() -> CGFloat {
        wiskRichEditorAvailableWidth(
            boundsWidth: bounds.width,
            horizontalInset: textContainerInset.left + textContainerInset.right,
            lineFragmentPadding: textContainer.lineFragmentPadding
        )
    }

    func refreshImageResizeChrome() {
        let storage = textStorage
        guard let id = imageResizeController.selectedAttachmentID,
              let index = wiskCharacterIndex(ofAttachmentID: id, in: storage),
              let rect = wiskGlyphRect(in: self, characterIndex: index) else {
            if imageResizeController.hasSelection, imageResizeController.isDragging == false {
                imageResizeController.clear()
            }
            return
        }
        imageResizeController.refresh(characterIndex: index, imageRect: rect)
    }

    func syncImageResizeChromeFromSelection() {
        guard !imageResizeController.isDragging else { return }
        let attachments = imageAttachmentsProvider()
        let storage = textStorage
        guard isEditable,
              let attachment = wiskImageAttachment(
                near: selectedRange,
                in: storage,
                attachments: attachments
              ),
              let index = wiskCharacterIndex(ofAttachmentID: attachment.id, in: storage),
              let rect = wiskGlyphRect(in: self, characterIndex: index),
              selectedRange.length == 1 else {
            imageResizeController.clear()
            return
        }
        imageResizeController.select(attachmentID: attachment.id, characterIndex: index, imageRect: rect)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        if gestureRecognizer === resizePan {
            return isEditable && imageResizeController.handle(at: point) != nil
        }
        if gestureRecognizer === imageTap {
            return isEditable && imageHit(at: point) != nil
        }
        if gestureRecognizer === checklistTap {
            return isEditable && checklistToggleIndex(at: point) != nil
        }
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let inherited = (super.keyCommands ?? []).filter {
            !($0.input?.lowercased() == "z" && $0.modifierFlags.contains(.command))
        }
        return inherited + [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentList)),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(outdentList)),
            UIKeyCommand(input: "z", modifierFlags: [.command], action: #selector(undoEditing)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoEditing)),
            UIKeyCommand(input: "f", modifierFlags: [.command], action: #selector(presentInNoteFind)),
            UIKeyCommand(input: "b", modifierFlags: [.command], action: #selector(applyBoldCommand)),
            UIKeyCommand(input: "i", modifierFlags: [.command], action: #selector(applyItalicCommand)),
            UIKeyCommand(input: "u", modifierFlags: [.command], action: #selector(applyUnderlineCommand)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelImageResize)),
        ]
    }

    @objc private func applyBoldCommand() {
        applyFormattingCommand(.bold)
    }

    @objc private func applyItalicCommand() {
        applyFormattingCommand(.italic)
    }

    @objc private func applyUnderlineCommand() {
        applyFormattingCommand(.underline)
    }

    private func applyFormattingCommand(_ action: WiskMarkdownFormattingAction) {
        guard isFirstResponder, isEditable else { return }
        onApplyFormatting?(WiskMarkdownFormattingRequest(action: action))
    }

    @objc private func indentList() {
        onIndent?(false)
    }

    @objc private func outdentList() {
        onIndent?(true)
    }

    @objc private func undoEditing() {
        guard isFirstResponder else { return }
        undoManager?.undo()
    }

    @objc private func redoEditing() {
        guard isFirstResponder else { return }
        undoManager?.redo()
    }

    @objc private func presentInNoteFind() {
        guard isFirstResponder else { return }
        findInteraction?.presentFindNavigator(showingReplace: true)
    }

    @objc private func applyEditorFormatting(_ notification: Notification) {
        guard let request = notification.object as? WiskMarkdownFormattingRequest,
              WiskActiveMarkdownEditor.canHandle(from: self, request: request) else { return }
        WiskActiveMarkdownEditor.claim(self)
        onApplyFormatting?(request)
    }

    @objc private func cancelImageResize() {
        if let restore = imageResizeController.cancelDrag() {
            wiskApplyLiveAttachmentWidth(
                in: textStorage,
                at: restore.characterIndex,
                width: restore.width,
                aspectRatio: restore.aspectRatio
            )
            wiskInvalidateAttachmentLayout(self, characterIndex: restore.characterIndex)
        }
        imageResizeController.clear()
    }

    @objc private func handleImageResizeTap(_ gesture: UITapGestureRecognizer) {
        guard let hit = imageHit(at: gesture.location(in: self)) else { return }
        if WiskAttachmentImageStore.shared.phase(for: hit.attachment) == .failed {
            WiskAttachmentImageStore.shared.retry(for: hit.attachment)
            return
        }
        selectedRange = NSRange(location: hit.index, length: 1)
        imageResizeController.select(attachmentID: hit.attachment.id, characterIndex: hit.index, imageRect: hit.rect)
    }

    @objc private func handleChecklistTap(_ gesture: UITapGestureRecognizer) {
        guard let index = checklistToggleIndex(at: gesture.location(in: self)) else { return }
        onToggleChecklist?(index)
    }

    private func checklistToggleIndex(at point: CGPoint) -> Int? {
        let storage = textStorage
        guard storage.length > 0 else { return nil }
        let rawIndex: Int
        if let position = closestPosition(to: point) {
            rawIndex = offset(from: beginningOfDocument, to: position)
        } else {
            return nil
        }
        let candidates = [rawIndex, max(rawIndex - 1, 0)]
        for index in candidates where WiskRichMarkdownDocument.isChecklistToggleLocation(index, in: storage) {
            return index
        }
        return nil
    }

    @objc private func handleImageResizePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let handle = imageResizeController.handle(at: point) else { return }
            imageResizeController.beginDrag(handle: handle, availableWidth: currentAvailableWidth())
        case .changed:
            guard let live = imageResizeController.updateDrag(currentX: point.x) else { return }
            wiskApplyLiveAttachmentWidth(
                in: textStorage,
                at: live.characterIndex,
                width: live.width,
                aspectRatio: live.aspectRatio
            )
            wiskInvalidateAttachmentLayout(self, characterIndex: live.characterIndex)
            refreshImageResizeChrome()
        case .ended:
            persistFinishedImageResize()
        case .cancelled, .failed:
            cancelImageResize()
        default:
            break
        }
    }

    private func persistFinishedImageResize() {
        guard let result = imageResizeController.finishDrag() else { return }
        onAttachmentDisplayWidthChange?(result.attachmentID, result.persistedWidth)
        refreshImageResizeChrome()
    }

    private func imageHit(at point: CGPoint) -> (attachment: NoteAttachment, index: Int, rect: CGRect)? {
        let storage = textStorage
        guard storage.length > 0 else { return nil }
        let rawIndex: Int
        if let position = closestPosition(to: point) {
            rawIndex = offset(from: beginningOfDocument, to: position)
        } else {
            rawIndex = 0
        }
        let attachments = imageAttachmentsProvider()
        let candidates = [rawIndex, max(rawIndex - 1, 0)]
        for index in candidates {
            guard let attachment = wiskImageAttachment(at: index, in: storage, attachments: attachments),
                  let rect = wiskGlyphRect(in: self, characterIndex: index),
                  rect.insetBy(dx: -4, dy: -4).contains(point) else {
                continue
            }
            return (attachment, index, rect)
        }
        return nil
    }
}

private struct PlatformRichMarkdownTextView: UIViewRepresentable {
    @Binding var markdownText: String
    @Binding var selectedMarkdownRange: Range<String.Index>?

    let attachments: [NoteAttachment]
    let fontSelection: WiskEditorFontSelection
    let baseFontSize: CGFloat
    let isEditable: Bool
    var minHeight: CGFloat? = nil
    let showSourceMarkers: Bool
    let searchHighlightText: String
    let contentGutter: CGFloat
    let wikiLinkTitles: [String]
    let jumpToSourceRange: NSRange?
    var foldedSourceLocations: Binding<Set<Int>>
    let documentIdentity: UUID?
    let accessibilityIdentifier: String
    let onFocusChange: ((Bool) -> Void)?
    let onOpenWikiLink: ((String) -> Void)?
    let onJumpHandled: (() -> Void)?
    let onWikiQueryChanged: ((String?) -> Void)?
    let onWikiCaretOffset: ((CGSize) -> Void)?
    let onMarkerCaret: ((Int?) -> Void)?
    let onAttachmentDisplayWidthChange: (UUID, Double?) -> Void
    let onAttachmentAction: (UUID, WiskAttachmentEditorAction) -> Void
    let onPasteImage: (() -> Void)?
    let bodyFocusRequestID: UUID?
    let onBodyFocusHandled: (() -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let textView = WiskMarkdownUITextView()
        textView.onIndent = { [weak coordinator = context.coordinator, weak textView] outdent in
            guard let textView else { return }
            coordinator?.applyIndent(outdent: outdent, textView: textView)
        }
        textView.onLayout = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.refreshLayoutIfNeeded(in: textView)
        }
        textView.delegate = context.coordinator
        context.coordinator.attachedTextView = textView
        textView.backgroundColor = .clear
        // Full-viewport editor: the text view grows with its content inside
        // the outer SwiftUI ScrollView instead of scrolling internally (a
        // scroll-enabled UITextView reports no intrinsic content size and
        // collapses to the minHeight floor, scrolling in place).
        textView.isScrollEnabled = false
        // Deterministic sentence capitalization is applied in the typing
        // path (shouldChangeTextIn / onInsertText). Stock UIKit
        // autocapitalization re-engages shift on every programmatic
        // textStorage edit — every keystroke here is one.
        textView.autocapitalizationType = .none
        // Plain typing routes through UIKit's native input pipeline (see
        // insertText / shouldChangeTextIn), so re-enable the intelligence
        // UIKit gates on these traits: spell-check underlines, QuickType
        // suggestions, and autocorrection. Smart punctuation stays off —
        // typographic quotes and dashes would corrupt markdown source.
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.isFindInteractionEnabled = true
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.typingAttributes = WiskRichMarkdownDocument.typingAttributes(
            headingLevel: nil,
            fontSelection: fontSelection,
            baseFontSize: baseFontSize
        )
        textView.configureImageResize()
        textView.onToggleChecklist = { [weak coordinator = context.coordinator, weak textView] index in
            guard let textView else { return }
            coordinator?.toggleChecklist(atVisibleLocation: index, textView: textView)
        }
        textView.onAttachmentDisplayWidthChange = { [weak coordinator = context.coordinator] id, width in
            coordinator?.parent.onAttachmentDisplayWidthChange(id, width)
        }
        textView.imageAttachmentsProvider = { [weak coordinator = context.coordinator] in
            coordinator?.parent.attachments ?? []
        }
        textView.onApplyFormatting = { [weak coordinator = context.coordinator, weak textView] request in
            guard let textView else { return }
            coordinator?.applyFormatting(request, textView: textView)
        }
        textView.markCaretUserInitiated = { [weak coordinator = context.coordinator] in
            coordinator?.caretChangeIsUserInitiated = true
        }
        textView.onInsertText = { [weak coordinator = context.coordinator, weak textView] text in
            guard let textView else { return }
            let replacement = coordinator?.sentenceStartCapitalizedReplacement(text, textView: textView) ?? text
            _ = coordinator?.applySourceEdit(
                visibleRange: textView.selectedRange,
                replacement: replacement,
                textView: textView
            )
        }
        textView.onDeleteBackward = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            let selected = textView.selectedRange
            if selected.length > 0 {
                _ = coordinator?.applySourceEdit(
                    visibleRange: selected,
                    replacement: "",
                    textView: textView
                )
            } else if selected.location > 0 {
                _ = coordinator?.applySourceEdit(
                    visibleRange: NSRange(location: selected.location - 1, length: 1),
                    replacement: "",
                    textView: textView
                )
            }
        }
        textView.commitCaret = { [weak coordinator = context.coordinator, weak textView] range in
            guard let textView else { return }
            coordinator?.rememberVisibleRange(range, in: textView, isUserInitiated: true)
        }
        textView.observeEditorCommands()
        context.coordinator.lastDocumentIdentity = documentIdentity
        context.coordinator.lastMarkdownText = markdownText
        if markdownText.isEmpty == false || documentIdentity == nil {
            context.coordinator.openDocument(
                markdown: markdownText,
                identity: documentIdentity,
                in: textView,
                isIdentityChange: false
            )
        }
        return textView
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.saveSession(from: textView)
        coordinator.cancelDeferredRestyle()
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.accessibilityIdentifier = accessibilityIdentifier
        context.coordinator.handleBodyFocusRequestIfNeeded(in: textView)
        if context.coordinator.isApplyingSourceEdit {
            return
        }
        let identityChanged = documentIdentity != nil
            && context.coordinator.lastDocumentIdentity != documentIdentity
        let isDocumentReplacement = WiskEditorOpenPath.isDocumentReplacement(
            previousMarkdown: context.coordinator.lastMarkdownText,
            nextMarkdown: markdownText,
            identityChanged: identityChanged
        )
        if isDocumentReplacement {
            context.coordinator.openDocument(
                markdown: markdownText,
                identity: documentIdentity,
                in: textView,
                isIdentityChange: identityChanged
            )
        } else if context.coordinator.lastMarkdownText != markdownText
            || context.coordinator.lastAttachmentFingerprint != wiskAttachmentRenderFingerprint(attachments)
            || context.coordinator.lastShowSourceMarkers != showSourceMarkers
            || context.coordinator.lastFoldedLocations != foldedSourceLocations.wrappedValue {
            context.coordinator.cancelDeferredRestyle()
            context.coordinator.applyMarkdownText(markdownText, to: textView)
        } else if context.coordinator.lastSearchHighlightText != searchHighlightText {
            context.coordinator.restyleSearchHighlights(in: textView, shouldScroll: true)
        } else {
            context.coordinator.refreshLayoutIfNeeded(in: textView)
        }
        context.coordinator.lastDocumentIdentity = documentIdentity
        // Re-measure after programmatic updates (markdown re-apply, attachment
        // resolution) now that the text view grows with content instead of
        // scrolling internally.
        textView.invalidateIntrinsicContentSize()
        context.coordinator.handleJumpIfNeeded(in: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let fittingHeight = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let floorHeight = minHeight ?? 0
        if let proposedHeight = proposal.height, proposedHeight.isFinite {
            // Tight/bounded proposal (e.g. structured-section editors): stay
            // bounded instead of growing past the container.
            return CGSize(width: width, height: max(floorHeight, min(proposedHeight, fittingHeight)))
        }
        // Unbounded height (the note editor inside the outer ScrollView):
        // report the full content height so the outer ScrollView scrolls the
        // whole viewport.
        return CGSize(width: width, height: max(floorHeight, fittingHeight))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlatformRichMarkdownTextView
        var isApplyingProgrammaticUpdate = false
        var isApplyingSourceEdit = false
        var lastMarkdownText = ""
        var lastAttachmentFingerprint = ""
        var lastShowSourceMarkers = false
        var lastSearchHighlightText = ""
        var lastScrolledSearchText = ""
        var lastScrolledSearchIdentity: UUID?
        var lastFoldedLocations = Set<Int>()
        var lastAvailableWidth: CGFloat = 0
        /// A native UIKit change (`shouldChangeTextIn` returned true) waiting
        /// for its `textViewDidChange` commit. `baseTextLength` is
        /// `textStorage.length` captured before UIKit applied the change: the
        /// commit patches a text view that already shows the native
        /// characters (unlike the engine path, whose view still shows the old
        /// render), so the incremental line patch needs the native delta to
        /// locate the new line's actual span.
        struct PendingNativeEdit {
            var editedRange: NSRange
            var baseTextLength: Int
        }
        var pendingEditedRange: PendingNativeEdit?
        /// Set while a native marked-text commit proceeds with undo
        /// registration disabled, so UITextView does not record its own undo
        /// entry on top of the coordinator's source-level record.
        private var nativeUndoDisabledForMarkedCommit = false
        var lastFocusedVisibleRange = NSRange(location: 0, length: 0)
        var caretChangeIsUserInitiated = false
        var cachedParsedSource: String?
        var cachedDocument: WiskMarkdownDocument?
        var lastDocumentIdentity: UUID?
        var lastSourceCaretUTF16: Int?
        private var restyleTask: Task<Void, Never>?
        private var fillInStyleTask: Task<Void, Never>?
        private var restyleGeneration = 0
        private var pendingCaretUTF16: Int?
        private var pendingScrollFraction: CGFloat?
        var lastConsumedBodyFocusRequestID: UUID?
        weak var attachedTextView: UITextView?
        private var keyboardFrame: CGRect = .zero
        private var keyboardFrameObserver: NSObjectProtocol?

        init(parent: PlatformRichMarkdownTextView) {
            self.parent = parent
            super.init()
            observeKeyboardFrameChanges()
        }

        /// Consumes a `bodyFocusRequestID` exactly once and moves keyboard
        /// focus into the body text view. Used by the title field's Return
        /// handoff on iOS (macOS has its own coordinator implementation).
        func handleBodyFocusRequestIfNeeded(in textView: UITextView) {
            guard let requestID = parent.bodyFocusRequestID else { return }
            guard lastConsumedBodyFocusRequestID != requestID else { return }
            lastConsumedBodyFocusRequestID = requestID
            guard parent.isEditable else {
                parent.onBodyFocusHandled?()
                return
            }
            let identity = parent.documentIdentity
            // Short defer lets SwiftUI settle the title field's resignation so
            // the keyboard handoff does not race the focus system.
            Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, let textView else { return }
                guard self.parent.documentIdentity == identity else { return }
                guard self.lastConsumedBodyFocusRequestID == requestID else { return }
                textView.becomeFirstResponder()
                // Landing the caret at the body start matches Apple Notes /
                // Bear: the returned note's first line is what you usually
                // edit next, and an existing long note would otherwise jump
                // the viewport to the very bottom.
                let startLocation = 0
                textView.selectedRange = NSRange(location: startLocation, length: 0)
                self.parent.onBodyFocusHandled?()
            }
        }

        deinit {
            restyleTask?.cancel()
            fillInStyleTask?.cancel()
            if let keyboardFrameObserver {
                NotificationCenter.default.removeObserver(keyboardFrameObserver)
            }
        }

        func prepareForDocumentIdentityChange(in textView: UITextView) {
            saveSession(from: textView)
            cancelDeferredRestyle()
            textView.undoManager?.removeAllActions()
            lastFocusedVisibleRange = NSRange(location: 0, length: 0)
            pendingEditedRange = nil
            caretChangeIsUserInitiated = false
            cachedParsedSource = nil
            cachedDocument = nil
            parent.selectedMarkdownRange = nil
            rememberSourceCaret(nil)
        }

        func shouldScrollToFirstSearchMatch() -> Bool {
            lastScrolledSearchText != parent.searchHighlightText
                || lastScrolledSearchIdentity != (lastDocumentIdentity ?? parent.documentIdentity)
        }

        func restyleSearchHighlights(in textView: UITextView, shouldScroll: Bool) {
            let wasApplying = isApplyingProgrammaticUpdate
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = wasApplying }
            let storage = textView.textStorage
            storage.beginEditing()
            let firstMatch = WiskRichMarkdownDocument.applySearchHighlights(
                to: storage,
                searchText: parent.searchHighlightText
            )
            storage.endEditing()
            lastSearchHighlightText = parent.searchHighlightText
            if shouldScroll {
                lastScrolledSearchIdentity = lastDocumentIdentity ?? parent.documentIdentity
                lastScrolledSearchText = parent.searchHighlightText
                if let firstMatch {
                    scrollRangeIntoHostVisibility(firstMatch, in: textView)
                }
            }
        }

        func openDocument(
            markdown: String,
            identity: UUID?,
            in textView: UITextView,
            isIdentityChange: Bool
        ) {
            guard let identity else {
                applyMarkdownText(markdown, to: textView, eager: false)
                return
            }
            let switchState = WiskEditorSignposts.signposter.beginInterval("Switch")
            let started = ContinuousClock.now
            let utf16Count = (markdown as NSString).length
            var cacheResult = "miss"
            var loggedDelay: UInt64 = 0
            var loggedSwitched = false
            defer {
                WiskEditorSignposts.signposter.endInterval("Switch", switchState)
                let elapsedMs = (ContinuousClock.now - started) / Duration.milliseconds(1)
                WiskEditorSignposts.log.info(
                    "Switch \(cacheResult, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) utf16=\(utf16Count, privacy: .public) delayNs=\(loggedDelay, privacy: .public) switched=\(loggedSwitched, privacy: .public) id=\(identity.uuidString, privacy: .public)"
                )
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let identitySwitched = identity != WiskEditorSwitchCadence.lastOpenedID
            WiskEditorSwitchCadence.lastOpenedID = identity
            let delay: UInt64
            if identitySwitched {
                delay = WiskEditorRestylePolicy.delayNanoseconds(
                    sincePreviousIdentityChange: WiskEditorSwitchCadence.lastIdentityChangeUptime,
                    now: now
                )
                WiskEditorSwitchCadence.lastIdentityChangeUptime = now
            } else {
                delay = 0
            }
            loggedDelay = delay
            loggedSwitched = identitySwitched
            if isIdentityChange {
                prepareForDocumentIdentityChange(in: textView)
            }

            lastDocumentIdentity = identity

            if let snapshot = WiskEditorSessionCache.shared.snapshot(id: identity),
               snapshot.source == markdown,
               snapshot.showSourceMarkers == parent.showSourceMarkers {
                parent.foldedSourceLocations.wrappedValue = snapshot.foldedLocations
                lastFoldedLocations = snapshot.foldedLocations
                pendingCaretUTF16 = snapshot.caretUTF16
                pendingScrollFraction = snapshot.scrollFraction
                cachedParsedSource = snapshot.source
                cachedDocument = snapshot.document
                if let styled = snapshot.styled {
                    applyCachedStyled(styled, markdown: markdown, document: snapshot.document, to: textView)
                    cacheResult = "hit"
                    WiskEditorSignposts.cacheHit(utf16Count: utf16Count)
                    return
                }
            } else if isIdentityChange {
                pendingCaretUTF16 = 0
                pendingScrollFraction = 0
            }

            WiskEditorSignposts.cacheMiss(utf16Count: utf16Count, delayNanoseconds: delay)
            let paintPlainFirst = WiskEditorOpenPath.shouldPaintPlainFirst(utf16Count: utf16Count) || delay > 0
            if paintPlainFirst {
                applyPlainMarkdownText(markdown, to: textView)
                scheduleDeferredRestyle(
                    of: markdown,
                    identity: identity,
                    in: textView,
                    delayNanoseconds: delay
                )
            } else {
                applyMarkdownText(markdown, to: textView, eager: false)
            }
        }

        func saveSession(from textView: UITextView) {
            guard let id = lastDocumentIdentity else { return }
            let source = lastMarkdownText
            let existingSource = WiskEditorSessionCache.shared.snapshot(id: id)?.source
            guard WiskEditorOpenPath.shouldReplaceCachedSession(
                withSource: source,
                existingSource: existingSource
            ) else { return }
            let document: WiskMarkdownDocument
            if let cachedDocument {
                document = cachedDocument
            } else if let cached = WiskEditorSessionCache.shared.snapshot(id: id), cached.source == source {
                document = cached.document
            } else {
                return
            }
            let styled: NSAttributedString?
            let storage = textView.textStorage
            if storage.length > 0, storage.length <= WiskEditorPerformance.styledCacheMaxUTF16 {
                styled = WiskRichMarkdownDocument.copyWithoutSearchHighlights(
                    NSAttributedString(attributedString: storage)
                )
            } else {
                styled = nil
            }
            WiskEditorSessionCache.shared.store(
                id: id,
                snapshot: WiskEditorSessionSnapshot(
                    source: source,
                    document: document,
                    caretUTF16: textView.selectedRange.location,
                    scrollFraction: scrollFraction(of: textView),
                    foldedLocations: lastFoldedLocations,
                    showSourceMarkers: lastShowSourceMarkers,
                    styled: styled
                )
            )
        }

        func cancelDeferredRestyle() {
            restyleGeneration += 1
            restyleTask?.cancel()
            restyleTask = nil
            fillInStyleTask?.cancel()
            fillInStyleTask = nil
        }

        func scheduleDeferredRestyle(
            of markdown: String,
            identity: UUID?,
            in textView: UITextView,
            delayNanoseconds: UInt64 = WiskEditorPerformance.restyleDebounceNanoseconds
        ) {
            restyleGeneration += 1
            let generation = restyleGeneration
            restyleTask?.cancel()
            fillInStyleTask?.cancel()
            let showMarkers = parent.showSourceMarkers
            restyleTask = Task { @MainActor [weak self, weak textView] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard let self, let textView else { return }
                guard !Task.isCancelled, self.restyleGeneration == generation else { return }
                guard self.lastDocumentIdentity == identity else { return }
                guard self.lastMarkdownText == markdown else { return }

                if let identity,
                   let styled = WiskEditorSessionCache.shared.styled(
                    id: identity,
                    source: markdown,
                    showSourceMarkers: showMarkers,
                    foldedLocations: []
                   ),
                   let document = WiskEditorSessionCache.shared.document(
                    id: identity,
                    source: markdown,
                    showSourceMarkers: showMarkers,
                    foldedLocations: []
                   ) {
                    self.cachedParsedSource = markdown
                    self.cachedDocument = document
                    self.applyCachedStyled(styled, markdown: markdown, document: document, to: textView)
                    return
                }

                let document: WiskMarkdownDocument
                if let identity,
                   let cached = WiskEditorSessionCache.shared.document(
                    id: identity,
                    source: markdown,
                    showSourceMarkers: showMarkers,
                    foldedLocations: []
                   ) {
                    document = cached
                } else {
                    document = await Task.detached(priority: .userInitiated) {
                        WiskMarkdownDocumentEngine.parse(markdown)
                    }.value
                }
                guard !Task.isCancelled, self.restyleGeneration == generation else { return }
                guard self.lastDocumentIdentity == identity, self.lastMarkdownText == markdown else { return }
                self.cachedParsedSource = markdown
                self.cachedDocument = document
                self.applyMarkdownText(markdown, to: textView, eager: true)
            }
        }

        func applyPlainMarkdownText(_ markdown: String, to textView: UITextView) {
            isApplyingProgrammaticUpdate = true
            let attributes = WiskRichMarkdownDocument.typingAttributes(
                headingLevel: nil,
                fontSelection: parent.fontSelection,
                baseFontSize: parent.baseFontSize
            )
            WiskEditorSignposts.interval("PlainText") {
                textView.attributedText = NSAttributedString(string: markdown, attributes: attributes)
            }
            textView.typingAttributes = attributes
            lastMarkdownText = markdown
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = parent.foldedSourceLocations.wrappedValue
            isApplyingProgrammaticUpdate = false
            restyleSearchHighlights(in: textView, shouldScroll: false)
        }

        func applyCachedStyled(
            _ styled: NSAttributedString,
            markdown: String,
            document: WiskMarkdownDocument,
            to textView: UITextView
        ) {
            isApplyingProgrammaticUpdate = true
            WiskEditorSignposts.interval("SetAttributedString") {
                textView.attributedText = styled
            }
            textView.typingAttributes = WiskRichMarkdownDocument.typingAttributes(
                headingLevel: nil,
                fontSelection: parent.fontSelection,
                baseFontSize: parent.baseFontSize
            )
            let caret = pendingCaretUTF16 ?? 0
            textView.selectedRange = NSRange(location: min(caret, styled.length), length: 0)
            restorePendingScroll(in: textView)
            lastMarkdownText = markdown
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = parent.foldedSourceLocations.wrappedValue
            cachedParsedSource = markdown
            cachedDocument = document
            isApplyingProgrammaticUpdate = false
            (textView as? WiskMarkdownUITextView)?.refreshImageResizeChrome()
            publishWikiCaret(in: textView)
            restyleSearchHighlights(in: textView, shouldScroll: shouldScrollToFirstSearchMatch())
        }

        func scheduleFillInStyle(of markdown: String, identity: UUID?, in textView: UITextView) {
            fillInStyleTask?.cancel()
            let generation = restyleGeneration
            fillInStyleTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView else { return }
                guard !Task.isCancelled, self.restyleGeneration == generation else { return }
                guard self.lastDocumentIdentity == identity, self.lastMarkdownText == markdown else { return }
                self.applyMarkdownText(markdown, to: textView, eager: false)
            }
        }

        func storeStyledSession(
            id: UUID,
            markdown: String,
            document: WiskMarkdownDocument,
            in textView: UITextView
        ) {
            let styled: NSAttributedString?
            let storage = textView.textStorage
            if storage.length > 0, storage.length <= WiskEditorPerformance.styledCacheMaxUTF16 {
                styled = WiskRichMarkdownDocument.copyWithoutSearchHighlights(
                    NSAttributedString(attributedString: storage)
                )
            } else {
                styled = nil
            }
            WiskEditorSessionCache.shared.store(
                id: id,
                snapshot: WiskEditorSessionSnapshot(
                    source: markdown,
                    document: document,
                    caretUTF16: textView.selectedRange.location,
                    scrollFraction: scrollFraction(of: textView),
                    foldedLocations: lastFoldedLocations,
                    showSourceMarkers: lastShowSourceMarkers,
                    styled: styled
                )
            )
        }

        func scrollFraction(of textView: UITextView) -> CGFloat {
            let maxScroll = max(textView.contentSize.height - textView.bounds.height, 1)
            return min(max(textView.contentOffset.y / maxScroll, 0), 1)
        }

        func restorePendingScroll(in textView: UITextView) {
            guard let fraction = pendingScrollFraction else {
                pendingScrollFraction = nil
                pendingCaretUTF16 = nil
                return
            }
            textView.layoutIfNeeded()
            let maxScroll = max(textView.contentSize.height - textView.bounds.height, 0)
            textView.setContentOffset(CGPoint(x: 0, y: fraction * maxScroll), animated: false)
            pendingScrollFraction = nil
            pendingCaretUTF16 = nil
        }

        func parsedDocument(for source: String, dirtySourceRange: NSRange? = nil) -> WiskMarkdownDocument {
            WiskMarkdownParseCache.document(
                for: source,
                cachedSource: &cachedParsedSource,
                cachedDocument: &cachedDocument,
                dirtySourceRange: dirtySourceRange
            )
        }

        @discardableResult
        func rememberVisibleRange(_ range: NSRange, in textView: UITextView, isUserInitiated: Bool) -> Bool {
            guard range.location != NSNotFound else { return false }
            let textLength = textView.attributedText.length
            if WiskRichMarkdownDocument.shouldPreserveRememberedVisibleRange(
                incoming: range,
                remembered: lastFocusedVisibleRange,
                textLength: textLength,
                isUserInitiated: isUserInitiated
            ) {
                return false
            }
            lastFocusedVisibleRange = range
            WiskActiveMarkdownEditor.claim(textView)
            return true
        }

        func applyMarkdownText(_ markdown: String, to textView: UITextView, eager: Bool = false) {
            isApplyingProgrammaticUpdate = true
            let selectedRange = textView.selectedRange
            let availableWidth = availableWidth(for: textView)
            lastAvailableWidth = availableWidth
            let document = parsedDocument(for: markdown)
            let folds = parent.foldedSourceLocations.wrappedValue
            let caretHint = pendingCaretUTF16 ?? selectedRange.location
            let sourceLength = (markdown as NSString).length
            let eagerRange: NSRange?
            if eager, sourceLength > WiskEditorPerformance.eagerStyleUTF16Window {
                let window = WiskEditorPerformance.eagerStyleUTF16Window
                let start = max(caretHint - window / 2, 0)
                eagerRange = NSRange(location: start, length: min(window, sourceLength - start))
            } else {
                eagerRange = nil
            }
            let attributed = WiskEditorSignposts.interval("AttributedString") {
                WiskRichMarkdownDocument.attributedString(
                    from: markdown,
                    attachments: parent.attachments,
                    fontSelection: parent.fontSelection,
                    baseFontSize: parent.baseFontSize,
                    availableWidth: availableWidth,
                    showSourceMarkers: parent.showSourceMarkers,
                    document: document,
                    foldedLocations: folds,
                    eagerStyleUTF16Range: eagerRange
                )
            }
            WiskEditorSignposts.interval("SetAttributedString") {
                textView.attributedText = attributed
            }
            textView.typingAttributes = WiskRichMarkdownDocument.typingAttributes(
                headingLevel: nil,
                fontSelection: parent.fontSelection,
                baseFontSize: parent.baseFontSize
            )
            textView.selectedRange = WiskRichMarkdownDocument.visibleSelection(
                forMarkdownRange: parent.selectedMarkdownRange,
                in: markdown,
                fallback: NSRange(location: min(max(caretHint, 0), attributed.length), length: 0),
                textLength: textView.attributedText.length,
                showSourceMarkers: parent.showSourceMarkers,
                document: document,
                foldedLocations: folds
            )
            restorePendingScroll(in: textView)
            lastMarkdownText = markdown
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = folds
            isApplyingProgrammaticUpdate = false
            (textView as? WiskMarkdownUITextView)?.refreshImageResizeChrome()
            publishWikiCaret(in: textView)
            if eagerRange != nil {
                scheduleFillInStyle(of: markdown, identity: lastDocumentIdentity, in: textView)
            } else if let identity = lastDocumentIdentity ?? parent.documentIdentity {
                storeStyledSession(id: identity, markdown: markdown, document: document, in: textView)
            }
            restyleSearchHighlights(in: textView, shouldScroll: shouldScrollToFirstSearchMatch())
        }

        func handleJumpIfNeeded(in textView: UITextView) {
            guard let target = parent.jumpToSourceRange else { return }
            let document = parsedDocument(for: parent.markdownText)
            let unfolded = WiskMarkdownFolding.unfoldLocations(
                intersecting: target,
                in: document,
                folds: parent.foldedSourceLocations.wrappedValue
            )
            if unfolded != parent.foldedSourceLocations.wrappedValue {
                parent.foldedSourceLocations.wrappedValue = unfolded
            }
            let folds = parent.foldedSourceLocations.wrappedValue
            let visible: NSRange
            if parent.showSourceMarkers {
                visible = target
            } else if let range = Range(target, in: parent.markdownText),
                      let mapped = WiskRichMarkdownDocument.visibleRange(
                        forMarkdownRange: range,
                        in: parent.markdownText,
                        document: document,
                        foldedLocations: folds
                      ) {
                visible = mapped
            } else {
                visible = NSRange(location: 0, length: 0)
            }
            let length = textView.attributedText.length
            let location = min(max(visible.location, 0), length)
            let selected = NSRange(location: location, length: min(visible.length, max(length - location, 0)))
            textView.selectedRange = selected
            scrollRangeIntoHostVisibility(selected, in: textView)
            rememberVisibleRange(selected, in: textView, isUserInitiated: true)
            parent.onJumpHandled?()
        }

        func applySourceEdit(
            visibleRange: NSRange,
            replacement: String,
            textView: UITextView,
            nativeTextViewDelta: Int = 0
        ) -> Bool {
            let document = parsedDocument(for: parent.markdownText)
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: visibleRange,
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: document,
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else { return false }
            unfoldIfNeeded(intersecting: sourceRange)
            let previous = parent.markdownText
            let previousSelection = parent.selectedMarkdownRange
            let mutation: WiskMarkdownMutation?
            if replacement == "\n" {
                mutation = WiskMarkdownDocumentEngine.applyReturn(in: parent.markdownText, sourceRange: sourceRange)
            } else {
                mutation = WiskMarkdownDocumentEngine.replaceSourceRange(
                    in: parent.markdownText,
                    sourceRange: sourceRange,
                    with: replacement
                )
            }
            guard let mutation else { return false }
            registerSourceUndo(previous: previous, previousSelection: previousSelection, textView: textView)
            lastMarkdownText = mutation.source
            isApplyingSourceEdit = true
            defer { isApplyingSourceEdit = false }
            parent.markdownText = mutation.source
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            if !applyIncrementalMutation(
                previous: previous,
                mutation: mutation,
                editedSourceRange: sourceRange,
                replacement: replacement,
                textView: textView,
                nativeTextViewDelta: nativeTextViewDelta
            ) {
                applyMarkdownText(mutation.source, to: textView)
            }
            rememberVisibleRange(textView.selectedRange, in: textView, isUserInitiated: true)
            publishWikiQuery()
            return true
        }

        func applyIncrementalMutation(
            previous: String,
            mutation: WiskMarkdownMutation,
            editedSourceRange: NSRange,
            replacement: String,
            textView: UITextView,
            nativeTextViewDelta: Int = 0
        ) -> Bool {
            guard replacement != "\n",
                  parent.foldedSourceLocations.wrappedValue.isEmpty,
                  let edit = WiskRichMarkdownDocument.incrementalLineEdit(
                    previousMarkdown: previous,
                    mutation: mutation,
                    editedSourceRange: editedSourceRange,
                    replacement: replacement,
                    attachments: parent.attachments,
                    fontSelection: parent.fontSelection,
                    baseFontSize: parent.baseFontSize,
                    availableWidth: availableWidth(for: textView),
                    showSourceMarkers: parent.showSourceMarkers,
                    foldedLocations: parent.foldedSourceLocations.wrappedValue,
                    previousDocument: cachedDocument
                  )
            else {
                return false
            }

            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }
            // When the edit arrived through UIKit's native pipeline the text
            // view already contains the new line's characters: the patch must
            // replace the new line's span (old range + native delta), not the
            // old render's, or the native characters survive as a duplicated
            // tail. The engine path passes delta 0, which resolves to
            // edit.visibleRange — unchanged behavior.
            let patchRange: NSRange? = nativeTextViewDelta == 0
                ? nil
                : NSRange(
                    location: edit.visibleRange.location,
                    length: edit.visibleRange.length + nativeTextViewDelta
                )
            guard WiskRichMarkdownDocument.applyIncrementalLineEdit(
                edit,
                to: textView.textStorage,
                replacingRange: patchRange
            ) else {
                return false
            }

            cachedDocument = parsedDocument(for: mutation.source, dirtySourceRange: editedSourceRange)
            lastMarkdownText = mutation.source
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = parent.foldedSourceLocations.wrappedValue

            let restoredSelection = WiskRichMarkdownDocument.visibleSelection(
                forMarkdownRange: parent.selectedMarkdownRange,
                in: mutation.source,
                fallback: NSRange(location: edit.visibleRange.location + edit.attributedLine.length, length: 0),
                textLength: textView.textStorage.length,
                showSourceMarkers: parent.showSourceMarkers,
                document: cachedDocument,
                foldedLocations: lastFoldedLocations
            )
            textView.selectedRange = restoredSelection
            restyleSearchHighlights(in: textView, shouldScroll: false)
            return true
        }

        func registerSourceUndo(previous: String, previousSelection: Range<String.Index>?, textView: UITextView) {
            textView.undoManager?.registerUndo(withTarget: self) { coordinator in
                let current = coordinator.parent.markdownText
                let currentSelection = coordinator.parent.selectedMarkdownRange
                coordinator.parent.markdownText = previous
                coordinator.parent.selectedMarkdownRange = previousSelection
                coordinator.applyMarkdownText(previous, to: textView)
                coordinator.registerSourceUndo(previous: current, previousSelection: currentSelection, textView: textView)
            }
        }

        func publishWikiQuery() {
            let length = (parent.markdownText as NSString).length
            guard let caret = lastSourceCaretUTF16, caret >= 0, caret <= length else {
                parent.onWikiQueryChanged?(nil)
                return
            }
            parent.onWikiQueryChanged?(WiskMarkdownDocumentEngine.wikiLinkPartial(in: parent.markdownText, sourceCaret: caret))
        }

        func rememberSourceCaret(_ location: Int?) {
            lastSourceCaretUTF16 = location
            parent.onMarkerCaret?(location)
        }

        func publishWikiCaret(in textView: UITextView) {
            let range = textView.selectedRange
            guard range.location != NSNotFound else {
                parent.onWikiCaretOffset?(.zero)
                return
            }
            let caretRect: CGRect
            if let position = textView.position(from: textView.beginningOfDocument, offset: range.location) {
                caretRect = textView.caretRect(for: position)
            } else {
                caretRect = textView.caretRect(for: textView.endOfDocument)
            }
            parent.onWikiCaretOffset?(
                CGSize(
                    width: max(caretRect.minX - textView.contentOffset.x, 8),
                    height: max(caretRect.maxY - textView.contentOffset.y, 8)
                )
            )
        }

        func unfoldIfNeeded(intersecting sourceRange: NSRange) {
            let document = parsedDocument(for: parent.markdownText)
            let unfolded = WiskMarkdownFolding.unfoldLocations(
                intersecting: sourceRange,
                in: document,
                folds: parent.foldedSourceLocations.wrappedValue
            )
            if unfolded != parent.foldedSourceLocations.wrappedValue {
                parent.foldedSourceLocations.wrappedValue = unfolded
            }
        }

        func applyTableMutation(_ mutation: WiskMarkdownMutation, textView: UITextView) {
            registerSourceUndo(
                previous: parent.markdownText,
                previousSelection: parent.selectedMarkdownRange,
                textView: textView
            )
            parent.markdownText = mutation.source
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            applyMarkdownText(mutation.source, to: textView)
            rememberVisibleRange(textView.selectedRange, in: textView, isUserInitiated: true)
        }

        func toggleChecklist(atVisibleLocation location: Int, textView: UITextView) {
            guard parent.isEditable else { return }
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: NSRange(location: location, length: 0),
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: parsedDocument(for: parent.markdownText),
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else { return }
            guard let mutation = WiskMarkdownDocumentEngine.toggleChecklist(
                in: parent.markdownText,
                sourceLocation: sourceRange.location
            ) else { return }
            applyTableMutation(mutation, textView: textView)
        }

        func applyFormatting(_ request: WiskMarkdownFormattingRequest, textView: UITextView) {
            guard let mutation = WiskRichMarkdownDocument.applyFormatting(
                request.action,
                to: parent.markdownText,
                visibleRange: lastFocusedVisibleRange,
                visibleText: textView.attributedText.string
            ) else { return }
            request.handled = true
            registerSourceUndo(
                previous: parent.markdownText,
                previousSelection: parent.selectedMarkdownRange,
                textView: textView
            )
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            parent.markdownText = mutation.source
            applyMarkdownText(mutation.source, to: textView)
            rememberVisibleRange(textView.selectedRange, in: textView, isUserInitiated: true)
        }

        func refreshLayoutIfNeeded(in textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            let width = availableWidth(for: textView)
            guard abs(width - lastAvailableWidth) > 2 else { return }
            lastAvailableWidth = width
            let hasFitImages = parent.attachments.contains {
                $0.isImage && $0.displayWidth == nil && $0.isPreviewVisible
            }
            guard hasFitImages else { return }
            applyMarkdownText(parent.markdownText, to: textView)
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            var extras: [UIMenuElement] = []
            if parent.isEditable,
               let attachment = wiskEditorAttachment(
                near: range,
                in: textView.attributedText,
                attachments: parent.attachments
               ) {
                if attachment.isImage {
                    let sizeActions = WiskAttachmentImageSizeOption.allCases.map { option in
                        UIAction(
                            title: option.title,
                            state: option.isSelected(for: attachment) ? .on : .off
                        ) { [parent] _ in
                            parent.onAttachmentAction(attachment.id, .displayWidth(option.displayWidth(for: attachment)))
                        }
                    }
                    extras.append(UIMenu(title: "Image Size", children: sizeActions))
                    extras.append(UIAction(title: "Crop") { [parent] _ in
                        parent.onAttachmentAction(attachment.id, .crop)
                    })
                }
                let alignmentActions: [(String, NoteAttachmentAlignment)] = [
                    ("Align Leading", .leading),
                    ("Align Center", .center),
                    ("Align Trailing", .trailing),
                ]
                extras.append(
                    UIMenu(
                        title: "Alignment",
                        children: alignmentActions.map { title, alignment in
                            UIAction(
                                title: title,
                                state: attachment.alignment == alignment ? .on : .off
                            ) { [parent] _ in
                                parent.onAttachmentAction(attachment.id, .alignment(alignment))
                            }
                        }
                    )
                )
                extras.append(UIAction(title: "Edit Name and Alt Text") { [parent] _ in
                    parent.onAttachmentAction(attachment.id, .editDetails)
                })
                extras.append(
                    UIAction(title: attachment.isPreviewVisible ? "Hide Preview" : "Show Preview") { [parent] _ in
                        parent.onAttachmentAction(attachment.id, .previewVisible(!attachment.isPreviewVisible))
                    }
                )
            } else if parent.isEditable {
                extras.append(contentsOf: sourceContextActions(range: range, textView: textView))
            }
            return UIMenu(children: extras + suggestedActions)
        }

        func sourceContextActions(range: NSRange, textView: UITextView) -> [UIMenuElement] {
            let document = parsedDocument(for: parent.markdownText)
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: range,
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: document,
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else {
                return []
            }
            var actions: [UIMenuElement] = []
            if document.tables.contains(where: {
                sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
            }) {
                actions.append(UIAction(title: "Insert Table Row") { [weak self] _ in
                    guard let self,
                          let mutation = WiskMarkdownDocumentEngine.insertTableRow(
                            in: self.parent.markdownText,
                            sourceRange: sourceRange
                          ) else { return }
                    self.applyTableMutation(mutation, textView: textView)
                })
                actions.append(UIAction(title: "Delete Table Row") { [weak self] _ in
                    guard let self,
                          let mutation = WiskMarkdownDocumentEngine.deleteTableRow(
                            in: self.parent.markdownText,
                            sourceRange: sourceRange
                          ) else { return }
                    self.applyTableMutation(mutation, textView: textView)
                })
                actions.append(UIAction(title: "Insert Table Column") { [weak self] _ in
                    guard let self,
                          let mutation = WiskMarkdownDocumentEngine.insertTableColumn(
                            in: self.parent.markdownText,
                            sourceRange: sourceRange
                          ) else { return }
                    self.applyTableMutation(mutation, textView: textView)
                })
                actions.append(UIAction(title: "Delete Table Column") { [weak self] _ in
                    guard let self,
                          let mutation = WiskMarkdownDocumentEngine.deleteTableColumn(
                            in: self.parent.markdownText,
                            sourceRange: sourceRange
                          ) else { return }
                    self.applyTableMutation(mutation, textView: textView)
                })
            }
            if let anchor = WiskMarkdownFolding.foldAnchor(atSource: sourceRange.location, in: document),
               WiskMarkdownFolding.interiorSourceRange(forFoldAt: anchor, in: document) != nil {
                let folded = parent.foldedSourceLocations.wrappedValue.contains(anchor)
                actions.append(UIAction(title: folded ? "Unfold" : "Fold") { [weak self] _ in
                    guard let self else { return }
                    if folded {
                        self.parent.foldedSourceLocations.wrappedValue.remove(anchor)
                    } else {
                        self.parent.foldedSourceLocations.wrappedValue.insert(anchor)
                    }
                    self.applyMarkdownText(self.parent.markdownText, to: textView)
                })
            }
            return actions
        }

        private func availableWidth(for textView: UITextView) -> CGFloat {
            wiskRichEditorAvailableWidth(
                boundsWidth: textView.bounds.width,
                horizontalInset: textView.textContainerInset.left + textView.textContainerInset.right,
                lineFragmentPadding: textView.textContainer.lineFragmentPadding
            )
        }

        // MARK: - Outer-scroll caret bridge
        // The editor text view no longer scrolls internally (it grows with
        // content inside the SwiftUI ScrollView host), so caret visibility is
        // bridged to the nearest ancestor UIScrollView — the SwiftUI
        // ScrollView host view.

        /// Nearest ancestor scroll view above `textView`, skipping the text
        /// view itself (UITextView is a UIScrollView subclass even with
        /// scrolling disabled).
        private func nearestHostScrollView(for textView: UITextView) -> UIScrollView? {
            var responder: UIResponder? = textView
            while let current = responder {
                if let scrollView = current as? UIScrollView, scrollView !== textView {
                    return scrollView
                }
                responder = current.next
            }
            return nil
        }

        // MARK: Keyboard-aware host scrolling
        // The editor ScrollView ignores keyboard safe areas (see
        // wiskIgnoresKeyboardSafeArea in WiskFeatureViews.swift), so the
        // keyboard never scrolls the viewport on focus. The caret bridge
        // itself subtracts keyboard overlap from the host's visible bounds.

        private func observeKeyboardFrameChanges() {
            keyboardFrameObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                self.keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                guard let textView = self.attachedTextView, textView.isFirstResponder else { return }
                self.ensureCaretVisibleInHost(textView)
            }
        }

        /// Host visible bounds with any keyboard overlap removed.
        private func visibleBoundsExcludingKeyboard(of host: UIScrollView) -> CGRect {
            let bounds = host.bounds.inset(by: host.adjustedContentInset)
            guard keyboardFrame != .zero else { return bounds }
            let keyboardInHost = host.convert(keyboardFrame, from: nil)
            let overlap = bounds.maxY - keyboardInHost.minY
            guard overlap > 0 else { return bounds }
            return bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: overlap, right: 0))
        }

        func ensureCaretVisibleInHost(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate, textView.markedTextRange == nil else { return }
            guard let start = textView.selectedTextRange?.start else { return }
            let caretRect = textView.caretRect(for: start)
            guard caretRect.width > 0 || caretRect.height > 0 else { return }
            scrollRectIntoHostVisibility(
                caretRect,
                in: textView,
                onlyIfFullyOutside: true,
                animated: true
            )
        }

        // MARK: Deterministic sentence capitalization
        // Every keystroke here is a programmatic textStorage edit, so stock
        // UIKit autocapitalization cannot track sentence state (autocap is
        // disabled in makeUIView). Capitalize the typed replacement's first
        // letter only when the visible-text context says sentence start.

        func sentenceStartCapitalizedReplacement(_ text: String, textView: UITextView) -> String {
            sentenceStartCapitalizedReplacement(text, caretLocation: textView.selectedRange.location, textView: textView)
        }

        private func sentenceStartCapitalizedReplacement(
            _ text: String,
            caretLocation: Int,
            textView: UITextView
        ) -> String {
            guard text.contains(where: { $0.isLetter }),
                  let letterIndex = text.firstIndex(where: { $0.isLetter }),
                  text[letterIndex].isLowercase
            else { return text }
            guard isVisibleSentenceStart(beforeCaret: caretLocation, in: textView) else { return text }
            var result = text
            result.replaceSubrange(letterIndex...letterIndex, with: text[letterIndex].uppercased())
            return result
        }

        /// True when the caret sits at a sentence start: position 0, or after
        /// `. ! ? …` allowing whitespace and closing quotes/brackets between
        /// the terminator and the caret. A `.` that ends a numbered list
        /// marker ("1.") does not count.
        private func isVisibleSentenceStart(beforeCaret caretLocation: Int, in textView: UITextView) -> Bool {
            isVisibleSentenceStart(beforeCaret: textView.text, caretLocation: caretLocation)
        }

        private func isVisibleSentenceStart(beforeCaret text: String, caretLocation: Int) -> Bool {
            guard caretLocation != NSNotFound, caretLocation > 0 else { return true }
            let ns = text as NSString
            var index = caretLocation - 1
            let sentenceTerminators: Set<unichar> = [
                unichar(UnicodeScalar(".").value),
                unichar(UnicodeScalar("!").value),
                unichar(UnicodeScalar("?").value),
                0x2026, // …
            ]
            // Skipped while scanning backward: whitespace, closing
            // quotes/brackets (as in: He said." ), and opening ones (an
            // opener at the sentence start means the text after it starts
            // the sentence — both "hello and (hello should capitalize).
            let transparent: Set<unichar> = [
                unichar(UnicodeScalar("\"").value),
                unichar(UnicodeScalar("'").value),
                unichar(UnicodeScalar(")").value),
                unichar(UnicodeScalar("]").value),
                unichar(UnicodeScalar("}").value),
                unichar(UnicodeScalar("(").value),
                unichar(UnicodeScalar("[").value),
                unichar(UnicodeScalar("{").value),
                0x201C, // "
                0x201D, // "
                0x2018, // '
                0x2019, // '
                0x00AB, // «
                0x00BB, // »
            ]
            while index >= 0 {
                let character = ns.character(at: index)
                let isWhitespace = UnicodeScalar(character)
                    .map(CharacterSet.whitespacesAndNewlines.contains) == true
                if isWhitespace || transparent.contains(character) {
                    index -= 1
                    continue
                }
                break
            }
            if index < 0 {
                // Only transparent characters between the document start and
                // the caret ("hello → the text begins the sentence.
                return true
            }
            guard sentenceTerminators.contains(ns.character(at: index)) else { return false }
            let lineStart = ns.lineRange(for: NSRange(location: index, length: 0)).location
            let marker = ns.substring(with: NSRange(location: lineStart, length: index - lineStart + 1))
            if marker.range(of: "^[[:space:]]*[0-9]+[.)]$", options: .regularExpression) != nil {
                return false
            }
            return true
        }

        func scrollRangeIntoHostVisibility(_ range: NSRange, in textView: UITextView) {
            // No-op when the text view scrolls itself; with internal scrolling
            // disabled the host bridge below is the effective path.
            textView.scrollRangeToVisible(range)
            guard !textView.isScrollEnabled else { return }
            let length = textView.textStorage.length
            guard length > 0 else { return }
            let location = min(max(range.location, 0), length - 1)
            guard let rect = wiskGlyphRect(in: textView, characterIndex: location) else { return }
            scrollRectIntoHostVisibility(
                rect.insetBy(dx: 0, dy: -16),
                in: textView,
                onlyIfFullyOutside: false,
                animated: false
            )
        }

        private func scrollRectIntoHostVisibility(
            _ rect: CGRect,
            in textView: UITextView,
            onlyIfFullyOutside: Bool,
            animated: Bool
        ) {
            guard textView.window != nil, let host = nearestHostScrollView(for: textView) else { return }
            let rectInHost = host.convert(rect, from: textView)
            if onlyIfFullyOutside, visibleBoundsExcludingKeyboard(of: host).contains(rectInHost) { return }
            // Defer one tick so SwiftUI has applied the text view's new
            // content height to the host scroll view before scrolling it.
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host else { return }
                self.scrollHostToMakeVisible(rectInHost.insetBy(dx: 0, dy: -12), in: host, animated: animated)
            }
        }

        /// Minimal scroll of the host so `target` sits inside the visible
        /// bounds (keyboard overlap excluded). Replaces scrollRectToVisible,
        /// which cannot express a keyboard-excluded visible area.
        private func scrollHostToMakeVisible(
            _ target: CGRect,
            in host: UIScrollView,
            animated: Bool
        ) {
            let bounds = visibleBoundsExcludingKeyboard(of: host)
            var deltaY: CGFloat = 0
            if target.maxY > bounds.maxY {
                deltaY = target.maxY - bounds.maxY
            } else if target.minY < bounds.minY {
                deltaY = target.minY - bounds.minY
            }
            guard deltaY != 0 else { return }
            let contentHeight = host.contentSize.height
                + host.adjustedContentInset.top
                + host.adjustedContentInset.bottom
            let minY = host.adjustedContentInset.top
            let maxY = max(minY, contentHeight - host.bounds.height)
            let y = min(max(host.contentOffset.y + deltaY, minY), maxY)
            host.setContentOffset(CGPoint(x: host.contentOffset.x, y: y), animated: animated)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            caretChangeIsUserInitiated = true
            rememberVisibleRange(textView.selectedRange, in: textView, isUserInitiated: true)
            parent.onFocusChange?(true)
            ensureCaretVisibleInHost(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange?(false)
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if let target = WiskNoteLinkService.wikiTarget(from: URL) {
                parent.onOpenWikiLink?(target)
                return false
            }
            return WiskMarkdownDocumentEngine.isSafeURL(URL)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let isUserInitiated = caretChangeIsUserInitiated
            caretChangeIsUserInitiated = false
            if !isApplyingProgrammaticUpdate, textView.selectedRange.location != NSNotFound {
                let didRemember = rememberVisibleRange(
                    textView.selectedRange,
                    in: textView,
                    isUserInitiated: isUserInitiated
                )
                if didRemember, let mapped = mappedSelectedMarkdownRange(from: textView.selectedRange) {
                    parent.selectedMarkdownRange = mapped
                    publishWikiQuery()
                    publishWikiCaret(in: textView)
                }
            }
            guard !isApplyingProgrammaticUpdate else { return }
            ensureCaretVisibleInHost(textView)
            (textView as? WiskMarkdownUITextView)?.syncImageResizeChromeFromSelection()
            dropAbandonedMarkedCommitState(in: textView)
        }

        /// A composition that ended without a committed text change
        /// (cancelled IME input, rejected dictation) leaves
        /// pendingEditedRange pointing at a location nothing was inserted
        /// into. A later unrelated native change could then apply a bogus
        /// replacement there. The deferred drop gives a real commit's
        /// textViewDidChange one runloop tick to consume the pending range
        /// first.
        private func dropAbandonedMarkedCommitState(in textView: UITextView) {
            guard textView.markedTextRange == nil,
                  pendingEditedRange != nil,
                  !isApplyingProgrammaticUpdate,
                  !isApplyingSourceEdit else {
                return
            }
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                guard self.pendingEditedRange != nil, textView.markedTextRange == nil else { return }
                self.pendingEditedRange = nil
                if self.nativeUndoDisabledForMarkedCommit {
                    self.nativeUndoDisabledForMarkedCommit = false
                    textView.undoManager?.enableUndoRegistration()
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? WiskMarkdownUITextView)?.refreshImageResizeChrome()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            caretChangeIsUserInitiated = true
            if textView.markedTextRange != nil {
                if pendingEditedRange == nil {
                    // First event of a composition: the text view still shows
                    // the pre-composition render, so this length is the
                    // incremental patch's baseline.
                    pendingEditedRange = PendingNativeEdit(
                        editedRange: NSRange(location: range.location, length: max(range.length, (text as NSString).length)),
                        baseTextLength: textView.textStorage.length
                    )
                } else {
                    pendingEditedRange?.editedRange = NSRange(location: range.location, length: max(range.length, (text as NSString).length))
                }
                // The native commit applies outside the coordinator and would
                // register its own undo entry in the shared manager; suppress
                // it so the commit is a single source-level undo step. The
                // registration is re-enabled at the top of textViewDidChange.
                if let undoManager = textView.undoManager,
                   !undoManager.isUndoing, !undoManager.isRedoing {
                    nativeUndoDisabledForMarkedCommit = true
                    undoManager.disableUndoRegistration()
                }
                return true
            }
            pendingEditedRange = nil
            if isApplyingSourceEdit || (textView as? WiskMarkdownUITextView)?.isHandlingKeyInput == true {
                return false
            }
            // Return keeps the engine path so list continuation applies
            // synchronously. Deletions (empty replacement) must commit
            // through the engine directly — the pending commit in
            // textViewDidChange can only express insertions/replacements
            // read back from the text view after the change, never a
            // deletion.
            if text == "\n" || text.isEmpty {
                let replacement = sentenceStartCapitalizedReplacement(text, textView: textView)
                return !applySourceEdit(visibleRange: range, replacement: replacement, textView: textView)
            }
            // Plain typing (characters, paste, autocorrect/QuickType
            // acceptance) applies natively so UIKit's input pipeline stays
            // live. textViewDidChange commits the result to the engine
            // source. Suppress the native text-level undo registration so
            // native insert + engine re-apply land as one source-level undo
            // step; re-enabled at the top of textViewDidChange (same pattern
            // as the marked-text commit above).
            if let undoManager = textView.undoManager,
               !undoManager.isUndoing, !undoManager.isRedoing {
                nativeUndoDisabledForMarkedCommit = true
                undoManager.disableUndoRegistration()
            }
            pendingEditedRange = PendingNativeEdit(
                editedRange: NSRange(location: range.location, length: max(range.length, (text as NSString).length)),
                // must be captured before UIKit applies the change: shouldChangeTextIn
                // runs while the text view still shows the old render.
                baseTextLength: textView.textStorage.length
            )
            return true
        }

        func applyIndent(outdent: Bool, textView: UITextView) {
            let document = parsedDocument(for: parent.markdownText)
            let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                    visibleRange: textView.selectedRange,
                    source: parent.markdownText,
                    showSourceMarkers: parent.showSourceMarkers,
                    document: document,
                    foldedLocations: parent.foldedSourceLocations.wrappedValue
                )
            guard let sourceRange else { return }
            if let tableMutation = WiskMarkdownDocumentEngine.applyTableTab(
                in: parent.markdownText,
                sourceRange: sourceRange,
                reverse: outdent
            ) {
                parent.selectedMarkdownRange = Range(tableMutation.selectedSourceRange, in: tableMutation.source)
                rememberSourceCaret(tableMutation.selectedSourceRange.location)
                applyMarkdownText(tableMutation.source, to: textView)
                rememberVisibleRange(textView.selectedRange, in: textView, isUserInitiated: true)
                return
            }
            guard let mutation = WiskMarkdownDocumentEngine.indentLines(
                in: parent.markdownText,
                sourceRange: sourceRange,
                outdent: outdent
            ) else { return }
            registerSourceUndo(
                previous: parent.markdownText,
                previousSelection: parent.selectedMarkdownRange,
                textView: textView
            )
            parent.markdownText = mutation.source
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            applyMarkdownText(mutation.source, to: textView)
        }

        func mappedSelectedMarkdownRange(from visibleRange: NSRange) -> Range<String.Index>? {
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: visibleRange,
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: parsedDocument(for: parent.markdownText),
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else {
                rememberSourceCaret(nil)
                return nil
            }
            rememberSourceCaret(sourceRange.location)
            return Range(sourceRange, in: parent.markdownText)
        }

        func textViewDidChange(_ textView: UITextView) {
            // Re-enable native undo registration suppressed for the
            // marked-text commit (see shouldChangeTextIn) before anything
            // else can run.
            if nativeUndoDisabledForMarkedCommit {
                nativeUndoDisabledForMarkedCommit = false
                textView.undoManager?.enableUndoRegistration()
            }
            // The text view no longer scrolls internally, so re-measure on
            // every edit before any early-return can skip it.
            textView.invalidateIntrinsicContentSize()
            guard !isApplyingProgrammaticUpdate else { return }
            guard textView.markedTextRange == nil else { return }
            guard let pending = pendingEditedRange else { return }
            pendingEditedRange = nil
            let ns = textView.attributedText.string as NSString
            // Visible length the native change added (can be negative for a
            // shrinking autocorrect acceptance). The text view already shows
            // the native characters, so the incremental patch must replace
            // the new line's actual span, not the old render's.
            let nativeTextViewDelta = ns.length - pending.baseTextLength
            let replacementLength = max(textView.selectedRange.location - pending.editedRange.location, 0)
            let replacementRange = NSRange(
                location: pending.editedRange.location,
                length: min(replacementLength, max(ns.length - pending.editedRange.location, 0))
            )
            var replacement = replacementRange.length > 0 ? ns.substring(with: replacementRange) : ""
            if replacementRange.length > 0 {
                // Autocorrect/dictation/IME commits apply natively and never
                // pass through the direct typing path, so apply the same
                // deterministic sentence capitalization here. The context
                // before pending.editedRange.location is unchanged by the
                // commit.
                replacement = sentenceStartCapitalizedReplacement(
                    replacement,
                    caretLocation: pending.editedRange.location,
                    textView: textView
                )
            }
            let originalRange = NSRange(location: pending.editedRange.location, length: 0)
            _ = applySourceEdit(
                visibleRange: originalRange,
                replacement: replacement,
                textView: textView,
                nativeTextViewDelta: nativeTextViewDelta
            )
        }
    }
}
#elseif os(macOS)
private final class WiskImageSizeMenuPayload: NSObject {
    let attachmentID: UUID
    let width: Double?

    init(attachmentID: UUID, width: Double?) {
        self.attachmentID = attachmentID
        self.width = width
    }
}

private final class WiskAttachmentMenuPayload: NSObject {
    let attachmentID: UUID
    let action: WiskAttachmentEditorAction

    init(attachmentID: UUID, action: WiskAttachmentEditorAction) {
        self.attachmentID = attachmentID
        self.action = action
    }
}

private final class TableMenuPayload: NSObject {
    let title: String
    let sourceRange: NSRange

    init(title: String, sourceRange: NSRange) {
        self.title = title
        self.sourceRange = sourceRange
    }
}

enum WiskMacBodyEditorFocus {
    @MainActor static weak var currentTextView: NSTextView?

    @MainActor static var isFirstResponder: Bool {
        guard let currentTextView else { return false }
        return currentTextView.window?.firstResponder === currentTextView
    }
}

enum WiskTextKitSelections {
    static func nsRanges(from textView: NSTextView) -> [NSRange] {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else {
            return []
        }
        let documentStart = layoutManager.documentRange.location
        var ranges: [NSRange] = []
        for selection in layoutManager.textSelections {
            for textRange in selection.textRanges {
                let location = contentStorage.offset(from: documentStart, to: textRange.location)
                let end = contentStorage.offset(from: documentStart, to: textRange.endLocation)
                guard location >= 0, end >= location else { continue }
                ranges.append(NSRange(location: location, length: end - location))
            }
        }
        return ranges
    }

    static func visualLineFragments(in textView: NSTextView, intersecting selection: NSRange) -> [NSRange] {
        guard selection.location != NSNotFound,
              selection.length > 0,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let start = layoutManager.location(
                layoutManager.documentRange.location,
                offsetBy: selection.location
              ),
              let end = layoutManager.location(start, offsetBy: selection.length),
              let textRange = NSTextRange(location: start, end: end) else {
            return []
        }
        layoutManager.ensureLayout(for: textRange)
        let documentStart = layoutManager.documentRange.location
        var ranges: [NSRange] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { segmentRange, _, _, _ in
            guard let segmentRange else { return true }
            let location = contentStorage.offset(from: documentStart, to: segmentRange.location)
            let length = contentStorage.offset(from: segmentRange.location, to: segmentRange.endLocation)
            if location >= 0, length >= 0 {
                ranges.append(NSRange(location: location, length: length))
            }
            return true
        }
        return ranges
    }

    @discardableResult
    static func apply(_ ranges: [NSRange], to textView: NSTextView) -> Bool {
        guard let layoutManager = textView.textLayoutManager else { return false }
        let documentStart = layoutManager.documentRange.location
        var selections: [NSTextSelection] = []
        selections.reserveCapacity(ranges.count)
        for range in ranges {
            guard let start = layoutManager.location(documentStart, offsetBy: range.location) else {
                return false
            }
            if range.length == 0 {
                selections.append(NSTextSelection(start, affinity: .downstream))
                continue
            }
            guard let end = layoutManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else {
                return false
            }
            selections.append(
                NSTextSelection(range: textRange, affinity: .downstream, granularity: .character)
            )
        }
        guard selections.count == ranges.count, selections.isEmpty == false else { return false }
        layoutManager.textSelections = selections
        textView.updateInsertionPointStateAndRestartTimer(true)
        textView.needsDisplay = true
        return true
    }

    static func caretRect(in textView: NSTextView, at utf16Index: Int) -> NSRect? {
        let length = (textView.string as NSString).length
        let index = min(max(utf16Index, 0), length)
        var actual = NSRange(location: 0, length: 0)
        let query = NSRange(location: index, length: index < length ? 1 : 0)
        let screenRect = textView.firstRect(forCharacterRange: query, actualRange: &actual)
        if let window = textView.window, screenRect.height >= 1 {
            let windowRect = window.convertFromScreen(screenRect)
            var local = textView.convert(windowRect, from: nil)
            if index < length {
                local.size.width = 2
            } else {
                local.origin.x += max(local.width - 2, 0)
                local.size.width = 2
            }
            if local.height >= 1 {
                return local
            }
        }

        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let location = layoutManager.location(
                layoutManager.documentRange.location,
                offsetBy: index
              ) else {
            return nil
        }
        let documentStart = layoutManager.documentRange.location
        var lineFrame = CGRect.null
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutManager.enumerateTextSegments(
            in: NSTextRange(location: location),
            type: .standard,
            options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            lineFrame = frame
            return false
        }
        if lineFrame.isNull || lineFrame.height < 1 {
            layoutManager.enumerateTextLayoutFragments(
                from: location,
                options: [.ensuresLayout, .ensuresExtraLineFragment]
            ) { fragment in
                lineFrame = fragment.layoutFragmentFrame
                return false
            }
        }
        guard lineFrame.isNull == false, lineFrame.height >= 1 else { return nil }

        var caretX = lineFrame.minX
        layoutManager.enumerateCaretOffsetsInLineFragment(at: location) { offset, caretLocation, leadingEdge, stop in
            let caretIndex = contentStorage.offset(from: documentStart, to: caretLocation)
            if caretIndex == index {
                caretX = offset
                if leadingEdge {
                    stop.pointee = true
                }
            }
        }

        var rect = CGRect(x: caretX, y: lineFrame.minY, width: 2, height: lineFrame.height)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }
}

private final class WiskMarkdownNSTextView: NSTextView {
    var onAttachmentDisplayWidthChange: ((UUID, Double?) -> Void)?
    var onAttachmentAction: ((UUID, WiskAttachmentEditorAction) -> Void)?
    var onOpenWikiLink: ((String) -> Void)?
    var onApplyFormatting: ((WiskMarkdownFormattingRequest) -> Void)?
    var onToggleChecklist: ((Int) -> Void)?
    var markCaretUserInitiated: (() -> Void)?
    var commitCaret: ((NSRange) -> Void)?
    var snapshotEditingCaret: ((NSRange) -> Void)?
    var imageAttachmentsProvider: () -> [NoteAttachment] = { [] }
    var onPasteImage: (() -> Void)?
    var onMultiCursorCommand: ((WiskEditorMultiCursor.Command) -> Void)?
    var markSelectionFromMouse: (() -> Void)?
    var onCollapseMultiCursor: (() -> Void)?
    var onDoCommand: ((Selector) -> Bool)?
    var extraInsertionPoints: [NSRange] = [] {
        didSet {
            refreshExtraCaretRects()
            updateInsertionPointStateAndRestartTimer(true)
            needsDisplay = true
        }
    }

    let imageResizeController = WiskImageAttachmentResizeController()
    private var extraCaretRects: [NSRect] = []
    var onContainerWidthCommitted: (() -> Void)?
    private(set) var isDeferringContainerWidth = false
    private var observesEditorCommands = false
    private var resizeCursorTrackingArea: NSTrackingArea?
    private var didPushResizeCursor = false
    private let widthCoalescer = WiskWidthCoalescer()
    private var widthSettleTask: Task<Void, Never>?
    private var extraCaretKeyMonitor: Any?
    private var extraInsertionIndicators: [NSTextInsertionIndicator] = []

    func observeEditorCommands() {
        guard !observesEditorCommands else { return }
        observesEditorCommands = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyEditorFormatting(_:)),
            name: .wiskApplyMarkdownEditorFormatting,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentInNoteFind),
            name: .wiskFindInNote,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitSelectionIntoLinesCommand),
            name: .wiskSplitSelectionIntoLines,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectNextOccurrenceCommand),
            name: .wiskSelectNextOccurrence,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectAllOccurrencesCommand),
            name: .wiskSelectAllOccurrences,
            object: nil
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            observeEditorCommands()
            observeScrollForImageResizeChrome()
            installExtraCaretKeyMonitor()
            refreshExtraCaretRects()
        } else {
            removeExtraCaretKeyMonitor()
        }
    }

    func captureEditingCaret(from event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        snapshotEditingCaret?(NSRange(location: index, length: 0))
    }

    func containsMouse(of event: NSEvent) -> Bool {
        guard event.window === window, let contentView = window?.contentView else { return false }
        var hit: NSView? = contentView.hitTest(event.locationInWindow)
        while let current = hit {
            if current === self {
                return true
            }
            hit = current.superview
        }
        return false
    }

    func handleFormattingRequest(_ request: WiskMarkdownFormattingRequest) {
        onApplyFormatting?(request)
    }

    deinit {
        widthSettleTask?.cancel()
        removeExtraCaretKeyMonitor()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func presentInNoteFind() {
        guard isBodyEditorKeyTarget else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performFindPanelAction(item)
    }

    @objc private func splitSelectionIntoLinesCommand() {
        guard isBodyEditorKeyTarget else { return }
        onMultiCursorCommand?(.splitIntoLines)
    }

    @objc private func selectNextOccurrenceCommand() {
        guard isBodyEditorKeyTarget else { return }
        onMultiCursorCommand?(.selectNextOccurrence)
    }

    @objc private func selectAllOccurrencesCommand() {
        guard isBodyEditorKeyTarget else { return }
        onMultiCursorCommand?(.selectAllOccurrences)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleMultiCursorKeyEquivalent(event) {
            return true
        }
        if handleFormattingKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Direct ⌘B/⌘I/⌘U (and ⌘⇧U/⌘⇧M) formatting while the body editor has
    /// keyboard focus. Dispatches through the same onApplyFormatting closure
    /// the Format menu's notification path reaches, but without depending on
    /// the WiskActiveMarkdownEditor claim or the formatting-bar visibility
    /// setting, so the shortcuts work any time the editor is key.
    private func handleFormattingKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isEditable,
              isBodyEditorKeyTarget,
              event.type == .keyDown else {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let character = event.charactersIgnoringModifiers?.lowercased()
        let action: WiskMarkdownFormattingAction?
        if flags == [.command] {
            switch character {
            case "b": action = .bold
            case "i": action = .italic
            case "u": action = .underline
            default: action = nil
            }
        } else if flags == [.command, .shift] {
            switch character {
            case "u": action = .strikethrough
            case "m": action = .highlight
            default: action = nil
            }
        } else {
            action = nil
        }
        guard let action else { return false }
        onApplyFormatting?(WiskMarkdownFormattingRequest(action: action))
        return true
    }

    override func doCommand(by selector: Selector) {
        if extraInsertionPoints.count >= 2, onDoCommand?(selector) == true {
            return
        }
        super.doCommand(by: selector)
    }

    /// Shift+Return maps to `insertLineBreak:`, whose default inserts the
    /// U+2028 line separator into the note source. The markdown engine only
    /// understands "\n" lines, so route it through the normal newline
    /// pipeline (applyReturn continues/terminates lists like plain Return).
    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    private func installExtraCaretKeyMonitor() {
        guard extraCaretKeyMonitor == nil else { return }
        extraCaretKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.extraInsertionPoints.count >= 2,
                  self.window?.isKeyWindow == true,
                  self.handleExtraCaretKey(event) else {
                return event
            }
            return nil
        }
    }

    private func removeExtraCaretKeyMonitor() {
        if let extraCaretKeyMonitor {
            NSEvent.removeMonitor(extraCaretKeyMonitor)
            self.extraCaretKeyMonitor = nil
        }
    }

    private func handleExtraCaretKey(_ event: NSEvent) -> Bool {
        guard isEditable, event.type == .keyDown else { return false }
        guard let selector = extraCaretSelector(for: event) else { return false }
        return onDoCommand?(selector) == true
    }

    private func extraCaretSelector(for event: NSEvent) -> Selector? {
        let significant = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case 123:
            if significant.isEmpty { return #selector(NSResponder.moveLeft(_:)) }
            if significant == [.option] { return #selector(NSResponder.moveWordLeft(_:)) }
            if significant == [.command] { return #selector(NSResponder.moveToBeginningOfLine(_:)) }
            return nil
        case 124:
            if significant.isEmpty { return #selector(NSResponder.moveRight(_:)) }
            if significant == [.option] { return #selector(NSResponder.moveWordRight(_:)) }
            if significant == [.command] { return #selector(NSResponder.moveToEndOfLine(_:)) }
            return nil
        case 125:
            return significant.isEmpty ? #selector(NSResponder.moveDown(_:)) : nil
        case 126:
            return significant.isEmpty ? #selector(NSResponder.moveUp(_:)) : nil
        case 51:
            return significant.isEmpty ? #selector(NSResponder.deleteBackward(_:)) : nil
        case 117:
            return significant.isEmpty ? #selector(NSResponder.deleteForward(_:)) : nil
        default:
            return nil
        }
    }

    private var isBodyEditorKeyTarget: Bool {
        window?.firstResponder === self || WiskMacBodyEditorFocus.currentTextView === self
    }

    private func handleMultiCursorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isEditable,
              isBodyEditorKeyTarget,
              event.type == .keyDown else {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let character = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command, .shift], character == "l" {
            onMultiCursorCommand?(.splitIntoLines)
            return true
        }
        if flags == [.command], character == "d" {
            onMultiCursorCommand?(.selectNextOccurrence)
            return true
        }
        if flags == [.command, .control], character == "g" {
            onMultiCursorCommand?(.selectAllOccurrences)
            return true
        }
        return false
    }

    private func refreshExtraCaretRects() {
        extraCaretRects = extraInsertionPoints.compactMap { range in
            WiskTextKitSelections.caretRect(in: self, at: range.location)
        }
        updateExtraInsertionIndicators()
    }

    private func extraCaretOverlayRects() -> [NSRect] {
        let primary = selectedRange()
        return extraInsertionPoints.enumerated().compactMap { index, extra in
            if extra.location == primary.location, extra.length == primary.length {
                return nil
            }
            if extraCaretRects.indices.contains(index) {
                return extraCaretRects[index]
            }
            return WiskTextKitSelections.caretRect(in: self, at: extra.location)
        }
    }

    private func updateExtraInsertionIndicators() {
        let rects = extraInsertionPoints.count >= 2 ? extraCaretOverlayRects() : []
        let visible = rects.isEmpty == false && shouldDrawInsertionPoint
        while extraInsertionIndicators.count > rects.count {
            extraInsertionIndicators.removeLast().removeFromSuperview()
        }
        while extraInsertionIndicators.count < rects.count {
            let indicator = NSTextInsertionIndicator(frame: .zero)
            addSubview(indicator)
            extraInsertionIndicators.append(indicator)
        }
        for (indicator, rect) in zip(extraInsertionIndicators, rects) {
            if indicator.color != insertionPointColor {
                indicator.color = insertionPointColor
            }
            if NSEqualRects(indicator.frame, rect) == false {
                indicator.frame = rect
            }
            let mode: NSTextInsertionIndicator.DisplayMode = visible ? .automatic : .hidden
            if indicator.displayMode != mode {
                indicator.displayMode = mode
            }
        }
    }

    private func collapseExtraInsertionPoints() {
        guard extraInsertionPoints.count >= 2 else { return }
        extraInsertionPoints = []
        onCollapseMultiCursor?()
    }

    override func layout() {
        super.layout()
        if extraInsertionPoints.isEmpty == false {
            refreshExtraCaretRects()
        }
    }

    override func selectAll(_ sender: Any?) {
        collapseExtraInsertionPoints()
        super.selectAll(sender)
    }

    @objc private func applyEditorFormatting(_ notification: Notification) {
        guard let request = notification.object as? WiskMarkdownFormattingRequest,
              WiskActiveMarkdownEditor.canHandle(from: self, request: request) else { return }
        WiskActiveMarkdownEditor.claim(self)
        onApplyFormatting?(request)
    }

    func configureImageResize() {
        imageResizeController.attach(to: self)
        observeScrollForImageResizeChrome()
    }

    private func observeScrollForImageResizeChrome() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        guard let contentView = enclosingScrollView?.contentView else { return }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsChangedForImageResize),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    @objc private func scrollViewBoundsChangedForImageResize() {
        updateHoverImageResizeChrome()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > WiskEditorPerformance.widthChangeEpsilon
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        handleContainerWidthChange()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        pauseContainerWidthTracking()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        commitContainerWidth()
    }

    func cancelDeferredWidthCommit() {
        widthSettleTask?.cancel()
        widthSettleTask = nil
    }

    private func handleContainerWidthChange() {
        switch widthCoalescer.noteWidth(bounds.width) {
        case .unchanged:
            break
        case .commitNow:
            commitContainerWidth()
        case .deferUntilSettled:
            pauseContainerWidthTracking()
            scheduleContainerWidthCommit()
        }
    }

    private func pauseContainerWidthTracking() {
        guard isDeferringContainerWidth == false else { return }
        isDeferringContainerWidth = true
        textContainer?.widthTracksTextView = false
        let wrapWidth = widthCoalescer.committedWidth ?? bounds.width
        textContainer?.containerSize = NSSize(
            width: wrapWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func scheduleContainerWidthCommit() {
        widthSettleTask?.cancel()
        widthSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: WiskEditorPerformance.widthSettleNanoseconds)
            guard !Task.isCancelled else { return }
            self?.commitContainerWidth()
        }
    }

    private func commitContainerWidth() {
        cancelDeferredWidthCommit()
        let width = bounds.width
        _ = widthCoalescer.commit(width)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        isDeferringContainerWidth = false
        onContainerWidthCommitted?()
    }

    func refreshImageResizeChromeIfSelected() {
        guard imageResizeController.hasSelection else { return }
        refreshImageResizeChrome()
    }

    func currentAvailableWidth() -> CGFloat {
        wiskRichEditorAvailableWidth(
            boundsWidth: bounds.width,
            horizontalInset: textContainerInset.width * 2,
            lineFragmentPadding: textContainer?.lineFragmentPadding ?? 0
        )
    }

    func refreshImageResizeChrome() {
        guard let id = imageResizeController.selectedAttachmentID,
              let storage = textStorage,
              let index = wiskCharacterIndex(ofAttachmentID: id, in: storage),
              let rect = wiskGlyphRect(in: self, characterIndex: index) else {
            if imageResizeController.hasSelection, imageResizeController.isDragging == false {
                imageResizeController.clear()
            }
            window?.invalidateCursorRects(for: self)
            return
        }
        imageResizeController.refresh(characterIndex: index, imageRect: rect)
        window?.invalidateCursorRects(for: self)
    }

    func syncImageResizeChromeFromSelection() {
        updateHoverImageResizeChrome()
    }

    func updateHoverImageResizeChrome(at point: NSPoint? = nil) {
        if imageResizeController.isDragging {
            refreshImageResizeChrome()
            return
        }
        guard isEditable, window != nil else {
            hideImageResizeChrome()
            return
        }
        let point = point ?? convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        guard visibleRect.contains(point), let hit = imageHit(at: point) else {
            hideImageResizeChrome()
            return
        }
        imageResizeController.select(
            attachmentID: hit.attachment.id,
            characterIndex: hit.index,
            imageRect: hit.rect
        )
        window?.invalidateCursorRects(for: self)
    }

    private func hideImageResizeChrome() {
        guard imageResizeController.isDragging == false else { return }
        guard imageResizeController.hasSelection else { return }
        imageResizeController.clear()
        window?.invalidateCursorRects(for: self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            WiskMacBodyEditorFocus.currentTextView = self
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            for indicator in extraInsertionIndicators {
                indicator.displayMode = .hidden
            }
            if WiskMacBodyEditorFocus.currentTextView === self {
                WiskMacBodyEditorFocus.currentTextView = nil
            }
        }
        return resigned
    }

    override func paste(_ sender: Any?) {
        if isEditable, let onPasteImage, MacPasteSupport.hasImageContent() {
            onPasteImage()
            return
        }
        super.paste(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           isEditable,
           onPasteImage != nil,
           MacPasteSupport.hasImageContent() {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    // Stock NSTextView copy only writes text flavors: image attachments are
    // NSTextAttachments without file wrappers, so nothing image-typed reaches
    // the clipboard and other apps (Gale, browsers, Preview) see no image to
    // paste. Mirror the selected attachments' bytes onto the pasteboard after
    // the text flavors are written. AppKit clears the pasteboard once and
    // then calls writeSelection once per declared type; the .string pass
    // always runs, so write the image data there exactly once.
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let wrote = super.writeSelection(to: pasteboard, type: type)
        guard type == .string else { return wrote }
        writeSelectedAttachmentData(to: pasteboard)
        if let markdown = markdownSourceForAttachmentSelection() {
            pasteboard.setString(markdown, forType: .string)
        }
        return wrote
    }

    /// The stock plain-text flavor for a selection containing attachments is a
    /// run of object-replacement glyphs. When the selection covers whole lines
    /// and includes attachments, replace it with the markdown source so pasting
    /// back into Wisk (or any markdown surface) preserves the attachment
    /// reference instead of invisible glyphs. Partial-line selections keep the
    /// stock flavor: converting a text fragment to markdown could mangle it.
    private func markdownSourceForAttachmentSelection() -> String? {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return nil }

        var containsAttachment = false
        storage.enumerateAttribute(.wiskMarkdownAttachmentID, in: range, options: []) { value, _, stop in
            if value != nil {
                containsAttachment = true
                stop.pointee = true
            }
        }
        guard containsAttachment else { return nil }

        let nsString = storage.string as NSString
        let lineRange = nsString.lineRange(for: range)
        guard lineRange.location == range.location,
              NSMaxRange(lineRange) == NSMaxRange(range),
              NSMaxRange(lineRange) <= storage.length else { return nil }

        return WiskRichMarkdownDocument.markdown(from: storage.attributedSubstring(from: lineRange))
    }

    private func writeSelectedAttachmentData(to pasteboard: NSPasteboard) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        var attachmentsByID: [UUID: NoteAttachment] = [:]
        for attachment in imageAttachmentsProvider() {
            attachmentsByID[attachment.id] = attachment
        }

        var seenIDs: Set<UUID> = []
        var images: [NSImage] = []
        storage.enumerateAttribute(.wiskMarkdownAttachmentID, in: range) { value, attrRange, _ in
            guard let idString = value as? String,
                  let id = UUID(uuidString: idString),
                  seenIDs.contains(id) == false else { return }
            guard storage.attribute(.wiskMarkdownAttachmentIsImage, at: attrRange.location, effectiveRange: nil) as? Bool == true,
                  let attachment = attachmentsByID[id] else { return }
            seenIDs.insert(id)

            guard let data = WiskAttachmentImageStore.shared.resolvedData(for: attachment) else { return }
            if attachment.contentType == "application/pdf" {
                pasteboard.setData(data, forType: .pdf)
                return
            }
            if let contentType = UTType(mimeType: attachment.contentType) {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(contentType.identifier))
            }
            if let image = NSImage(data: data) {
                images.append(image)
            }
        }

        if images.isEmpty == false {
            pasteboard.writeObjects(images) // TIFF flavors for apps that read NSImage/TIFF
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage,
           let attachment = wiskEditorAttachment(
            near: NSRange(location: index, length: 0),
            in: storage,
            attachments: imageAttachmentsProvider()
           ) ?? wiskEditorAttachment(
            near: selectedRange(),
            in: storage,
            attachments: imageAttachmentsProvider()
           ) {
            insertAttachmentMenuItems(into: menu, attachment: attachment)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        let inEditor = containsMouse(of: event)
        if inEditor {
            markCaretUserInitiated?()
            markSelectionFromMouse?()
            collapseExtraInsertionPoints()
        }
        let point = convert(event.locationInWindow, from: nil)
        if shouldToggleChecklist(at: point) {
            return
        }
        if shouldOpenWikiLink(at: point, event: event) {
            return
        }
        guard isEditable else {
            super.mouseDown(with: event)
            if inEditor {
                commitCaret?(selectedRange())
            }
            return
        }
        updateHoverImageResizeChrome(at: point)
        if let handle = imageResizeController.handle(at: point) {
            window?.makeFirstResponder(self)
            if imageResizeController.beginDrag(handle: handle, availableWidth: currentAvailableWidth()) {
                pushResizeCursorIfNeeded()
            }
            return
        }
        if let hit = imageHit(at: point) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: hit.index, length: 1))
            commitCaret?(selectedRange())
            return
        }
        hideImageResizeChrome()
        if inEditor {
            captureEditingCaret(from: event)
        }
        super.mouseDown(with: event)
        let selected = selectedRange()
        if WiskRichMarkdownDocument.isOnLastLine(selected, in: string) == false || inEditor {
            commitCaret?(selected)
        }
    }

    override func keyDown(with event: NSEvent) {
        if handleMultiCursorKeyEquivalent(event) {
            return
        }
        if extraInsertionPoints.count >= 2, handleExtraCaretKey(event) {
            return
        }
        markCaretUserInitiated?()
        super.keyDown(with: event)
        if extraInsertionPoints.count < 2 {
            commitCaret?(selectedRange())
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard imageResizeController.isDragging else {
            markSelectionFromMouse?()
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let live = imageResizeController.updateDrag(currentX: point.x),
              let storage = textStorage else {
            return
        }
        wiskApplyLiveAttachmentWidth(
            in: storage,
            at: live.characterIndex,
            width: live.width,
            aspectRatio: live.aspectRatio
        )
        wiskInvalidateAttachmentLayout(self, characterIndex: live.characterIndex)
        refreshImageResizeChrome()
    }

    override func mouseUp(with event: NSEvent) {
        guard imageResizeController.isDragging else {
            super.mouseUp(with: event)
            return
        }
        persistFinishedImageResize()
    }

    override func cancelOperation(_ sender: Any?) {
        if imageResizeController.isDragging {
            cancelImageResize()
            return
        }
        if extraInsertionPoints.count >= 2 {
            let caret = NSRange(location: extraInsertionPoints[0].location, length: 0)
            extraInsertionPoints = []
            setSelectedRange(caret)
            onCollapseMultiCursor?()
            commitCaret?(caret)
            return
        }
        let layoutRanges = WiskTextKitSelections.nsRanges(from: self)
        if layoutRanges.count > 1 || selectedRanges.count > 1 {
            let location = layoutRanges.first?.location
                ?? (selectedRanges.first as? NSValue)?.rangeValue.location
                ?? selectedRange().location
            let caret = NSRange(location: location, length: 0)
            WiskTextKitSelections.apply([caret], to: self)
            setSelectedRange(caret)
            onCollapseMultiCursor?()
            commitCaret?(caret)
            return
        }
        onCollapseMultiCursor?()
        super.cancelOperation(sender)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverImageResizeChrome(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hideImageResizeChrome()
        super.mouseExited(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let resizeCursorTrackingArea {
            removeTrackingArea(resizeCursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        resizeCursorTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard imageResizeController.chrome.isHidden == false else { return }
        addCursorRect(
            WiskAttachmentImageResize.handleRect(
                for: .bottomRight,
                in: imageResizeController.imageRect,
                size: imageResizeController.chrome.hitSize
            ),
            cursor: macImageResizeCursor
        )
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if imageResizeController.isDragging || imageResizeController.handle(at: point) != nil {
            macImageResizeCursor.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverImageResizeChrome(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
    }

    private var macImageResizeCursor: NSCursor {
        NSCursor.frameResize(position: .bottomRight, directions: [.inward, .outward])
    }

    private func pushResizeCursorIfNeeded() {
        guard didPushResizeCursor == false else { return }
        macImageResizeCursor.push()
        didPushResizeCursor = true
    }

    private func popResizeCursorIfNeeded() {
        guard didPushResizeCursor else { return }
        NSCursor.pop()
        didPushResizeCursor = false
    }

    private func cancelImageResize() {
        defer { popResizeCursorIfNeeded() }
        if let restore = imageResizeController.cancelDrag(), let storage = textStorage {
            wiskApplyLiveAttachmentWidth(
                in: storage,
                at: restore.characterIndex,
                width: restore.width,
                aspectRatio: restore.aspectRatio
            )
            wiskInvalidateAttachmentLayout(self, characterIndex: restore.characterIndex)
        }
        collapseSelectionAfterImageResize()
        imageResizeController.clear()
        window?.invalidateCursorRects(for: self)
        updateHoverImageResizeChrome()
    }

    private func persistFinishedImageResize() {
        defer { popResizeCursorIfNeeded() }
        guard let result = imageResizeController.finishDrag() else { return }
        collapseSelectionAfterImageResize()
        onAttachmentDisplayWidthChange?(result.attachmentID, result.persistedWidth)
        updateHoverImageResizeChrome()
    }

    private func collapseSelectionAfterImageResize() {
        let index = imageResizeController.selectedCharacterIndex ?? selectedRange().location
        let caret = NSRange(location: min(index + 1, textStorage?.length ?? 0), length: 0)
        setSelectedRange(caret)
        commitCaret?(caret)
    }

    private func shouldToggleChecklist(at point: NSPoint) -> Bool {
        guard isEditable, let storage = textStorage, storage.length > 0 else { return false }
        let index = min(max(characterIndexForInsertion(at: point), 0), max(storage.length - 1, 0))
        let candidates = [index, max(index - 1, 0)]
        for candidate in candidates where WiskRichMarkdownDocument.isChecklistToggleLocation(candidate, in: storage) {
            onToggleChecklist?(candidate)
            return true
        }
        return false
    }

    private func shouldOpenWikiLink(at point: NSPoint, event: NSEvent) -> Bool {
        let commandClick = event.modifierFlags.contains(.command)
        guard commandClick || isEditable == false else { return false }
        let index = min(max(characterIndexForInsertion(at: point), 0), max((textStorage?.length ?? 1) - 1, 0))
        guard let target = wikiTarget(at: index) else { return false }
        onOpenWikiLink?(target)
        return true
    }

    private func wikiTarget(at index: Int) -> String? {
        guard let storage = textStorage, storage.length > 0, index >= 0, index < storage.length else {
            return nil
        }
        if let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL,
           let target = WiskNoteLinkService.wikiTarget(from: url) {
            return target
        }
        if let title = storage.attribute(.wiskMarkdownWikiLink, at: index, effectiveRange: nil) as? String,
           title.isEmpty == false {
            return title
        }
        return nil
    }

    private func insertAttachmentMenuItems(into menu: NSMenu, attachment: NoteAttachment) {
        var insertAt = 0
        if attachment.isImage, menu.item(withTitle: "Image Size") == nil {
            let submenu = NSMenu(title: "Image Size")
            for option in WiskAttachmentImageSizeOption.allCases {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(applyAttachmentMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = option.isSelected(for: attachment) ? .on : .off
                item.representedObject = WiskAttachmentMenuPayload(
                    attachmentID: attachment.id,
                    action: .displayWidth(option.displayWidth(for: attachment))
                )
                submenu.addItem(item)
            }
            let root = NSMenuItem(title: "Image Size", action: nil, keyEquivalent: "")
            root.submenu = submenu
            menu.insertItem(root, at: insertAt)
            insertAt += 1
        }
        if attachment.isImage, menu.item(withTitle: "Crop") == nil {
            let item = NSMenuItem(
                title: "Crop",
                action: #selector(applyAttachmentMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = WiskAttachmentMenuPayload(
                attachmentID: attachment.id,
                action: .crop
            )
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        if menu.item(withTitle: "Alignment") == nil {
            let submenu = NSMenu(title: "Alignment")
            let options: [(String, NoteAttachmentAlignment)] = [
                ("Leading", .leading),
                ("Center", .center),
                ("Trailing", .trailing),
            ]
            for (title, alignment) in options {
                let item = NSMenuItem(
                    title: title,
                    action: #selector(applyAttachmentMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.state = attachment.alignment == alignment ? .on : .off
                item.representedObject = WiskAttachmentMenuPayload(
                    attachmentID: attachment.id,
                    action: .alignment(alignment)
                )
                submenu.addItem(item)
            }
            let root = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
            root.submenu = submenu
            menu.insertItem(root, at: insertAt)
            insertAt += 1
        }
        if menu.item(withTitle: "Edit Name and Alt Text") == nil {
            let item = NSMenuItem(
                title: "Edit Name and Alt Text",
                action: #selector(applyAttachmentMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = WiskAttachmentMenuPayload(
                attachmentID: attachment.id,
                action: .editDetails
            )
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        let previewTitle = attachment.isPreviewVisible ? "Hide Preview" : "Show Preview"
        if menu.item(withTitle: previewTitle) == nil {
            let item = NSMenuItem(
                title: previewTitle,
                action: #selector(applyAttachmentMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = WiskAttachmentMenuPayload(
                attachmentID: attachment.id,
                action: .previewVisible(!attachment.isPreviewVisible)
            )
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        if insertAt > 0, menu.item(at: insertAt)?.isSeparatorItem != true {
            menu.insertItem(.separator(), at: insertAt)
        }
    }

    @objc private func applyAttachmentMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? WiskAttachmentMenuPayload else { return }
        onAttachmentAction?(payload.attachmentID, payload.action)
    }

    private func imageHit(at point: NSPoint) -> (attachment: NoteAttachment, index: Int, rect: CGRect)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let rawIndex = characterIndexForInsertion(at: point)
        let attachments = imageAttachmentsProvider()
        let candidates = [rawIndex, max(rawIndex - 1, 0)]
        for index in candidates {
            guard let attachment = wiskImageAttachment(at: index, in: storage, attachments: attachments),
                  let rect = wiskGlyphRect(in: self, characterIndex: index),
                  rect.insetBy(dx: -4, dy: -4).contains(point) else {
                continue
            }
            return (attachment, index, rect)
        }
        return nil
    }
}

private struct PlatformRichMarkdownTextView: NSViewRepresentable {
    @Binding var markdownText: String
    @Binding var selectedMarkdownRange: Range<String.Index>?

    let attachments: [NoteAttachment]
    let fontSelection: WiskEditorFontSelection
    let baseFontSize: CGFloat
    let isEditable: Bool
    // Unused on macOS (Mac sizing is NSScrollView-based); kept so the shared
    // wrapper can pass it to both platform implementations.
    var minHeight: CGFloat? = nil
    let showSourceMarkers: Bool
    let searchHighlightText: String
    let contentGutter: CGFloat
    let wikiLinkTitles: [String]
    let jumpToSourceRange: NSRange?
    var foldedSourceLocations: Binding<Set<Int>>
    let documentIdentity: UUID?
    let accessibilityIdentifier: String
    let onFocusChange: ((Bool) -> Void)?
    let onOpenWikiLink: ((String) -> Void)?
    let onJumpHandled: (() -> Void)?
    let onWikiQueryChanged: ((String?) -> Void)?
    let onWikiCaretOffset: ((CGSize) -> Void)?
    let onMarkerCaret: ((Int?) -> Void)?
    let onAttachmentDisplayWidthChange: (UUID, Double?) -> Void
    let onAttachmentAction: (UUID, WiskAttachmentEditorAction) -> Void
    let onPasteImage: (() -> Void)?
    let bodyFocusRequestID: UUID?
    let onBodyFocusHandled: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        Self.pinOverlayScrollerToTrailingEdge(scrollView)
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)

        let textView = WiskMarkdownNSTextView(usingTextLayoutManager: true)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        // Wisk stores markdown source. Smart quotes/dashes/text replacement
        // follow the user's macOS System Settings when left unpinned and
        // silently rewrite the note source ('x' → 'x', "-" → "-"), and any
        // delayed substitution pass editing outside the coordinator pipeline
        // desyncs the visible text until the next keystroke re-render.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.textContainerInset = NSSize(width: contentGutter, height: 0)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.typingAttributes = WiskRichMarkdownDocument.typingAttributes(
            headingLevel: nil,
            fontSelection: fontSelection,
            baseFontSize: baseFontSize
        )
        textView.configureImageResize()
        textView.onToggleChecklist = { [weak coordinator = context.coordinator, weak textView] index in
            guard let textView else { return }
            coordinator?.toggleChecklist(atVisibleLocation: index, textView: textView)
        }
        textView.onAttachmentDisplayWidthChange = { [weak coordinator = context.coordinator] id, width in
            coordinator?.parent.onAttachmentDisplayWidthChange(id, width)
        }
        textView.onAttachmentAction = { [weak coordinator = context.coordinator] id, action in
            coordinator?.parent.onAttachmentAction(id, action)
        }
        textView.onOpenWikiLink = { [weak coordinator = context.coordinator] target in
            coordinator?.parent.onOpenWikiLink?(target)
        }
        textView.imageAttachmentsProvider = { [weak coordinator = context.coordinator] in
            coordinator?.parent.attachments ?? []
        }
        textView.onApplyFormatting = { [weak coordinator = context.coordinator, weak textView] request in
            guard let textView else { return }
            coordinator?.applyFormatting(request, textView: textView)
        }
        textView.markCaretUserInitiated = { [weak coordinator = context.coordinator] in
            coordinator?.caretChangeIsUserInitiated = true
        }
        textView.markSelectionFromMouse = { [weak coordinator = context.coordinator] in
            coordinator?.selectionChangeFromMouse = true
        }
        textView.onCollapseMultiCursor = { [weak coordinator = context.coordinator] in
            coordinator?.selectedSourceRanges = []
            coordinator?.lastAddedVisibleRange = nil
        }
        textView.commitCaret = { [weak coordinator = context.coordinator, weak textView] range in
            guard let textView else { return }
            coordinator?.captureEditingCaret(range, in: textView)
        }
        textView.snapshotEditingCaret = { [weak coordinator = context.coordinator, weak textView] range in
            guard let textView else { return }
            coordinator?.captureEditingCaret(range, in: textView)
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPasteImage?()
        }
        textView.onMultiCursorCommand = { [weak coordinator = context.coordinator, weak textView] command in
            guard let textView else { return }
            coordinator?.handleMultiCursorCommand(command, textView: textView)
        }
        textView.onDoCommand = { [weak coordinator = context.coordinator, weak textView] selector in
            guard let coordinator, let textView else { return false }
            return coordinator.textView(textView, doCommandBy: selector)
        }
        textView.observeEditorCommands()
        textView.onContainerWidthCommitted = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.refreshLayoutIfNeeded(in: textView)
            textView.refreshImageResizeChromeIfSelected()
        }
        scrollView.documentView = textView
        context.coordinator.observeFrame(of: textView)
        context.coordinator.lastDocumentIdentity = documentIdentity
        context.coordinator.lastMarkdownText = markdownText
        if markdownText.isEmpty == false || documentIdentity == nil {
            context.coordinator.openDocument(
                markdown: markdownText,
                identity: documentIdentity,
                in: textView,
                isIdentityChange: false
            )
        }
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let markdownView = scrollView.documentView as? WiskMarkdownNSTextView {
            markdownView.cancelDeferredWidthCommit()
            coordinator.saveSession(from: markdownView)
        } else if let textView = scrollView.documentView as? NSTextView {
            coordinator.saveSession(from: textView)
        }
        coordinator.cancelDeferredRestyle()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        Self.pinOverlayScrollerToTrailingEdge(scrollView)
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let nextInset = NSSize(width: contentGutter, height: 0)
        let gutterChanged = textView.textContainerInset != nextInset
        textView.textContainerInset = nextInset
        textView.isEditable = isEditable
        if let markdownView = textView as? WiskMarkdownNSTextView {
            markdownView.onAttachmentAction = onAttachmentAction
            markdownView.onOpenWikiLink = onOpenWikiLink
            markdownView.onPasteImage = onPasteImage
            markdownView.onMultiCursorCommand = { [weak coordinator = context.coordinator, weak textView] command in
                guard let textView else { return }
                coordinator?.handleMultiCursorCommand(command, textView: textView)
            }
            markdownView.snapshotEditingCaret = { [weak coordinator = context.coordinator, weak textView] range in
                guard let textView else { return }
                coordinator?.captureEditingCaret(range, in: textView)
            }
        }
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        if context.coordinator.isApplyingSourceEdit {
            context.coordinator.handleBodyFocusRequestIfNeeded(in: textView)
            return
        }
        let identityChanged = documentIdentity != nil
            && context.coordinator.lastDocumentIdentity != documentIdentity
        let isDocumentReplacement = WiskEditorOpenPath.isDocumentReplacement(
            previousMarkdown: context.coordinator.lastMarkdownText,
            nextMarkdown: markdownText,
            identityChanged: identityChanged
        )
        if isDocumentReplacement {
            context.coordinator.openDocument(
                markdown: markdownText,
                identity: documentIdentity,
                in: textView,
                isIdentityChange: identityChanged
            )
        } else if context.coordinator.lastMarkdownText != markdownText
            || context.coordinator.lastAttachmentFingerprint != wiskAttachmentRenderFingerprint(attachments)
            || context.coordinator.lastShowSourceMarkers != showSourceMarkers
            || context.coordinator.lastFoldedLocations != foldedSourceLocations.wrappedValue {
            context.coordinator.cancelDeferredRestyle()
            context.coordinator.applyMarkdownText(markdownText, to: textView)
        } else if context.coordinator.lastSearchHighlightText != searchHighlightText {
            context.coordinator.restyleSearchHighlights(in: textView, shouldScroll: true)
        } else if (textView as? WiskMarkdownNSTextView)?.isDeferringContainerWidth != true {
            context.coordinator.refreshLayoutIfNeeded(in: textView)
        }
        context.coordinator.lastDocumentIdentity = documentIdentity
        context.coordinator.handleJumpIfNeeded(in: textView)
        if gutterChanged, (textView as? WiskMarkdownNSTextView)?.isDeferringContainerWidth != true {
            context.coordinator.refreshLayoutIfNeeded(in: textView)
        }
        context.coordinator.handleBodyFocusRequestIfNeeded(in: textView)
    }

    private static func pinOverlayScrollerToTrailingEdge(_ scrollView: NSScrollView) {
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.scrollerStyle = .overlay
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlatformRichMarkdownTextView
        var isApplyingProgrammaticUpdate = false
        var isApplyingSourceEdit = false
        var lastMarkdownText = ""
        var lastAttachmentFingerprint = ""
        var lastShowSourceMarkers = false
        var lastSearchHighlightText = ""
        var lastScrolledSearchText = ""
        var lastScrolledSearchIdentity: UUID?
        var lastFoldedLocations = Set<Int>()
        var lastAvailableWidth: CGFloat = 0
        var pendingEditedRange: NSRange?
        /// Set while the native marked-text commit proceeds with undo
        /// registration disabled, so the framework does not record its own
        /// undo entry on top of the coordinator's source-level record.
        private var nativeUndoDisabledForMarkedCommit = false
        var lastFocusedVisibleRange = NSRange(location: 0, length: 0)
        var editingCaretSnapshot: NSRange?
        var caretChangeIsUserInitiated = false
        var selectionChangeFromMouse = false
        var isApplyingMultiCursor = false
        var cachedParsedSource: String?
        var cachedDocument: WiskMarkdownDocument?
        var lastDocumentIdentity: UUID?
        var lastSourceCaretUTF16: Int?
        var selectedSourceRanges: [NSRange] = []
        var lastAddedVisibleRange: NSRange?
        var lastConsumedBodyFocusRequestID: UUID?
        var keepEditorFirstResponder = false
        weak var boundTextView: NSTextView?
        #if DEBUG
        weak var sourceProbe: NSTextField?
        #endif
        private var frameObserver: NSObjectProtocol?
        private var restyleTask: Task<Void, Never>?
        private var fillInStyleTask: Task<Void, Never>?
        private var restyleGeneration = 0
        private var pendingCaretUTF16: Int?
        private var pendingScrollFraction: CGFloat?

        init(parent: PlatformRichMarkdownTextView) {
            self.parent = parent
        }

        func prepareForDocumentIdentityChange(in textView: NSTextView) {
            saveSession(from: textView)
            cancelDeferredRestyle()
            textView.undoManager?.removeAllActions()
            editingCaretSnapshot = nil
            lastFocusedVisibleRange = NSRange(location: 0, length: 0)
            pendingEditedRange = nil
            caretChangeIsUserInitiated = false
            cachedParsedSource = nil
            cachedDocument = nil
            keepEditorFirstResponder = false
            parent.selectedMarkdownRange = nil
            selectedSourceRanges = []
            lastAddedVisibleRange = nil
            (textView as? WiskMarkdownNSTextView)?.extraInsertionPoints = []
            rememberSourceCaret(nil)
        }

        func shouldScrollToFirstSearchMatch() -> Bool {
            lastScrolledSearchText != parent.searchHighlightText
                || lastScrolledSearchIdentity != (lastDocumentIdentity ?? parent.documentIdentity)
        }

        func restyleSearchHighlights(in textView: NSTextView, shouldScroll: Bool) {
            guard let storage = textView.textStorage else { return }
            let wasApplying = isApplyingProgrammaticUpdate
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = wasApplying }
            storage.beginEditing()
            let firstMatch = WiskRichMarkdownDocument.applySearchHighlights(
                to: storage,
                searchText: parent.searchHighlightText
            )
            storage.endEditing()
            lastSearchHighlightText = parent.searchHighlightText
            if shouldScroll {
                lastScrolledSearchIdentity = lastDocumentIdentity ?? parent.documentIdentity
                lastScrolledSearchText = parent.searchHighlightText
                if let firstMatch {
                    textView.scrollRangeToVisible(firstMatch)
                }
            }
        }

        func openDocument(
            markdown: String,
            identity: UUID?,
            in textView: NSTextView,
            isIdentityChange: Bool
        ) {
            guard let identity else {
                applyMarkdownText(markdown, to: textView, eager: false)
                return
            }
            let switchState = WiskEditorSignposts.signposter.beginInterval("Switch")
            let started = ContinuousClock.now
            let utf16Count = (markdown as NSString).length
            var cacheResult = "miss"
            var loggedDelay: UInt64 = 0
            var loggedSwitched = false
            defer {
                WiskEditorSignposts.signposter.endInterval("Switch", switchState)
                let elapsedMs = (ContinuousClock.now - started) / Duration.milliseconds(1)
                WiskEditorSignposts.log.info(
                    "Switch \(cacheResult, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) utf16=\(utf16Count, privacy: .public) delayNs=\(loggedDelay, privacy: .public) switched=\(loggedSwitched, privacy: .public) id=\(identity.uuidString, privacy: .public)"
                )
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let identitySwitched = identity != WiskEditorSwitchCadence.lastOpenedID
            WiskEditorSwitchCadence.lastOpenedID = identity
            let delay: UInt64
            if identitySwitched {
                delay = WiskEditorRestylePolicy.delayNanoseconds(
                    sincePreviousIdentityChange: WiskEditorSwitchCadence.lastIdentityChangeUptime,
                    now: now
                )
                WiskEditorSwitchCadence.lastIdentityChangeUptime = now
            } else {
                delay = 0
            }
            loggedDelay = delay
            loggedSwitched = identitySwitched
            if isIdentityChange {
                prepareForDocumentIdentityChange(in: textView)
            }

            lastDocumentIdentity = identity

            if let snapshot = WiskEditorSessionCache.shared.snapshot(id: identity),
               snapshot.source == markdown,
               snapshot.showSourceMarkers == parent.showSourceMarkers {
                parent.foldedSourceLocations.wrappedValue = snapshot.foldedLocations
                lastFoldedLocations = snapshot.foldedLocations
                pendingCaretUTF16 = snapshot.caretUTF16
                pendingScrollFraction = snapshot.scrollFraction
                cachedParsedSource = snapshot.source
                cachedDocument = snapshot.document
                if let styled = snapshot.styled {
                    applyCachedStyled(styled, markdown: markdown, document: snapshot.document, to: textView)
                    cacheResult = "hit"
                    WiskEditorSignposts.cacheHit(utf16Count: utf16Count)
                    return
                }
            } else if isIdentityChange {
                pendingCaretUTF16 = 0
                pendingScrollFraction = 0
            }

            WiskEditorSignposts.cacheMiss(utf16Count: utf16Count, delayNanoseconds: delay)
            let paintPlainFirst = WiskEditorOpenPath.shouldPaintPlainFirst(utf16Count: utf16Count) || delay > 0
            if paintPlainFirst {
                applyPlainMarkdownText(markdown, to: textView)
                scheduleDeferredRestyle(
                    of: markdown,
                    identity: identity,
                    in: textView,
                    delayNanoseconds: delay
                )
            } else {
                applyMarkdownText(markdown, to: textView, eager: false)
            }
        }

        func saveSession(from textView: NSTextView) {
            guard let id = lastDocumentIdentity else { return }
            let source = lastMarkdownText
            let existingSource = WiskEditorSessionCache.shared.snapshot(id: id)?.source
            guard WiskEditorOpenPath.shouldReplaceCachedSession(
                withSource: source,
                existingSource: existingSource
            ) else { return }
            let document: WiskMarkdownDocument
            if let cachedDocument {
                document = cachedDocument
            } else if let cached = WiskEditorSessionCache.shared.snapshot(id: id), cached.source == source {
                document = cached.document
            } else {
                return
            }
            let styled: NSAttributedString?
            if let storage = textView.textStorage,
               storage.length > 0,
               storage.length <= WiskEditorPerformance.styledCacheMaxUTF16 {
                styled = WiskRichMarkdownDocument.copyWithoutSearchHighlights(
                    NSAttributedString(attributedString: storage)
                )
            } else {
                styled = nil
            }
            WiskEditorSessionCache.shared.store(
                id: id,
                snapshot: WiskEditorSessionSnapshot(
                    source: source,
                    document: document,
                    caretUTF16: textView.selectedRange().location,
                    scrollFraction: scrollFraction(of: textView),
                    foldedLocations: lastFoldedLocations,
                    showSourceMarkers: lastShowSourceMarkers,
                    styled: styled
                )
            )
        }

        func cancelDeferredRestyle() {
            restyleGeneration += 1
            restyleTask?.cancel()
            restyleTask = nil
            fillInStyleTask?.cancel()
            fillInStyleTask = nil
        }

        func scheduleDeferredRestyle(
            of markdown: String,
            identity: UUID?,
            in textView: NSTextView,
            delayNanoseconds: UInt64 = WiskEditorPerformance.restyleDebounceNanoseconds
        ) {
            restyleGeneration += 1
            let generation = restyleGeneration
            restyleTask?.cancel()
            fillInStyleTask?.cancel()
            let showMarkers = parent.showSourceMarkers
            restyleTask = Task { @MainActor [weak self, weak textView] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard let self, let textView else { return }
                guard !Task.isCancelled, self.restyleGeneration == generation else { return }
                guard self.lastDocumentIdentity == identity else { return }
                guard self.lastMarkdownText == markdown else { return }

                if let identity,
                   let styled = WiskEditorSessionCache.shared.styled(
                    id: identity,
                    source: markdown,
                    showSourceMarkers: showMarkers,
                    foldedLocations: []
                   ),
                   let document = WiskEditorSessionCache.shared.document(
                    id: identity,
                    source: markdown,
                    showSourceMarkers: showMarkers,
                    foldedLocations: []
                   ) {
                    self.cachedParsedSource = markdown
                    self.cachedDocument = document
                    self.applyCachedStyled(styled, markdown: markdown, document: document, to: textView)
                    return
                }

                let document: WiskMarkdownDocument
                if let identity,
                   let cached = WiskEditorSessionCache.shared.document(
                    id: identity,
                    source: markdown,
                    showSourceMarkers: showMarkers,
                    foldedLocations: []
                   ) {
                    document = cached
                } else {
                    document = await Task.detached(priority: .userInitiated) {
                        WiskMarkdownDocumentEngine.parse(markdown)
                    }.value
                }
                guard !Task.isCancelled, self.restyleGeneration == generation else { return }
                guard self.lastDocumentIdentity == identity, self.lastMarkdownText == markdown else { return }
                self.cachedParsedSource = markdown
                self.cachedDocument = document
                self.applyMarkdownText(markdown, to: textView, eager: true)
            }
        }

        func applyPlainMarkdownText(_ markdown: String, to textView: NSTextView) {
            boundTextView = textView
            let previousResponder = textView.window?.firstResponder
            isApplyingProgrammaticUpdate = true
            let attributes = WiskRichMarkdownDocument.typingAttributes(
                headingLevel: nil,
                fontSelection: parent.fontSelection,
                baseFontSize: parent.baseFontSize
            )
            WiskEditorSignposts.interval("PlainText") {
                textView.textStorage?.setAttributedString(NSAttributedString(string: markdown, attributes: attributes))
            }
            textView.typingAttributes = attributes
            lastMarkdownText = markdown
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = parent.foldedSourceLocations.wrappedValue
            isApplyingProgrammaticUpdate = false
            #if DEBUG
            publishSourceProbe(markdown, in: textView)
            #endif
            restoreFirstResponderIfStolen(from: previousResponder, in: textView)
            restyleSearchHighlights(in: textView, shouldScroll: false)
        }

        func parsedDocument(for source: String, dirtySourceRange: NSRange? = nil) -> WiskMarkdownDocument {
            WiskMarkdownParseCache.document(
                for: source,
                cachedSource: &cachedParsedSource,
                cachedDocument: &cachedDocument,
                dirtySourceRange: dirtySourceRange
            )
        }

        deinit {
            restyleTask?.cancel()
            fillInStyleTask?.cancel()
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }

        @discardableResult
        func rememberVisibleRange(_ range: NSRange, in textView: NSTextView, isUserInitiated: Bool) -> Bool {
            guard range.location != NSNotFound else { return false }
            let text = textView.string
            if WiskRichMarkdownDocument.shouldPreserveRememberedVisibleRange(
                incoming: range,
                remembered: lastFocusedVisibleRange,
                text: text,
                isUserInitiated: isUserInitiated
            ) {
                return false
            }
            lastFocusedVisibleRange = range
            if WiskRichMarkdownDocument.shouldSkipEditingCaretSnapshotUpdate(
                incoming: range,
                snapshot: editingCaretSnapshot,
                text: text,
                isUserInitiated: isUserInitiated
            ) == false {
                editingCaretSnapshot = range
            }
            WiskActiveMarkdownEditor.claim(textView)
            return true
        }

        func captureEditingCaret(_ range: NSRange, in textView: NSTextView) {
            guard range.location != NSNotFound else { return }
            editingCaretSnapshot = range
            lastFocusedVisibleRange = range
            WiskActiveMarkdownEditor.claim(textView)
        }

        func liveVisibleRanges(in textView: NSTextView) -> [NSRange] {
            let textLength = (textView.string as NSString).length
            if let markdownView = textView as? WiskMarkdownNSTextView {
                let extras = WiskEditorMultiCursor.normalizedSelectionRanges(
                    markdownView.extraInsertionPoints,
                    textLength: textLength
                )
                if extras.count >= 2 {
                    return extras
                }
            }
            let fromLayout = WiskEditorMultiCursor.normalizedSelectionRanges(
                WiskTextKitSelections.nsRanges(from: textView),
                textLength: textLength
            )
            if fromLayout.count >= 2 {
                return fromLayout
            }
            return WiskEditorMultiCursor.normalizedSelectionRanges(
                textView.selectedRanges.compactMap { ($0 as? NSValue)?.rangeValue },
                textLength: textLength
            )
        }

        func commitVisibleRanges(_ ranges: [NSRange], in textView: NSTextView) {
            let normalized = WiskEditorMultiCursor.normalizedSelectionRanges(
                ranges,
                textLength: (textView.string as NSString).length
            )
            guard !normalized.isEmpty else { return }
            let markdownView = textView as? WiskMarkdownNSTextView
            let insertionPointsOnly = normalized.count >= 2 && normalized.allSatisfy { $0.length == 0 }
            if insertionPointsOnly {
                markdownView?.extraInsertionPoints = normalized
                textView.setSelectedRange(normalized[0])
                textView.updateInsertionPointStateAndRestartTimer(true)
                return
            }
            markdownView?.extraInsertionPoints = []
            textView.setSelectedRanges(
                normalized.map { NSValue(range: $0) },
                affinity: .downstream,
                stillSelecting: false
            )
        }

        func restoreSelections(
            sourceRanges: [NSRange],
            primary: NSRange,
            in textView: NSTextView,
            markdown: String,
            document: WiskMarkdownDocument,
            folds: Set<Int>
        ) {
            let textLength = textView.string.utf16.count
            if sourceRanges.count >= 2 {
                let visible = sourceRanges.map { sourceRange in
                    WiskRichMarkdownDocument.visibleSelection(
                        forMarkdownRange: Range(sourceRange, in: markdown),
                        in: markdown,
                        fallback: primary,
                        textLength: textLength,
                        showSourceMarkers: parent.showSourceMarkers,
                        document: document,
                        foldedLocations: folds
                    )
                }
                let normalized = WiskEditorMultiCursor.normalizedSelectionRanges(visible, textLength: textLength)
                if normalized.count >= 2 {
                    commitVisibleRanges(normalized, in: textView)
                    return
                }
            }
            (textView as? WiskMarkdownNSTextView)?.extraInsertionPoints = []
            textView.setSelectedRanges(
                [NSValue(range: primary)],
                affinity: .downstream,
                stillSelecting: false
            )
        }

        func applyVisibleRanges(_ ranges: [NSRange], in textView: NSTextView, scrollTo: NSRange? = nil) {
            caretChangeIsUserInitiated = true
            isApplyingMultiCursor = true
            defer { isApplyingMultiCursor = false }
            let normalized = WiskEditorMultiCursor.normalizedSelectionRanges(
                ranges,
                textLength: (textView.string as NSString).length
            )
            guard !normalized.isEmpty else { return }
            commitVisibleRanges(normalized, in: textView)
            let focus = scrollTo ?? normalized.last
            if let focus {
                textView.scrollRangeToVisible(focus)
                captureEditingCaret(focus, in: textView)
            }
            syncSourceRanges(from: normalized)
        }

        func syncSourceRanges(from visibleRanges: [NSRange]) {
            let mapped = mappedSourceRanges(from: visibleRanges)
            selectedSourceRanges = mapped ?? []
            if let primary = visibleRanges.last,
               let markdown = mappedSelectedMarkdownRange(from: primary) {
                parent.selectedMarkdownRange = markdown
            }
            if selectedSourceRanges.count < 2 {
                selectedSourceRanges = []
                lastAddedVisibleRange = nil
            }
        }

        func mappedSourceRanges(from visibleRanges: [NSRange]) -> [NSRange]? {
            let document = parsedDocument(for: parent.markdownText)
            var sourceRanges: [NSRange] = []
            sourceRanges.reserveCapacity(visibleRanges.count)
            for visible in visibleRanges {
                guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                    visibleRange: visible,
                    source: parent.markdownText,
                    showSourceMarkers: parent.showSourceMarkers,
                    document: document,
                    foldedLocations: parent.foldedSourceLocations.wrappedValue
                ) else {
                    return nil
                }
                sourceRanges.append(sourceRange)
            }
            return sourceRanges
        }

        func handleMultiCursorCommand(_ command: WiskEditorMultiCursor.Command, textView: NSTextView) {
            guard parent.isEditable else { return }
            let current = liveVisibleRanges(in: textView)
            let text = textView.string
            switch command {
            case .splitIntoLines:
                let fragments = WiskTextKitSelections.visualLineFragments(
                    in: textView,
                    intersecting: textView.selectedRange()
                )
                guard let ranges = WiskEditorMultiCursor.splitIntoLines(
                    selection: textView.selectedRange(),
                    in: text,
                    fragmentRanges: fragments
                ) else { return }
                lastAddedVisibleRange = ranges.last
                applyVisibleRanges(ranges, in: textView)
            case .selectNextOccurrence:
                guard let ranges = WiskEditorMultiCursor.selectNextOccurrence(
                    ranges: current,
                    in: text,
                    searchAfter: lastAddedVisibleRange
                ) else { return }
                let added = ranges.first { candidate in
                    current.contains(where: { NSEqualRanges($0, candidate) }) == false
                }
                lastAddedVisibleRange = added ?? ranges.last
                applyVisibleRanges(ranges, in: textView, scrollTo: added)
            case .selectAllOccurrences:
                guard let ranges = WiskEditorMultiCursor.selectAllOccurrences(ranges: current, in: text) else { return }
                lastAddedVisibleRange = ranges.last
                applyVisibleRanges(ranges, in: textView, scrollTo: ranges.last)
            }
        }

        func observeFrame(of textView: NSTextView) {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            textView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                if let markdownView = textView as? WiskMarkdownNSTextView,
                   markdownView.isDeferringContainerWidth {
                    return
                }
                self.refreshLayoutIfNeeded(in: textView)
            }
        }

        func applyMarkdownText(_ markdown: String, to textView: NSTextView, eager: Bool = false) {
            boundTextView = textView
            let previousResponder = textView.window?.firstResponder
            isApplyingProgrammaticUpdate = true
            let selectedRange = textView.selectedRange()
            let availableWidth = availableWidth(for: textView)
            lastAvailableWidth = availableWidth
            let document = parsedDocument(for: markdown)
            let folds = parent.foldedSourceLocations.wrappedValue
            let caretHint = pendingCaretUTF16 ?? selectedRange.location
            let sourceLength = (markdown as NSString).length
            let eagerRange: NSRange?
            if eager, sourceLength > WiskEditorPerformance.eagerStyleUTF16Window {
                let window = WiskEditorPerformance.eagerStyleUTF16Window
                let start = max(caretHint - window / 2, 0)
                eagerRange = NSRange(location: start, length: min(window, sourceLength - start))
            } else {
                eagerRange = nil
            }
            let attributed = WiskEditorSignposts.interval("AttributedString") {
                WiskRichMarkdownDocument.attributedString(
                    from: markdown,
                    attachments: parent.attachments,
                    fontSelection: parent.fontSelection,
                    baseFontSize: parent.baseFontSize,
                    availableWidth: availableWidth,
                    showSourceMarkers: parent.showSourceMarkers,
                    document: document,
                    foldedLocations: folds,
                    eagerStyleUTF16Range: eagerRange
                )
            }
            WiskEditorSignposts.interval("SetAttributedString") {
                textView.textStorage?.setAttributedString(attributed)
            }
            textView.typingAttributes = WiskRichMarkdownDocument.typingAttributes(
                headingLevel: nil,
                fontSelection: parent.fontSelection,
                baseFontSize: parent.baseFontSize
            )
            let restoredSelection = WiskRichMarkdownDocument.visibleSelection(
                forMarkdownRange: parent.selectedMarkdownRange,
                in: markdown,
                fallback: WiskRichMarkdownDocument.visibleRangeForFormatting(
                    snapshot: editingCaretSnapshot,
                    remembered: lastFocusedVisibleRange,
                    live: NSRange(location: caretHint, length: 0),
                    textLength: textView.string.utf16.count
                ),
                textLength: textView.string.utf16.count,
                showSourceMarkers: parent.showSourceMarkers,
                document: document,
                foldedLocations: folds
            )
            restoreSelections(
                sourceRanges: selectedSourceRanges,
                primary: restoredSelection,
                in: textView,
                markdown: markdown,
                document: document,
                folds: folds
            )
            restorePendingScroll(in: textView)
            lastMarkdownText = markdown
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = folds
            isApplyingProgrammaticUpdate = false
            #if DEBUG
            publishSourceProbe(markdown, in: textView)
            #endif
            (textView as? WiskMarkdownNSTextView)?.refreshImageResizeChrome()
            publishWikiCaret(in: textView)
            if eagerRange != nil {
                scheduleFillInStyle(of: markdown, identity: lastDocumentIdentity, in: textView)
            } else if let identity = lastDocumentIdentity ?? parent.documentIdentity {
                storeStyledSession(id: identity, markdown: markdown, document: document, in: textView)
            }
            restoreFirstResponderIfStolen(from: previousResponder, in: textView)
            restyleSearchHighlights(in: textView, shouldScroll: shouldScrollToFirstSearchMatch())
        }

        func restoreFirstResponderIfStolen(from previous: NSResponder?, in textView: NSTextView) {
            if keepEditorFirstResponder || parent.bodyFocusRequestID != nil { return }
            guard let window = textView.window, let previous, previous !== textView else { return }
            if window.firstResponder === textView {
                window.makeFirstResponder(previous)
            }
        }

        func handleBodyFocusRequestIfNeeded(in textView: NSTextView) {
            guard let requestID = parent.bodyFocusRequestID else { return }
            guard lastConsumedBodyFocusRequestID != requestID else { return }
            lastConsumedBodyFocusRequestID = requestID
            guard parent.isEditable else {
                parent.onBodyFocusHandled?()
                return
            }
            keepEditorFirstResponder = true
            let identity = parent.documentIdentity
            Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self, let textView else { return }
                guard self.keepEditorFirstResponder else { return }
                guard self.parent.documentIdentity == identity else { return }
                guard self.lastConsumedBodyFocusRequestID == requestID else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                self.parent.onBodyFocusHandled?()
            }
        }

        func applyCachedStyled(
            _ styled: NSAttributedString,
            markdown: String,
            document: WiskMarkdownDocument,
            to textView: NSTextView
        ) {
            boundTextView = textView
            let previousResponder = textView.window?.firstResponder
            isApplyingProgrammaticUpdate = true
            WiskEditorSignposts.interval("SetAttributedString") {
                textView.textStorage?.setAttributedString(styled)
            }
            textView.typingAttributes = WiskRichMarkdownDocument.typingAttributes(
                headingLevel: nil,
                fontSelection: parent.fontSelection,
                baseFontSize: parent.baseFontSize
            )
            let caret = pendingCaretUTF16 ?? 0
            let clamped = NSRange(location: min(caret, styled.length), length: 0)
            restoreSelections(
                sourceRanges: selectedSourceRanges,
                primary: clamped,
                in: textView,
                markdown: markdown,
                document: document,
                folds: parent.foldedSourceLocations.wrappedValue
            )
            restorePendingScroll(in: textView)
            lastMarkdownText = markdown
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = parent.foldedSourceLocations.wrappedValue
            cachedParsedSource = markdown
            cachedDocument = document
            isApplyingProgrammaticUpdate = false
            #if DEBUG
            publishSourceProbe(markdown, in: textView)
            #endif
            (textView as? WiskMarkdownNSTextView)?.refreshImageResizeChrome()
            publishWikiCaret(in: textView)
            restoreFirstResponderIfStolen(from: previousResponder, in: textView)
            restyleSearchHighlights(in: textView, shouldScroll: shouldScrollToFirstSearchMatch())
        }

        func scheduleFillInStyle(of markdown: String, identity: UUID?, in textView: NSTextView) {
            fillInStyleTask?.cancel()
            let generation = restyleGeneration
            fillInStyleTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView else { return }
                guard !Task.isCancelled, self.restyleGeneration == generation else { return }
                guard self.lastDocumentIdentity == identity, self.lastMarkdownText == markdown else { return }
                self.applyMarkdownText(markdown, to: textView, eager: false)
            }
        }

        func storeStyledSession(
            id: UUID,
            markdown: String,
            document: WiskMarkdownDocument,
            in textView: NSTextView
        ) {
            let styled: NSAttributedString?
            if let storage = textView.textStorage,
               storage.length > 0,
               storage.length <= WiskEditorPerformance.styledCacheMaxUTF16 {
                styled = WiskRichMarkdownDocument.copyWithoutSearchHighlights(
                    NSAttributedString(attributedString: storage)
                )
            } else {
                styled = nil
            }
            WiskEditorSessionCache.shared.store(
                id: id,
                snapshot: WiskEditorSessionSnapshot(
                    source: markdown,
                    document: document,
                    caretUTF16: textView.selectedRange().location,
                    scrollFraction: scrollFraction(of: textView),
                    foldedLocations: lastFoldedLocations,
                    showSourceMarkers: lastShowSourceMarkers,
                    styled: styled
                )
            )
        }

        func scrollFraction(of textView: NSTextView) -> CGFloat {
            guard let scrollView = textView.enclosingScrollView else { return 0 }
            let clipHeight = scrollView.contentView.bounds.height
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxScroll = max(documentHeight - clipHeight, 1)
            return min(max(scrollView.contentView.bounds.minY / maxScroll, 0), 1)
        }

        func restorePendingScroll(in textView: NSTextView) {
            guard let fraction = pendingScrollFraction,
                  let scrollView = textView.enclosingScrollView else {
                pendingScrollFraction = nil
                pendingCaretUTF16 = nil
                return
            }
            let clipHeight = scrollView.contentView.bounds.height
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxScroll = max(documentHeight - clipHeight, 0)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: fraction * maxScroll))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            pendingScrollFraction = nil
            pendingCaretUTF16 = nil
        }

        #if DEBUG
        func publishSourceProbe(_ markdown: String, in textView: NSTextView) {
            guard let scrollView = textView.enclosingScrollView else { return }
            let probe: NSTextField
            if let sourceProbe {
                probe = sourceProbe
            } else {
                let created = NSTextField(labelWithString: "")
                created.setAccessibilityIdentifier("wisk.mac.note.bodyMarkdownSource")
                created.setAccessibilityLabel("Markdown source")
                created.isEditable = false
                created.isSelectable = false
                created.isBezeled = false
                created.drawsBackground = false
                created.refusesFirstResponder = true
                created.alphaValue = 0.01
                created.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
                scrollView.addSubview(created)
                sourceProbe = created
                probe = created
            }
            probe.stringValue = markdown.replacingOccurrences(of: "\n", with: "¶")
            probe.setAccessibilityValue(probe.stringValue)
        }
        #endif

        func handleJumpIfNeeded(in textView: NSTextView) {
            guard let target = parent.jumpToSourceRange else { return }
            let document = parsedDocument(for: parent.markdownText)
            let unfolded = WiskMarkdownFolding.unfoldLocations(
                intersecting: target,
                in: document,
                folds: parent.foldedSourceLocations.wrappedValue
            )
            if unfolded != parent.foldedSourceLocations.wrappedValue {
                parent.foldedSourceLocations.wrappedValue = unfolded
            }
            let folds = parent.foldedSourceLocations.wrappedValue
            let visible: NSRange
            if parent.showSourceMarkers {
                visible = target
            } else if let range = Range(target, in: parent.markdownText),
                      let mapped = WiskRichMarkdownDocument.visibleRange(
                        forMarkdownRange: range,
                        in: parent.markdownText,
                        document: document,
                        foldedLocations: folds
                      ) {
                visible = mapped
            } else {
                visible = NSRange(location: 0, length: 0)
            }
            let length = textView.string.utf16.count
            let location = min(max(visible.location, 0), length)
            let selected = NSRange(location: location, length: min(visible.length, max(length - location, 0)))
            textView.setSelectedRange(selected)
            textView.scrollRangeToVisible(selected)
            selectedSourceRanges = []
            lastAddedVisibleRange = nil
            (textView as? WiskMarkdownNSTextView)?.extraInsertionPoints = []
            rememberVisibleRange(selected, in: textView, isUserInitiated: true)
            parent.onJumpHandled?()
        }

        func applySourceEdit(visibleRange: NSRange, replacement: String, textView: NSTextView) -> Bool {
            let document = parsedDocument(for: parent.markdownText)
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: visibleRange,
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: document,
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else { return false }
            unfoldIfNeeded(intersecting: sourceRange)
            let previous = parent.markdownText
            let previousSelection = parent.selectedMarkdownRange
            let mutation: WiskMarkdownMutation?
            if replacement == "\n" {
                mutation = WiskMarkdownDocumentEngine.applyReturn(in: parent.markdownText, sourceRange: sourceRange)
            } else {
                mutation = WiskMarkdownDocumentEngine.replaceSourceRange(
                    in: parent.markdownText,
                    sourceRange: sourceRange,
                    with: replacement
                )
            }
            guard let mutation else { return false }
            registerSourceUndo(previous: previous, previousSelection: previousSelection, textView: textView)
            selectedSourceRanges = []
            lastAddedVisibleRange = nil
            (textView as? WiskMarkdownNSTextView)?.extraInsertionPoints = []
            lastMarkdownText = mutation.source
            isApplyingSourceEdit = true
            defer { isApplyingSourceEdit = false }
            parent.markdownText = mutation.source
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            if !applyIncrementalMutation(
                previous: previous,
                mutation: mutation,
                editedSourceRange: sourceRange,
                replacement: replacement,
                textView: textView
            ) {
                applyMarkdownText(mutation.source, to: textView)
            }
            rememberVisibleRange(textView.selectedRange(), in: textView, isUserInitiated: true)
            publishWikiQuery()
            return true
        }

        func applySourceEdits(visibleRanges: [NSRange], replacements: [String], textView: NSTextView) -> Bool {
            guard visibleRanges.count == replacements.count, visibleRanges.count >= 2 else { return false }
            let document = parsedDocument(for: parent.markdownText)
            var sourceRanges: [NSRange] = []
            sourceRanges.reserveCapacity(visibleRanges.count)
            for visible in visibleRanges {
                guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                    visibleRange: visible,
                    source: parent.markdownText,
                    showSourceMarkers: parent.showSourceMarkers,
                    document: document,
                    foldedLocations: parent.foldedSourceLocations.wrappedValue
                ) else { return false }
                sourceRanges.append(sourceRange)
            }
            return applySourceEdits(sourceRanges: sourceRanges, replacements: replacements, textView: textView)
        }

        func applySourceEdits(sourceRanges: [NSRange], replacements: [String], textView: NSTextView) -> Bool {
            guard sourceRanges.count == replacements.count, sourceRanges.count >= 2 else { return false }
            for sourceRange in sourceRanges {
                unfoldIfNeeded(intersecting: sourceRange)
            }
            let edits = zip(sourceRanges, replacements).map { (range: $0.0, replacement: $0.1) }
            let previous = parent.markdownText
            let previousSelection = parent.selectedMarkdownRange
            guard let result = WiskEditorMultiCursor.applyAscending(
                edits: edits,
                in: previous,
                mutate: { current, range, replacement in
                    let mutation: WiskMarkdownMutation?
                    if replacement == "\n" {
                        mutation = WiskMarkdownDocumentEngine.applyReturn(in: current, sourceRange: range)
                    } else {
                        mutation = WiskMarkdownDocumentEngine.replaceSourceRange(
                            in: current,
                            sourceRange: range,
                            with: replacement
                        )
                    }
                    guard let mutation else { return nil }
                    return (mutation.source, mutation.selectedSourceRange)
                }
            ) else {
                return false
            }
            registerSourceUndo(previous: previous, previousSelection: previousSelection, textView: textView)
            lastMarkdownText = result.text
            isApplyingSourceEdit = true
            defer { isApplyingSourceEdit = false }
            parent.markdownText = result.text
            selectedSourceRanges = result.selectedRanges
            if let primary = result.selectedRanges.last {
                parent.selectedMarkdownRange = Range(primary, in: result.text)
                rememberSourceCaret(primary.location)
            }
            applyMarkdownText(result.text, to: textView)
            if let visiblePrimary = liveVisibleRanges(in: textView).last {
                rememberVisibleRange(visiblePrimary, in: textView, isUserInitiated: true)
            }
            publishWikiQuery()
            return true
        }

        func applyIncrementalMutation(
            previous: String,
            mutation: WiskMarkdownMutation,
            editedSourceRange: NSRange,
            replacement: String,
            textView: NSTextView
        ) -> Bool {
            guard replacement != "\n",
                  selectedSourceRanges.count < 2,
                  parent.foldedSourceLocations.wrappedValue.isEmpty,
                  let storage = textView.textStorage,
                  let edit = WiskRichMarkdownDocument.incrementalLineEdit(
                    previousMarkdown: previous,
                    mutation: mutation,
                    editedSourceRange: editedSourceRange,
                    replacement: replacement,
                    attachments: parent.attachments,
                    fontSelection: parent.fontSelection,
                    baseFontSize: parent.baseFontSize,
                    availableWidth: availableWidth(for: textView),
                    showSourceMarkers: parent.showSourceMarkers,
                    foldedLocations: parent.foldedSourceLocations.wrappedValue,
                    previousDocument: cachedDocument
                  )
            else {
                return false
            }

            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }
            guard WiskRichMarkdownDocument.applyIncrementalLineEdit(edit, to: storage) else {
                return false
            }

            cachedDocument = parsedDocument(for: mutation.source, dirtySourceRange: editedSourceRange)
            lastMarkdownText = mutation.source
            lastAttachmentFingerprint = wiskAttachmentRenderFingerprint(parent.attachments)
            lastShowSourceMarkers = parent.showSourceMarkers
            lastFoldedLocations = parent.foldedSourceLocations.wrappedValue

            let restoredSelection = WiskRichMarkdownDocument.visibleSelection(
                forMarkdownRange: parent.selectedMarkdownRange,
                in: mutation.source,
                fallback: NSRange(location: edit.visibleRange.location + edit.attributedLine.length, length: 0),
                textLength: storage.length,
                showSourceMarkers: parent.showSourceMarkers,
                document: cachedDocument,
                foldedLocations: lastFoldedLocations
            )
            textView.setSelectedRanges(
                [NSValue(range: restoredSelection)],
                affinity: .downstream,
                stillSelecting: false
            )
            (textView as? WiskMarkdownNSTextView)?.refreshImageResizeChrome()
            publishWikiCaret(in: textView)
            restyleSearchHighlights(in: textView, shouldScroll: false)
            return true
        }

        func registerSourceUndo(
            previous: String,
            previousSelection: Range<String.Index>?,
            previousSourceRanges: [NSRange]? = nil,
            textView: NSTextView
        ) {
            let storedPreviousRanges = previousSourceRanges ?? selectedSourceRanges
            textView.undoManager?.registerUndo(withTarget: self) { coordinator in
                let current = coordinator.parent.markdownText
                let currentSelection = coordinator.parent.selectedMarkdownRange
                let currentRanges = coordinator.selectedSourceRanges
                coordinator.parent.markdownText = previous
                coordinator.parent.selectedMarkdownRange = previousSelection
                coordinator.selectedSourceRanges = storedPreviousRanges
                coordinator.applyMarkdownText(previous, to: textView)
                coordinator.registerSourceUndo(
                    previous: current,
                    previousSelection: currentSelection,
                    previousSourceRanges: currentRanges,
                    textView: textView
                )
            }
        }

        func publishWikiQuery() {
            let length = (parent.markdownText as NSString).length
            guard let caret = lastSourceCaretUTF16, caret >= 0, caret <= length else {
                parent.onWikiQueryChanged?(nil)
                return
            }
            parent.onWikiQueryChanged?(WiskMarkdownDocumentEngine.wikiLinkPartial(in: parent.markdownText, sourceCaret: caret))
        }

        func rememberSourceCaret(_ location: Int?) {
            lastSourceCaretUTF16 = location
            parent.onMarkerCaret?(location)
        }

        func publishWikiCaret(in textView: NSTextView) {
            let range = textView.selectedRange()
            guard range.location != NSNotFound else {
                parent.onWikiCaretOffset?(.zero)
                return
            }
            var actualRange = NSRange(location: 0, length: 0)
            let rect = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: max(range.length, 1)), actualRange: &actualRange)
            let local = textView.convert(rect, from: nil)
            parent.onWikiCaretOffset?(CGSize(width: max(local.minX, 8), height: max(local.maxY, 8)))
        }

        func unfoldIfNeeded(intersecting sourceRange: NSRange) {
            let document = parsedDocument(for: parent.markdownText)
            let unfolded = WiskMarkdownFolding.unfoldLocations(
                intersecting: sourceRange,
                in: document,
                folds: parent.foldedSourceLocations.wrappedValue
            )
            if unfolded != parent.foldedSourceLocations.wrappedValue {
                parent.foldedSourceLocations.wrappedValue = unfolded
            }
        }

        func applyTableMutation(_ mutation: WiskMarkdownMutation, textView: NSTextView) {
            registerSourceUndo(
                previous: parent.markdownText,
                previousSelection: parent.selectedMarkdownRange,
                textView: textView
            )
            parent.markdownText = mutation.source
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            selectedSourceRanges = []
            lastAddedVisibleRange = nil
            rememberSourceCaret(mutation.selectedSourceRange.location)
            applyMarkdownText(mutation.source, to: textView)
            rememberVisibleRange(textView.selectedRange(), in: textView, isUserInitiated: true)
        }

        func toggleChecklist(atVisibleLocation location: Int, textView: NSTextView) {
            guard parent.isEditable else { return }
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: NSRange(location: location, length: 0),
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: parsedDocument(for: parent.markdownText),
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else { return }
            guard let mutation = WiskMarkdownDocumentEngine.toggleChecklist(
                in: parent.markdownText,
                sourceLocation: sourceRange.location
            ) else { return }
            applyTableMutation(mutation, textView: textView)
        }

        func mappedSelectedMarkdownRange(from visibleRange: NSRange) -> Range<String.Index>? {
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: visibleRange,
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: parsedDocument(for: parent.markdownText),
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else {
                rememberSourceCaret(nil)
                return nil
            }
            rememberSourceCaret(sourceRange.location)
            return Range(sourceRange, in: parent.markdownText)
        }

        func applyFormatting(_ request: WiskMarkdownFormattingRequest, textView: NSTextView) {
            caretChangeIsUserInitiated = false
            let liveRanges = liveVisibleRanges(in: textView)
            if liveRanges.count >= 2 {
                applyFormatting(request.action, to: liveRanges, request: request, textView: textView)
                return
            }
            if selectedSourceRanges.count >= 2 {
                let document = parsedDocument(for: parent.markdownText)
                let folds = parent.foldedSourceLocations.wrappedValue
                let textLength = (textView.string as NSString).length
                let mapped = selectedSourceRanges.map { sourceRange in
                    WiskRichMarkdownDocument.visibleSelection(
                        forMarkdownRange: Range(sourceRange, in: parent.markdownText),
                        in: parent.markdownText,
                        fallback: textView.selectedRange(),
                        textLength: textLength,
                        showSourceMarkers: parent.showSourceMarkers,
                        document: document,
                        foldedLocations: folds
                    )
                }
                applyFormatting(request.action, to: mapped, request: request, textView: textView)
                return
            }
            let textLength = (textView.string as NSString).length
            let visibleRange = WiskRichMarkdownDocument.visibleRangeForFormatting(
                snapshot: editingCaretSnapshot,
                remembered: lastFocusedVisibleRange,
                live: textView.selectedRange(),
                textLength: textLength
            )
            guard let mutation = WiskRichMarkdownDocument.applyFormatting(
                request.action,
                to: parent.markdownText,
                visibleRange: visibleRange,
                visibleText: textView.string
            ) else { return }
            request.handled = true
            registerSourceUndo(
                previous: parent.markdownText,
                previousSelection: parent.selectedMarkdownRange,
                textView: textView
            )
            selectedSourceRanges = []
            lastAddedVisibleRange = nil
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            parent.markdownText = mutation.source
            applyMarkdownText(mutation.source, to: textView)
            captureEditingCaret(textView.selectedRange(), in: textView)
        }

        func applyFormatting(
            _ action: WiskMarkdownFormattingAction,
            to visibleRanges: [NSRange],
            request: WiskMarkdownFormattingRequest,
            textView: NSTextView
        ) {
            guard let sourceRanges = mappedSourceRanges(from: visibleRanges) else { return }
            let isLinePrefix: Bool
            switch action {
            case .heading, .bullet, .numberedList, .checklist, .quote:
                isLinePrefix = true
            case .bold, .italic, .underline, .strikethrough, .highlight, .code, .link, .table:
                isLinePrefix = false
            }
            let targets = isLinePrefix
                ? WiskEditorMultiCursor.uniqueLineRanges(sourceRanges, in: parent.markdownText)
                : sourceRanges
            let previous = parent.markdownText
            let previousSelection = parent.selectedMarkdownRange
            guard let result = WiskEditorMultiCursor.applyAscending(
                ranges: targets,
                in: previous,
                mutate: { current, range in
                    guard let mutation = WiskMarkdownDocumentEngine.apply(action, to: current, sourceRange: range) else {
                        return nil
                    }
                    return (mutation.source, mutation.selectedSourceRange)
                }
            ) else {
                return
            }
            request.handled = true
            registerSourceUndo(
                previous: previous,
                previousSelection: previousSelection,
                textView: textView
            )
            parent.markdownText = result.text
            selectedSourceRanges = result.selectedRanges
            if let primary = result.selectedRanges.last {
                parent.selectedMarkdownRange = Range(primary, in: result.text)
                rememberSourceCaret(primary.location)
            }
            applyMarkdownText(result.text, to: textView)
            captureEditingCaret(textView.selectedRange(), in: textView)
        }

        func refreshLayoutIfNeeded(in textView: NSTextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            let width = availableWidth(for: textView)
            guard abs(width - lastAvailableWidth) > 2 else { return }
            lastAvailableWidth = width
            let hasFitImages = parent.attachments.contains {
                $0.isImage && $0.displayWidth == nil && $0.isPreviewVisible
            }
            guard hasFitImages else { return }
            applyMarkdownText(parent.markdownText, to: textView)
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard parent.isEditable,
                  let storage = view.textStorage else {
                return menu
            }
            if let attachment = wiskEditorAttachment(
                at: charIndex,
                in: storage,
                attachments: parent.attachments
            ) {
                var insertAt = 0
                if attachment.isImage, menu.item(withTitle: "Image Size") == nil {
                    let submenu = NSMenu(title: "Image Size")
                    for option in WiskAttachmentImageSizeOption.allCases {
                        let item = NSMenuItem(
                            title: option.title,
                            action: #selector(applyAttachmentMenuAction(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.state = option.isSelected(for: attachment) ? .on : .off
                        item.representedObject = WiskAttachmentMenuPayload(
                            attachmentID: attachment.id,
                            action: .displayWidth(option.displayWidth(for: attachment))
                        )
                        submenu.addItem(item)
                    }
                    let root = NSMenuItem(title: "Image Size", action: nil, keyEquivalent: "")
                    root.submenu = submenu
                    menu.insertItem(root, at: insertAt)
                    insertAt += 1
                }
                if attachment.isImage, menu.item(withTitle: "Crop") == nil {
                    let item = NSMenuItem(
                        title: "Crop",
                        action: #selector(applyAttachmentMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = WiskAttachmentMenuPayload(
                        attachmentID: attachment.id,
                        action: .crop
                    )
                    menu.insertItem(item, at: insertAt)
                    insertAt += 1
                }
                if menu.item(withTitle: "Alignment") == nil {
                    let submenu = NSMenu(title: "Alignment")
                    let options: [(String, NoteAttachmentAlignment)] = [
                        ("Leading", .leading),
                        ("Center", .center),
                        ("Trailing", .trailing),
                    ]
                    for (title, alignment) in options {
                        let item = NSMenuItem(
                            title: title,
                            action: #selector(applyAttachmentMenuAction(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.state = attachment.alignment == alignment ? .on : .off
                        item.representedObject = WiskAttachmentMenuPayload(
                            attachmentID: attachment.id,
                            action: .alignment(alignment)
                        )
                        submenu.addItem(item)
                    }
                    let root = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
                    root.submenu = submenu
                    menu.insertItem(root, at: insertAt)
                    insertAt += 1
                }
                if menu.item(withTitle: "Edit Name and Alt Text") == nil {
                    let item = NSMenuItem(
                        title: "Edit Name and Alt Text",
                        action: #selector(applyAttachmentMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = WiskAttachmentMenuPayload(
                        attachmentID: attachment.id,
                        action: .editDetails
                    )
                    menu.insertItem(item, at: insertAt)
                    insertAt += 1
                }
                let previewTitle = attachment.isPreviewVisible ? "Hide Preview" : "Show Preview"
                if menu.item(withTitle: previewTitle) == nil {
                    let item = NSMenuItem(
                        title: previewTitle,
                        action: #selector(applyAttachmentMenuAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = WiskAttachmentMenuPayload(
                        attachmentID: attachment.id,
                        action: .previewVisible(!attachment.isPreviewVisible)
                    )
                    menu.insertItem(item, at: insertAt)
                    insertAt += 1
                }
                menu.insertItem(.separator(), at: insertAt)
            } else {
                insertSourceContextMenuItems(into: menu, at: charIndex, textView: view)
            }
            return menu
        }

        func insertSourceContextMenuItems(into menu: NSMenu, at charIndex: Int, textView: NSTextView) {
            let document = parsedDocument(for: parent.markdownText)
            guard let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                visibleRange: NSRange(location: charIndex, length: 0),
                source: parent.markdownText,
                showSourceMarkers: parent.showSourceMarkers,
                document: document,
                foldedLocations: parent.foldedSourceLocations.wrappedValue
            ) else {
                return
            }
            if document.tables.contains(where: {
                sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
            }) {
                let titles = [
                    "Insert Table Row",
                    "Delete Table Row",
                    "Insert Table Column",
                    "Delete Table Column",
                ]
                for title in titles.reversed() {
                    let item = NSMenuItem(title: title, action: #selector(applyNamedTableAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = TableMenuPayload(title: title, sourceRange: sourceRange)
                    menu.insertItem(item, at: 0)
                }
            }
            if let anchor = WiskMarkdownFolding.foldAnchor(atSource: sourceRange.location, in: document),
               WiskMarkdownFolding.interiorSourceRange(forFoldAt: anchor, in: document) != nil {
                let folded = parent.foldedSourceLocations.wrappedValue.contains(anchor)
                let item = NSMenuItem(
                    title: folded ? "Unfold" : "Fold",
                    action: #selector(applyFoldMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = anchor
                menu.insertItem(item, at: 0)
            }
        }

        @objc private func applyNamedTableAction(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? TableMenuPayload,
                  let textView = boundTextView else { return }
            let mutation: WiskMarkdownMutation?
            switch payload.title {
            case "Insert Table Row":
                mutation = WiskMarkdownDocumentEngine.insertTableRow(in: parent.markdownText, sourceRange: payload.sourceRange)
            case "Delete Table Row":
                mutation = WiskMarkdownDocumentEngine.deleteTableRow(in: parent.markdownText, sourceRange: payload.sourceRange)
            case "Insert Table Column":
                mutation = WiskMarkdownDocumentEngine.insertTableColumn(in: parent.markdownText, sourceRange: payload.sourceRange)
            case "Delete Table Column":
                mutation = WiskMarkdownDocumentEngine.deleteTableColumn(in: parent.markdownText, sourceRange: payload.sourceRange)
            default:
                mutation = nil
            }
            if let mutation {
                applyTableMutation(mutation, textView: textView)
            }
        }

        @objc private func applyFoldMenuAction(_ sender: NSMenuItem) {
            guard let anchor = sender.representedObject as? Int,
                  let textView = boundTextView else { return }
            if parent.foldedSourceLocations.wrappedValue.contains(anchor) {
                parent.foldedSourceLocations.wrappedValue.remove(anchor)
            } else {
                parent.foldedSourceLocations.wrappedValue.insert(anchor)
            }
            applyMarkdownText(parent.markdownText, to: textView)
        }

        @objc private func applyAttachmentMenuAction(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? WiskAttachmentMenuPayload else { return }
            parent.onAttachmentAction(payload.attachmentID, payload.action)
        }

        @objc private func applyImageSize(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? WiskImageSizeMenuPayload else { return }
            parent.onAttachmentDisplayWidthChange(payload.attachmentID, payload.width)
        }

        private func availableWidth(for textView: NSTextView) -> CGFloat {
            wiskRichEditorAvailableWidth(
                boundsWidth: textView.bounds.width,
                horizontalInset: textView.textContainerInset.width * 2,
                lineFragmentPadding: textView.textContainer?.lineFragmentPadding ?? 0
            )
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                WiskActiveMarkdownEditor.claim(textView)
            }
            parent.onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            caretChangeIsUserInitiated = false
            parent.onFocusChange?(false)
        }

        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
            toCharacterRanges newSelectedCharRanges: [NSValue]
        ) -> [NSValue] {
            if isApplyingMultiCursor || isApplyingSourceEdit || isApplyingProgrammaticUpdate {
                return newSelectedCharRanges
            }
            if newSelectedCharRanges.count > 1 {
                return newSelectedCharRanges
            }
            if oldSelectedCharRanges.count > 1 {
                return newSelectedCharRanges
            }
            guard let oldRange = oldSelectedCharRanges.first?.rangeValue,
                  let newRange = newSelectedCharRanges.first?.rangeValue else {
                return newSelectedCharRanges
            }
            let kept = WiskRichMarkdownDocument.selectionAfterProposedChange(
                from: oldRange,
                to: newRange,
                text: textView.string,
                isUserInitiated: caretChangeIsUserInitiated || isApplyingProgrammaticUpdate
            )
            if kept == oldRange {
                return oldSelectedCharRanges
            }
            return newSelectedCharRanges
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            if let url, let target = WiskNoteLinkService.wikiTarget(from: url) {
                parent.onOpenWikiLink?(target)
                return true
            }
            if let url {
                return WiskMarkdownDocumentEngine.isSafeURL(url)
            }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let isUserInitiated = caretChangeIsUserInitiated
            let fromMouse = selectionChangeFromMouse
            caretChangeIsUserInitiated = false
            selectionChangeFromMouse = false
            let visibleRanges = liveVisibleRanges(in: textView)
            let selectedRange = visibleRanges.last ?? textView.selectedRange()
            if fromMouse,
               visibleRanges.count < 2,
               !isApplyingMultiCursor,
               !isApplyingProgrammaticUpdate,
               !isApplyingSourceEdit {
                selectedSourceRanges = []
                lastAddedVisibleRange = nil
            }
            if !isApplyingProgrammaticUpdate, selectedRange.location != NSNotFound {
                let didRemember = rememberVisibleRange(
                    selectedRange,
                    in: textView,
                    isUserInitiated: isUserInitiated
                )
                if didRemember, let mapped = mappedSelectedMarkdownRange(from: selectedRange) {
                    parent.selectedMarkdownRange = mapped
                    if visibleRanges.count >= 2 {
                        syncSourceRanges(from: visibleRanges)
                    } else if selectedSourceRanges.count < 2 || fromMouse {
                        selectedSourceRanges = []
                        lastAddedVisibleRange = nil
                    }
                    publishWikiQuery()
                    publishWikiCaret(in: textView)
                }
            }
            guard !isApplyingProgrammaticUpdate else { return }
            (textView as? WiskMarkdownNSTextView)?.syncImageResizeChromeFromSelection()
            dropAbandonedMarkedCommitState(in: textView)
        }

        /// A composition that ended without a committed text change
        /// (cancelled IME input, rejected dictation) leaves
        /// pendingEditedRange pointing at a location nothing was inserted
        /// into. A later unrelated native change could then apply a bogus
        /// replacement there. The deferred drop gives a real commit's
        /// textDidChange one runloop tick to consume the pending range
        /// first.
        private func dropAbandonedMarkedCommitState(in textView: NSTextView) {
            guard textView.hasMarkedText() == false,
                  pendingEditedRange != nil,
                  !isApplyingProgrammaticUpdate,
                  !isApplyingSourceEdit else {
                return
            }
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                guard self.pendingEditedRange != nil, textView.hasMarkedText() == false else { return }
                self.pendingEditedRange = nil
                if self.nativeUndoDisabledForMarkedCommit {
                    self.nativeUndoDisabledForMarkedCommit = false
                    textView.undoManager?.enableUndoRegistration()
                }
            }
        }

        func applyReplacementToStoredCarets(_ replacement: String, textView: NSTextView) -> Bool {
            guard selectedSourceRanges.count >= 2 else { return false }
            if textView.hasMarkedText() {
                return false
            }
            pendingEditedRange = nil
            caretChangeIsUserInitiated = true
            let replacements = Array(repeating: replacement, count: selectedSourceRanges.count)
            return applySourceEdits(
                sourceRanges: selectedSourceRanges,
                replacements: replacements,
                textView: textView
            )
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard !isApplyingProgrammaticUpdate else { return true }
            if selectedSourceRanges.count >= 2, affectedRanges.count <= 1 {
                let replacement = replacementStrings?.first ?? ""
                if replacement.isEmpty, let carets = extraInsertionCarets(in: textView) {
                    let affected = affectedRanges.first?.rangeValue ?? textView.selectedRange()
                    if affected.length > 0 {
                        let direction: WiskEditorMultiCursor.CaretDelete =
                            affected.location < carets[0].location ? .backward : .forward
                        _ = deleteAtExtraCarets(direction, in: textView)
                    }
                    return false
                }
                _ = applyReplacementToStoredCarets(replacement, textView: textView)
                return false
            }
            if affectedRanges.count <= 1 {
                return self.textView(
                    textView,
                    shouldChangeTextIn: affectedRanges.first?.rangeValue ?? textView.selectedRange(),
                    replacementString: replacementStrings?.first
                )
            }
            caretChangeIsUserInitiated = true
            if textView.hasMarkedText() {
                return false
            }
            guard let replacementStrings, replacementStrings.count == affectedRanges.count else {
                return false
            }
            pendingEditedRange = nil
            return !applySourceEdits(
                visibleRanges: affectedRanges.map(\.rangeValue),
                replacements: replacementStrings,
                textView: textView
            )
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplyingProgrammaticUpdate else { return true }
            if selectedSourceRanges.count >= 2 {
                let replacement = replacementString ?? ""
                if replacement.isEmpty, let carets = extraInsertionCarets(in: textView), affectedCharRange.length > 0 {
                    let direction: WiskEditorMultiCursor.CaretDelete =
                        affectedCharRange.location < carets[0].location ? .backward : .forward
                    _ = deleteAtExtraCarets(direction, in: textView)
                    return false
                }
                _ = applyReplacementToStoredCarets(replacement, textView: textView)
                return false
            }
            caretChangeIsUserInitiated = true
            if textView.hasMarkedText() {
                let replacementLength = ((replacementString ?? "") as NSString).length
                pendingEditedRange = NSRange(
                    location: affectedCharRange.location,
                    length: max(affectedCharRange.length, replacementLength)
                )
                // The native commit applies outside the coordinator and would
                // register its own undo entry in the shared manager; suppress
                // it so the commit is a single source-level undo step. The
                // registration is re-enabled at the top of textDidChange.
                if let undoManager = textView.undoManager,
                   !undoManager.isUndoing, !undoManager.isRedoing {
                    nativeUndoDisabledForMarkedCommit = true
                    undoManager.disableUndoRegistration()
                }
                return true
            }
            pendingEditedRange = nil
            return !applySourceEdit(
                visibleRange: affectedCharRange,
                replacement: replacementString ?? "",
                textView: textView
            )
        }

        func extraInsertionCarets(in textView: NSTextView) -> [NSRange]? {
            let live = liveVisibleRanges(in: textView)
            guard live.count >= 2, live.allSatisfy({ $0.length == 0 }) else { return nil }
            return live
        }

        func caretMove(for commandSelector: Selector) -> WiskEditorMultiCursor.CaretMove? {
            if commandSelector == #selector(NSResponder.moveLeft(_:))
                || commandSelector == #selector(NSResponder.moveLeftAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveBackward(_:)) {
                return .left
            }
            if commandSelector == #selector(NSResponder.moveRight(_:))
                || commandSelector == #selector(NSResponder.moveRightAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveForward(_:)) {
                return .right
            }
            if commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.moveUpAndModifySelection(_:)) {
                return .up
            }
            if commandSelector == #selector(NSResponder.moveDown(_:))
                || commandSelector == #selector(NSResponder.moveDownAndModifySelection(_:)) {
                return .down
            }
            if commandSelector == #selector(NSResponder.moveWordLeft(_:))
                || commandSelector == #selector(NSResponder.moveWordLeftAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveWordBackward(_:)) {
                return .wordLeft
            }
            if commandSelector == #selector(NSResponder.moveWordRight(_:))
                || commandSelector == #selector(NSResponder.moveWordRightAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveWordForward(_:)) {
                return .wordRight
            }
            if commandSelector == #selector(NSResponder.moveToBeginningOfLine(_:))
                || commandSelector == #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveToLeftEndOfLine(_:))
                || commandSelector == #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)) {
                return .lineStart
            }
            if commandSelector == #selector(NSResponder.moveToEndOfLine(_:))
                || commandSelector == #selector(NSResponder.moveToEndOfLineAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveToRightEndOfLine(_:))
                || commandSelector == #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)) {
                return .lineEnd
            }
            return nil
        }

        func moveExtraCarets(_ direction: WiskEditorMultiCursor.CaretMove, in textView: NSTextView) -> Bool {
            guard let carets = extraInsertionCarets(in: textView) else { return false }
            let moved = WiskEditorMultiCursor.moveCarets(carets, in: textView.string, direction: direction)
            guard !moved.isEmpty else { return true }
            applyVisibleRanges(moved, in: textView)
            return true
        }

        func deleteAtExtraCarets(_ direction: WiskEditorMultiCursor.CaretDelete, in textView: NSTextView) -> Bool {
            guard let carets = extraInsertionCarets(in: textView) else { return false }
            let textLength = (textView.string as NSString).length
            var visibleRanges: [NSRange] = []
            var replacements: [String] = []
            visibleRanges.reserveCapacity(carets.count)
            replacements.reserveCapacity(carets.count)
            for caret in carets {
                switch direction {
                case .backward:
                    if caret.location > 0 {
                        visibleRanges.append(NSRange(location: caret.location - 1, length: 1))
                    } else {
                        visibleRanges.append(NSRange(location: caret.location, length: 0))
                    }
                case .forward:
                    if caret.location < textLength {
                        visibleRanges.append(NSRange(location: caret.location, length: 1))
                    } else {
                        visibleRanges.append(NSRange(location: caret.location, length: 0))
                    }
                }
                replacements.append("")
            }
            guard visibleRanges.contains(where: { $0.length > 0 }) else { return true }
            return applySourceEdits(visibleRanges: visibleRanges, replacements: replacements, textView: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return applyIndent(outdent: false, textView: textView)
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return applyIndent(outdent: true, textView: textView)
            }
            if let direction = caretMove(for: commandSelector) {
                return moveExtraCarets(direction, in: textView)
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                return deleteAtExtraCarets(.backward, in: textView)
            }
            if commandSelector == #selector(NSResponder.deleteForward(_:)) {
                return deleteAtExtraCarets(.forward, in: textView)
            }
            return false
        }

        private func applyIndent(outdent: Bool, textView: NSTextView) -> Bool {
            let document = parsedDocument(for: parent.markdownText)
            let visibleRanges = liveVisibleRanges(in: textView)
            if visibleRanges.count >= 2 {
                return applyIndent(outdent: outdent, visibleRanges: visibleRanges, textView: textView)
            }
            if selectedSourceRanges.count >= 2 {
                let folds = parent.foldedSourceLocations.wrappedValue
                let textLength = (textView.string as NSString).length
                let mapped = selectedSourceRanges.map { sourceRange in
                    WiskRichMarkdownDocument.visibleSelection(
                        forMarkdownRange: Range(sourceRange, in: parent.markdownText),
                        in: parent.markdownText,
                        fallback: textView.selectedRange(),
                        textLength: textLength,
                        showSourceMarkers: parent.showSourceMarkers,
                        document: document,
                        foldedLocations: folds
                    )
                }
                return applyIndent(outdent: outdent, visibleRanges: mapped, textView: textView)
            }
            let sourceRange = WiskRichEditorSourceEditing.mappedSourceRange(
                    visibleRange: textView.selectedRange(),
                    source: parent.markdownText,
                    showSourceMarkers: parent.showSourceMarkers,
                    document: document,
                    foldedLocations: parent.foldedSourceLocations.wrappedValue
                )
            guard let sourceRange else { return false }
            if let tableMutation = WiskMarkdownDocumentEngine.applyTableTab(
                in: parent.markdownText,
                sourceRange: sourceRange,
                reverse: outdent
            ) {
                selectedSourceRanges = []
                lastAddedVisibleRange = nil
                parent.selectedMarkdownRange = Range(tableMutation.selectedSourceRange, in: tableMutation.source)
                rememberSourceCaret(tableMutation.selectedSourceRange.location)
                applyMarkdownText(tableMutation.source, to: textView)
                rememberVisibleRange(textView.selectedRange(), in: textView, isUserInitiated: true)
                return true
            }
            guard let mutation = WiskMarkdownDocumentEngine.indentLines(
                in: parent.markdownText,
                sourceRange: sourceRange,
                outdent: outdent
            ) else { return false }
            registerSourceUndo(
                previous: parent.markdownText,
                previousSelection: parent.selectedMarkdownRange,
                textView: textView
            )
            selectedSourceRanges = []
            lastAddedVisibleRange = nil
            parent.markdownText = mutation.source
            parent.selectedMarkdownRange = Range(mutation.selectedSourceRange, in: mutation.source)
            rememberSourceCaret(mutation.selectedSourceRange.location)
            applyMarkdownText(mutation.source, to: textView)
            return true
        }

        private func applyIndent(outdent: Bool, visibleRanges: [NSRange], textView: NSTextView) -> Bool {
            guard let sourceRanges = mappedSourceRanges(from: visibleRanges) else { return false }
            let targets = WiskEditorMultiCursor.uniqueLineRanges(sourceRanges, in: parent.markdownText)
            let previous = parent.markdownText
            let previousSelection = parent.selectedMarkdownRange
            guard let result = WiskEditorMultiCursor.applyAscending(
                ranges: targets,
                in: previous,
                mutate: { current, range in
                    guard let mutation = WiskMarkdownDocumentEngine.indentLines(
                        in: current,
                        sourceRange: range,
                        outdent: outdent
                    ) else { return nil }
                    return (mutation.source, mutation.selectedSourceRange)
                }
            ) else {
                return false
            }
            registerSourceUndo(
                previous: previous,
                previousSelection: previousSelection,
                textView: textView
            )
            parent.markdownText = result.text
            selectedSourceRanges = result.selectedRanges
            if let primary = result.selectedRanges.last {
                parent.selectedMarkdownRange = Range(primary, in: result.text)
                rememberSourceCaret(primary.location)
            }
            applyMarkdownText(result.text, to: textView)
            return true
        }

        func textDidChange(_ notification: Notification) {
            // Re-enable native undo registration suppressed for the
            // marked-text commit (see shouldChangeTextIn) before anything
            // else can run.
            if nativeUndoDisabledForMarkedCommit,
               let textView = notification.object as? NSTextView {
                nativeUndoDisabledForMarkedCommit = false
                textView.undoManager?.enableUndoRegistration()
            }
            guard !isApplyingProgrammaticUpdate,
                  let textView = notification.object as? NSTextView else { return }
            guard !textView.hasMarkedText() else { return }
            guard let pending = pendingEditedRange else { return }
            pendingEditedRange = nil
            let ns = textView.string as NSString
            let replacementLength = max(textView.selectedRange().location - pending.location, 0)
            let replacementRange = NSRange(
                location: pending.location,
                length: min(replacementLength, max(ns.length - pending.location, 0))
            )
            let replacement = replacementRange.length > 0 ? ns.substring(with: replacementRange) : ""
            _ = applySourceEdit(
                visibleRange: NSRange(location: pending.location, length: 0),
                replacement: replacement,
                textView: textView
            )
        }
    }
}
#endif

#if os(iOS)
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor

private var platformTextColor: PlatformColor {
    .label
}

private var platformHighlightColor: PlatformColor {
    UIColor.systemYellow.withAlphaComponent(0.28)
}

private var platformSearchHighlightColor: PlatformColor {
    UIColor.systemYellow.withAlphaComponent(0.55)
}

private var platformCodeBackgroundColor: PlatformColor {
    UIColor.secondarySystemBackground
}

private func platformFont(fontSelection: WiskEditorFontSelection, size: CGFloat, weight: WiskRichMarkdownDocument.FontWeight) -> PlatformFont {
    let uiWeight = uiFontWeight(for: weight)
    switch fontSelection.source {
    case .builtIn:
        switch fontSelection.builtInFont {
        case .system:
            return .systemFont(ofSize: size, weight: uiWeight)
        case .serif:
            return .systemFont(ofSize: size, weight: uiWeight)
        case .rounded:
            let descriptor = UIFont.systemFont(ofSize: size, weight: uiWeight).fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
        case .avenirNext:
            return UIFont(name: weight == .regular ? "AvenirNext-Regular" : "AvenirNext-DemiBold", size: size) ?? .systemFont(ofSize: size, weight: uiWeight)
        case .georgia:
            return UIFont(name: weight == .regular ? "Georgia" : "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: uiWeight)
        case .palatino:
            return UIFont(name: weight == .regular ? "Palatino-Roman" : "Palatino-Bold", size: size) ?? .systemFont(ofSize: size, weight: uiWeight)
        case .helveticaNeue:
            return UIFont(name: weight == .regular ? "HelveticaNeue" : "HelveticaNeue-Medium", size: size) ?? .systemFont(ofSize: size, weight: uiWeight)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: uiWeight)
        case .menlo:
            return UIFont(name: weight == .regular ? "Menlo-Regular" : "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: uiWeight)
        }
    case .local, .google:
        if let postScriptName = fontSelection.postScriptName,
           let font = UIFont(name: postScriptName, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: uiWeight)
    }
}

private func platformMonospacedFont(size: CGFloat) -> PlatformFont {
    .monospacedSystemFont(ofSize: size, weight: .regular)
}

private func uiFontWeight(for weight: WiskRichMarkdownDocument.FontWeight) -> UIFont.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    }
}
#elseif os(macOS)
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor

private var platformTextColor: PlatformColor {
    .labelColor
}

private var platformHighlightColor: PlatformColor {
    NSColor.systemYellow.withAlphaComponent(0.28)
}

private var platformSearchHighlightColor: PlatformColor {
    NSColor.systemYellow.withAlphaComponent(0.55)
}

private var platformCodeBackgroundColor: PlatformColor {
    NSColor.controlBackgroundColor
}

private func platformFont(fontSelection: WiskEditorFontSelection, size: CGFloat, weight: WiskRichMarkdownDocument.FontWeight) -> PlatformFont {
    let nsWeight = nsFontWeight(for: weight)
    switch fontSelection.source {
    case .builtIn:
        switch fontSelection.builtInFont {
        case .system:
            return .systemFont(ofSize: size, weight: nsWeight)
        case .serif:
            return NSFont(name: weight == .regular ? "NewYork-Regular" : "NewYork-Bold", size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        case .rounded:
            return .systemFont(ofSize: size, weight: nsWeight)
        case .avenirNext:
            return NSFont(name: weight == .regular ? "AvenirNext-Regular" : "AvenirNext-DemiBold", size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        case .georgia:
            return NSFont(name: weight == .regular ? "Georgia" : "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        case .palatino:
            return NSFont(name: weight == .regular ? "Palatino-Roman" : "Palatino-Bold", size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        case .helveticaNeue:
            return NSFont(name: weight == .regular ? "HelveticaNeue" : "HelveticaNeue-Medium", size: size) ?? .systemFont(ofSize: size, weight: nsWeight)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: nsWeight)
        case .menlo:
            return NSFont(name: weight == .regular ? "Menlo-Regular" : "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: nsWeight)
        }
    case .local, .google:
        if let postScriptName = fontSelection.postScriptName,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: nsWeight)
    }
}

private func platformMonospacedFont(size: CGFloat) -> PlatformFont {
    .monospacedSystemFont(ofSize: size, weight: .regular)
}

private func nsFontWeight(for weight: WiskRichMarkdownDocument.FontWeight) -> NSFont.Weight {
    switch weight {
    case .regular: return .regular
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    }
}
#endif
