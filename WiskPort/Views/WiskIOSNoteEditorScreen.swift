#if os(iOS)
import SwiftUI
import UIKit
import VisionKit

/// Applies the Bear-style chrome to the note editor surface: hides the
/// system navigation bar in favor of floating glass top chrome, hosts the
/// persistent keyboard bar while the editor is focused, and floats the
/// transient status toast above the keyboard.
struct WiskIOSNoteEditorChromeModifier: ViewModifier {
    let title: String
    @Binding var isShowingInfo: Bool
    let isBodyEditorFocused: Bool
    let showsPreviewToggle: Bool
    let isPreviewing: Bool
    let hasProAccess: Bool
    let canCleanUp: Bool
    let canRoute: Bool
    let isRouting: Bool
    let routeHelp: String
    let statusMessage: String?
    let applyFormatting: (WiskMarkdownFormattingAction) -> Void
    let onTogglePreview: () -> Void
    let onOrganize: () -> Void
    let onUnlockAI: () -> Void
    let onCleanUp: () -> Void
    let onRoute: () -> Void
    let onFind: () -> Void
    let onTypography: () -> Void
    let onAddPhoto: () -> Void
    let onAddFiles: () -> Void
    let onScan: () -> Void
    let onSketch: () -> Void
    let onExport: () -> Void
    let onCopyAs: (WiskCopyAsFormat) -> Void
    let onShowReviewLayer: () -> Void
    let onShowSharing: () -> Void
    let onDelete: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top) {
                WiskIOSNoteEditorTopChrome(
                    title: title,
                    showsBackButton: horizontalSizeClass == .compact,
                    isShowingInfo: $isShowingInfo,
                    actionsMenu: {
                        WiskNoteActionsMenu(
                            isPreviewing: isPreviewing,
                            showsPreviewToggle: showsPreviewToggle,
                            hasProAccess: hasProAccess,
                            canCleanUp: canCleanUp,
                            canRoute: canRoute,
                            isRouting: isRouting,
                            routeHelp: routeHelp,
                            cameraSupported: VNDocumentCameraViewController.isSupported,
                            onTogglePreview: onTogglePreview,
                            onOrganize: onOrganize,
                            onUnlockAI: onUnlockAI,
                            onCleanUp: onCleanUp,
                            onRoute: onRoute,
                            onFind: onFind,
                            onTypography: onTypography,
                            onAddPhoto: onAddPhoto,
                            onAddFiles: onAddFiles,
                            onScan: onScan,
                            onSketch: onSketch,
                            onExport: onExport,
                            onCopyAs: onCopyAs,
                            onShowInfo: { isShowingInfo = true },
                            onShowReviewLayer: onShowReviewLayer,
                            onShowSharing: onShowSharing,
                            onDelete: onDelete
                        )
                    }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xs)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    if let statusMessage {
                        WiskIOSStatusToast(message: statusMessage)
                    }
                    if isBodyEditorFocused {
                        WiskIOSKeyboardFormattingBar(
                            applyFormatting: applyFormatting,
                            onAddPhoto: onAddPhoto
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: isBodyEditorFocused)
            }
    }
}

/// Floating glass top chrome for the Bear-style note editor: a back chevron
/// in a glass circle, a truncating inline title, and a right-hand glass
/// capsule holding (i) and the consolidated ⋯ action menu.
struct WiskIOSNoteEditorTopChrome: View {
    let title: String
    let showsBackButton: Bool
    @Binding var isShowingInfo: Bool
    let actionsMenu: () -> WiskNoteActionsMenu

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 40
    @Namespace private var chromeNamespace

    var body: some View {
        ZStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, circle * 2 + 28)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wisk.note.chromeTitle")

            HStack(spacing: 10) {
                if showsBackButton {
                    backButton
                }
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: 0) {
                        infoButton
                        Divider()
                            .frame(height: 18)
                        actionsMenu()
                    }
                    .wiskGlassEffect(.regular.interactive(), in: Capsule())
                }
                .glassEffectID("note-actions", in: chromeNamespace)
            }
        }
        .frame(maxWidth: .infinity, minHeight: circle)
    }

    private var backButton: some View {
        GlassEffectContainer(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: circle, height: circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .wiskGlassEffect(.regular.interactive(), in: Circle())
            .glassEffectID("note-back", in: chromeNamespace)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("wisk.note.backButton")
        }
    }

    private var infoButton: some View {
        Button {
            isShowingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: circle, height: circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Note Info")
        .accessibilityIdentifier("wisk.note.infoButton")
    }
}

/// Transient status toast shown just above the keyboard (replaces the
/// permanent status pill stack in the old card canvas).
struct WiskIOSStatusToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.wiskPrimaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("wisk.note.statusToast")
    }
}

/// Export / import options presented as a sheet from the ⋯ menu.
struct WiskNoteExportOptionsList: View {
    let onImport: () -> Void
    let onExport: (WiskExportFormat) -> Void

    var body: some View {
        List {
            Section("Export this note") {
                ForEach(WiskExportFormat.allCases) { format in
                    Button {
                        onExport(format)
                    } label: {
                        Label("Export \(format.title)", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("wisk.note.export.\(format.rawValue)")
                }
            }
            Section("Import") {
                Button {
                    onImport()
                } label: {
                    Label("Import Markdown or TextBundle", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("wisk.note.interchangeMenu")
            }
        }
    }
}
struct WiskIOSKeyboardFormattingBar: View {
    let applyFormatting: (WiskMarkdownFormattingAction) -> Void
    let onAddPhoto: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            keyboardButton("arrow.uturn.backward", label: "Undo", identifier: "wisk.formatting.undo") {
                NotificationCenter.default.post(name: .wiskUndoMarkdownEditor, object: nil)
            }
            keyboardButton("arrow.uturn.forward", label: "Redo", identifier: "wisk.formatting.redo") {
                NotificationCenter.default.post(name: .wiskRedoMarkdownEditor, object: nil)
            }

            keyboardButton("number", label: "Add tag", identifier: "wisk.formatting.tag") {
                insertTagMarker()
            }

            keyboardButton("keyboard.chevron.compact.down", label: "Dismiss keyboard", identifier: "wisk.formatting.dismiss") {
                resignFirstResponder()
            }

            keyboardButton("photo", label: "Add photo", identifier: "wisk.note.insertPhotoButton") {
                onAddPhoto()
            }

            Spacer(minLength: 0)

            keyboardButton("bold", label: "Bold", identifier: "wisk.formatting.bold") {
                applyFormatting(.bold)
            }
            keyboardButton("italic", label: "Italic", identifier: "wisk.formatting.italic") {
                applyFormatting(.italic)
            }
            keyboardButton("underline", label: "Underline", identifier: "wisk.formatting.underline") {
                applyFormatting(.underline)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        // Contain first: a bare container identifier propagates down and
        // overwrites every button's own identifier in the accessibility tree.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wisk.keyboardBar")
    }

    private func keyboardButton(
        _ systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Starts a `#tag` in the active editor by inserting the marker through
    /// the text input system so undo and autosave wiring stay intact.
    private func insertTagMarker() {
        guard let textView = WiskActiveMarkdownEditor.textView as? UITextView else { return }
        textView.becomeFirstResponder()
        textView.insertText("#")
    }

    private func resignFirstResponder() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
#endif
