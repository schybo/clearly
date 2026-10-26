import Foundation
import SwiftUI

extension Notification.Name {
    static let wiskUndoMarkdownEditor = Notification.Name("wisk.undoMarkdownEditor")
    static let wiskRedoMarkdownEditor = Notification.Name("wisk.redoMarkdownEditor")
    static let wiskApplyMarkdownEditorFormatting = Notification.Name("wisk.applyMarkdownEditorFormatting")
    static let wiskFindInNote = Notification.Name("wisk.findInNote")
    static let wiskSplitSelectionIntoLines = Notification.Name("wisk.splitSelectionIntoLines")
    static let wiskSelectNextOccurrence = Notification.Name("wisk.selectNextOccurrence")
    static let wiskSelectAllOccurrences = Notification.Name("wisk.selectAllOccurrences")
}

private struct WiskEditorBodyFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var wiskEditorBodyFocused: Bool? {
        get { self[WiskEditorBodyFocusedKey.self] }
        set { self[WiskEditorBodyFocusedKey.self] = newValue }
    }
}

final class WiskMarkdownFormattingRequest {
    let action: WiskMarkdownFormattingAction
    var handled = false

    init(action: WiskMarkdownFormattingAction) {
        self.action = action
    }
}

enum WiskEditorDefaults {
    static let fontFamilyKey = "wisk.editor.fontFamily"
    static let fontSelectionKey = "wisk.editor.fontSelection.v1"
    static let customFontsKey = "wisk.editor.customFonts.v1"
    static let googleFontsCacheKey = "wisk.editor.googleFonts.cache.v1"
    static let formattingControlsKey = "wisk.editor.formattingControlsEnabled"
    static let showMarkdownSyntaxKey = "wisk.editor.showMarkdownSyntax"
    static let macFontSizeKey = "wisk.mac.editorFontSize"
    static let showReviewPanelKey = "wisk.mac.showReviewPanel"
    static let defaultFontSize = 16.0
}

enum WiskEditorFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded
    case avenirNext
    case georgia
    case palatino
    case helveticaNeue
    case monospaced
    case menlo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .avenirNext: return "Avenir Next"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .helveticaNeue: return "Helvetica Neue"
        case .monospaced: return "Monospaced"
        case .menlo: return "Menlo"
        }
    }

    var description: String {
        switch self {
        case .system: return "Clean Apple default for everyday notes."
        case .serif: return "A warmer, document-like writing feel."
        case .rounded: return "Soft and friendly for casual notes."
        case .avenirNext: return "A polished sans-serif with a little more personality."
        case .georgia: return "Comfortable serif text for longer-form writing."
        case .palatino: return "A classic bookish serif for reflective notes."
        case .helveticaNeue: return "A neutral, compact sans-serif for dense notes."
        case .monospaced: return "Fixed-width text for code and structured notes."
        case .menlo: return "A crisp developer-style monospace for technical notes."
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .avenirNext:
            return .custom("Avenir Next", size: size).weight(weight)
        case .georgia:
            return .custom("Georgia", size: size).weight(weight)
        case .palatino:
            return .custom("Palatino", size: size).weight(weight)
        case .helveticaNeue:
            return .custom("Helvetica Neue", size: size).weight(weight)
        case .monospaced:
            return .system(size: size, weight: weight, design: .monospaced)
        case .menlo:
            return .custom("Menlo", size: size).weight(weight)
        }
    }
}

enum WiskMarkdownFormattingAction: String, CaseIterable, Identifiable {
    case bold
    case italic
    case underline
    case strikethrough
    case highlight
    case heading
    case bullet
    case numberedList
    case checklist
    case quote
    case code
    case link
    case table

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .highlight: return "Highlight"
        case .heading: return "Heading"
        case .bullet: return "Bullet"
        case .numberedList: return "Numbered List"
        case .checklist: return "Checklist"
        case .quote: return "Quote"
        case .code: return "Code"
        case .link: return "Link"
        case .table: return "Table"
        }
    }

    var systemImage: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .highlight: return "highlighter"
        case .heading: return "textformat.size"
        case .bullet: return "list.bullet"
        case .numberedList: return "list.number"
        case .checklist: return "checklist"
        case .quote: return "quote.opening"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .table: return "tablecells"
        }
    }
}

enum WiskCopyAsFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case markdown
    case richText
    case html

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .markdown: "Markdown"
        case .richText: "Rich Text"
        case .html: "HTML"
        }
    }
}

enum WiskExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case textBundle
    case richText
    case html
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .textBundle: "TextBundle"
        case .richText: "Rich Text"
        case .html: "HTML"
        case .pdf: "PDF"
        }
    }
}

enum WiskMarkdownFormatter {
    static func apply(
        _ action: WiskMarkdownFormattingAction,
        to text: String,
        selectedRange: Range<String.Index>? = nil
    ) -> String {
        if let selectedRange {
            let sourceRange = WiskRichMarkdownDocument.replacingCollapsedDocumentEnd(
                NSRange(selectedRange, in: text),
                textLength: (text as NSString).length
            )
            if let mutation = WiskMarkdownDocumentEngine.apply(action, to: text, sourceRange: sourceRange) {
                return mutation.source
            }
        }

        if isLinePrefixAction(action) {
            let caret = NSRange(location: 0, length: 0)
            if let mutation = WiskMarkdownDocumentEngine.apply(action, to: text, sourceRange: caret) {
                return mutation.source
            }
        }

        return appending(action.placeholder, to: text)
    }

    private static func isLinePrefixAction(_ action: WiskMarkdownFormattingAction) -> Bool {
        switch action {
        case .heading, .bullet, .numberedList, .checklist, .quote:
            return true
        case .bold, .italic, .underline, .strikethrough, .highlight, .code, .link, .table:
            return false
        }
    }

    private static func appending(_ insertion: String, to text: String) -> String {
        guard text.isEmpty == false else { return insertion }
        let separator = text.hasSuffix("\n") ? "" : "\n"
        return text + separator + insertion
    }
}

private extension WiskMarkdownFormattingAction {
    var placeholder: String {
        switch self {
        case .bold:
            return "**bold text**"
        case .italic:
            return "*italic text*"
        case .underline:
            return "<u>underlined text</u>"
        case .strikethrough:
            return "~~struck text~~"
        case .highlight:
            return "==highlighted text=="
        case .heading:
            return "# Heading"
        case .bullet:
            return "- List item"
        case .numberedList:
            return "1. List item"
        case .checklist:
            return "- [ ] Task"
        case .quote:
            return "> Quote"
        case .code:
            return "`code`"
        case .link:
            return "[Link text](https://example.com)"
        case .table:
            return """
            | Item | Notes |
            | --- | --- |
            | Example | Detail |
            """
        }
    }
}
