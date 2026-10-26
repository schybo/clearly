#if os(iOS)
import SwiftUI

/// Consolidated ⋯ action menu for the Bear-style iOS note editor canvas.
/// Every action the old card header / nav bar / Pro card scattered around the
/// canvas funnels into this single menu.
struct WiskNoteActionsMenu: View {
    let isPreviewing: Bool
    let showsPreviewToggle: Bool
    let hasProAccess: Bool
    let canCleanUp: Bool
    let canRoute: Bool
    let isRouting: Bool
    let routeHelp: String
    let cameraSupported: Bool
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
    let onShowInfo: () -> Void
    let onShowReviewLayer: () -> Void
    let onShowSharing: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        Menu {
            if showsPreviewToggle {
                Button {
                    onTogglePreview()
                } label: {
                    Label(isPreviewing ? "Edit" : "Preview", systemImage: isPreviewing ? "pencil" : "doc.richtext")
                }
                .accessibilityIdentifier("wisk.note.previewToggle")
            }

            Button {
                if hasProAccess {
                    onOrganize()
                } else {
                    onUnlockAI()
                }
            } label: {
                Label(
                    hasProAccess ? "Organize now" : "Unlock AI",
                    systemImage: "sparkles"
                )
            }
            .accessibilityIdentifier("wisk.note.organizeButton")

            Button {
                onCleanUp()
            } label: {
                Label("Clean Up", systemImage: "wand.and.stars")
            }
            .disabled(!canCleanUp)
            .accessibilityIdentifier("wisk.note.cleanUpButton")

            Button {
                onRoute()
            } label: {
                Label(isRouting ? "Routing…" : "Route…", systemImage: "arrow.triangle.branch")
            }
            .disabled(!canRoute || isRouting)
            .accessibilityIdentifier("wisk.note.routeButton")
            .accessibilityHint(routeHelp)

            Divider()

            Button {
                onFind()
            } label: {
                Label("Find in Note", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("wisk.note.findInNote")

            Button {
                onTypography()
            } label: {
                Label("Typography…", systemImage: "textformat")
            }
            .accessibilityIdentifier("wisk.note.typography")

            Menu {
                Button {
                    onAddPhoto()
                } label: {
                    Label("Photo", systemImage: "photo")
                }
                .accessibilityIdentifier("wisk.note.insertPhotoButton")

                Button {
                    onAddFiles()
                } label: {
                    Label("Files", systemImage: "paperclip")
                }
                .accessibilityIdentifier("wisk.note.insertFileButton")

                if cameraSupported {
                    Button {
                        onScan()
                    } label: {
                        Label("Scan", systemImage: "doc.viewfinder")
                    }
                    .accessibilityIdentifier("wisk.note.scanDocumentButton")
                }

                Button {
                    onSketch()
                } label: {
                    Label("Sketch", systemImage: "scribble")
                }
                .accessibilityIdentifier("wisk.note.sketchButton")
            } label: {
                Label("Add", systemImage: "plus")
            }

            Divider()

            Button {
                onShowReviewLayer()
            } label: {
                Label("Review Layer", systemImage: "sparkles.rectangle.stack")
            }
            .accessibilityIdentifier("wisk.note.reviewLayer")

            Button {
                onShowSharing()
            } label: {
                Label("Sharing…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("wisk.note.sharing")

            Button {
                onExport()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up.on.square")
            }
            .accessibilityIdentifier("wisk.note.exportMenu")

            Menu {
                ForEach(WiskCopyAsFormat.allCases) { format in
                    Button(format.title) {
                        onCopyAs(format)
                    }
                }
            } label: {
                Label("Copy as…", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("wisk.note.copyAsMenu")

            Button {
                onShowInfo()
            } label: {
                Label("Note Info…", systemImage: "info.circle")
            }
            .accessibilityIdentifier("wisk.note.infoButton")

            Divider()

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("wisk.note.deleteButton")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .confirmationDialog(
            "Move this note to Trash?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note moves to Trash and stays recoverable from the Notes list.")
        }
        .accessibilityIdentifier("wisk.note.actionsMenu")
    }
}
#endif
