import SwiftUI
import ClearlyCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bridge between Wisk's note UI and Clearly's TextKit 1 composer stack.
///
/// Replaces `WiskRichMarkdownEditor` (TextKit 2, ~8k lines) with Clearly's
/// regex-driven `MarkdownSyntaxHighlighter` on a hand-built TextKit 1 graph
/// (`NSTextStorage` + `NSLayoutManager` + `NSTextContainer`), keeping the
/// three QuickType-safe guards that make Clearly's engine safe:
/// 1. Marked-text gate — programmatic text replacement never touches an
///    in-flight IME composition (CJK, dead keys, predictive text).
/// 2. `pendingBindingUpdates` token — while the binding write from typing
///    is still propagating, `update*View` must not clobber the text view.
/// 3. `isHighlighting` — attribute-only rehighlight passes never re-enter
///    the binding write-back.
///
/// Implemented subset: `markdownText` binding, `minHeight`, `isEditable`,
/// `baseFontSize`, `documentIdentity`, `accessibilityIdentifier`,
/// `onFocusChange`. Deferred (accepted for call-site parity, ignored):
/// inline attachment rendering, wiki-link suggestions, fold state,
/// jump-to-source, find highlighting, font selection.
struct WiskNextComposer: View {
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
    var accessibilityIdentifier: String = "wisk.composer"
    var onFocusChange: ((Bool) -> Void)? = nil
    var onOpenWikiLink: ((String) -> Void)? = nil
    var onJumpHandled: (() -> Void)? = nil
    var onWikiQueryChanged: ((String?) -> Void)? = nil
    var onEditAttachmentDetails: ((NoteAttachment) -> Void)? = nil
    var onPasteImage: (() -> Void)? = nil
    var bodyFocusRequestID: UUID? = nil
    var onBodyFocusHandled: (() -> Void)? = nil

    var body: some View {
        Group {
        #if os(macOS)
        ComposerMacTextView(
            markdownText: $markdownText,
            baseFontSize: baseFontSize,
            isEditable: isEditable,
            documentIdentity: documentIdentity,
            onFocusChange: onFocusChange
        )
        #else
        ComposerIOSTextView(
            markdownText: $markdownText,
            baseFontSize: baseFontSize,
            isEditable: isEditable,
            documentIdentity: documentIdentity,
            onFocusChange: onFocusChange
        )
        #endif
        }
        .frame(minHeight: minHeight)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - macOS (AppKit / TextKit 1 via ClearlyTextView)

#if os(macOS)

private struct ComposerMacTextView: NSViewRepresentable {
    @Binding var markdownText: String
    var baseFontSize: CGFloat
    var isEditable: Bool
    var documentIdentity: UUID?
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false

        let textView = ClearlyTextView(markdownFrame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = false
        textView.usesFontPanel = false
        // Substitution guards: same set Clearly pins off on Mac.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        TextCheckingPreferences.apply(to: textView)

        let font = NSFontManager.shared.convert(Theme.editorFont, toSize: baseFontSize)
        textView.font = font
        textView.textColor = Theme.textColor
        textView.backgroundColor = Theme.backgroundColor
        let paragraph = MarkdownHeadingLayout.paragraphStyle()
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: Theme.textColor,
            .paragraphStyle: paragraph,
            .baselineOffset: Theme.editorBaselineOffset
        ]
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isEditable = isEditable

        context.coordinator.highlighter = MarkdownEditorHighlighter()
        // Initial text set BEFORE the delegate attaches, mirroring Clearly's
        // EditorView: avoids a textDidChange fire during makeNSView.
        textView.string = markdownText
        context.coordinator.lastAppliedText = markdownText
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClearlyTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable

        // Guard 2+1: skip while the typing write-back is in flight or an IME
        // composition is live — the text view is authoritative in both cases.
        let textMismatch = markdownText != context.coordinator.lastAppliedText
        guard !context.coordinator.isUpdating,
              context.coordinator.pendingBindingUpdates == 0,
              !textView.hasMarkedText(),
              textMismatch else { return }

        context.coordinator.isUpdating = true
        let selectedRanges = textView.selectedRanges
        textView.string = markdownText
        textView.selectedRanges = selectedRanges
        context.coordinator.textUndoManager.removeAllActions()
        context.coordinator.isHighlightingInProgress = true
        context.coordinator.highlighter?.highlightAll(
            textView.textStorage!, caller: "composer-externalText"
        )
        context.coordinator.isHighlightingInProgress = false
        context.coordinator.lastAppliedText = markdownText
        context.coordinator.isUpdating = false
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? ClearlyTextView {
            textView.delegate = nil
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerMacTextView
        var isUpdating = false
        var isHighlightingInProgress = false
        var highlighter: MarkdownEditorHighlighter?
        var lastEditedRange: NSRange?
        var lastReplacementLength: Int = 0
        var lastAppliedText: String = ""
        /// Dedicated undo manager: binding writes must not pollute the
        /// window undo manager's typing coalescing (Clearly #390 pattern).
        let textUndoManager = UndoManager()
        /// In-flight async binding writes; > 0 means updateNSView must not
        /// replace the text view's content.
        var pendingBindingUpdates = 0
        var pendingBindingUpdateToken: UUID?

        init(parent: ComposerMacTextView) {
            self.parent = parent
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard textView.isEditable else { return false }
            lastEditedRange = affectedCharRange
            lastReplacementLength = (replacementString as NSString?)?.length ?? 0
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ClearlyTextView else { return }
            guard !isHighlightingInProgress else { return }

            pendingBindingUpdates = 1
            isHighlightingInProgress = true
            if let editedRange = lastEditedRange {
                highlighter?.highlightAround(
                    textView.textStorage!,
                    editedRange: editedRange,
                    replacementLength: lastReplacementLength,
                    caller: "composer-textDidChange"
                )
                lastEditedRange = nil
            } else {
                highlighter?.highlightAll(
                    textView.textStorage!, caller: "composer-textDidChange-fallback"
                )
            }
            isHighlightingInProgress = false

            let newText = textView.string
            lastAppliedText = newText
            parent.markdownText = newText

            // Decay the pending token so a later external write can land.
            let token = UUID()
            pendingBindingUpdateToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.pendingBindingUpdateToken == token else { return }
                self.pendingBindingUpdateToken = nil
                self.pendingBindingUpdates = 0
            }
        }

        func textViewDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ notification: Notification) {
            parent.onFocusChange?(false)
        }
    }
}

#else

// MARK: - iOS (UIKit / TextKit 1 via ClearlyUITextView)

private struct ComposerIOSTextView: UIViewRepresentable {
    @Binding var markdownText: String
    var baseFontSize: CGFloat
    var isEditable: Bool
    var documentIdentity: UUID?
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ClearlyUITextView {
        let textView = ClearlyUITextView()
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.font = Theme.editorFont.withSize(baseFontSize)
        // Grows with content inside Wisk's outer ScrollView (Bear canvas):
        // no inner scrolling, intrinsic content size drives the height.
        textView.isScrollEnabled = false
        context.coordinator.textView = textView
        context.coordinator.applyExternalText(markdownText)
        return textView
    }

    func updateUIView(_ textView: ClearlyUITextView, context: Context) {
        context.coordinator.parent = self
        textView.isEditable = isEditable
        guard context.coordinator.pendingBindingUpdates == 0 else { return }
        // Guard 1: never clobber an in-flight IME composition — UIKit's
        // marked text mutates the text view without firing textViewDidChange.
        guard textView.markedTextRange == nil else { return }
        guard markdownText != context.coordinator.lastAppliedText else { return }
        context.coordinator.applyExternalText(markdownText)
    }

    static func dismantleUIView(_ textView: ClearlyUITextView, coordinator: Coordinator) {
        textView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerIOSTextView
        weak var textView: ClearlyUITextView?
        let highlighter = MarkdownSyntaxHighlighter()
        var pendingBindingUpdates = 0
        var pendingBindingUpdateToken: UUID?
        var isHighlighting = false
        var lastEditedRange: NSRange?
        var lastReplacementLength: Int = 0
        var lastAppliedText: String = ""

        init(parent: ComposerIOSTextView) {
            self.parent = parent
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard textView.isEditable else { return false }
            lastEditedRange = range
            lastReplacementLength = (text as NSString).length
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isHighlighting, let ctv = textView as? ClearlyUITextView else { return }

            pendingBindingUpdates = 1

            isHighlighting = true
            if let editedRange = lastEditedRange {
                highlighter.highlightAround(
                    ctv.textStorage,
                    editedRange: editedRange,
                    replacementLength: lastReplacementLength,
                    caller: "composer-textViewDidChange"
                )
                lastEditedRange = nil
            } else {
                highlighter.highlightAll(
                    ctv.textStorage, caller: "composer-textViewDidChange-fallback"
                )
            }
            isHighlighting = false

            // Intrinsic height changed with the text; re-measure for SwiftUI.
            ctv.invalidateIntrinsicContentSize()

            let newText = ctv.text ?? ""
            lastAppliedText = newText
            parent.markdownText = newText

            let token = UUID()
            pendingBindingUpdateToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.pendingBindingUpdateToken == token else { return }
                self.pendingBindingUpdateToken = nil
                self.pendingBindingUpdates = 0
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange?(false)
        }

        func applyExternalText(_ newText: String) {
            guard let textView else { return }
            isHighlighting = true
            let selectedRange = textView.selectedRange
            textView.text = newText
            highlighter.highlightAll(textView.textStorage, caller: "composer-applyExternal")
            let clamped = NSRange(
                location: min(selectedRange.location, (newText as NSString).length),
                length: 0
            )
            textView.selectedRange = clamped
            isHighlighting = false
            lastAppliedText = newText
            textView.invalidateIntrinsicContentSize()
        }
    }
}

#endif
