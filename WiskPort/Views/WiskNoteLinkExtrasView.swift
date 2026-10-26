import SwiftData
import SwiftUI

private struct WiskOpenNoteKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}

extension EnvironmentValues {
    var wiskOpenNote: (UUID) -> Void {
        get { self[WiskOpenNoteKey.self] }
        set { self[WiskOpenNoteKey.self] = newValue }
    }
}

struct WiskNoteLinkExtrasView: View {
    let note: Note
    var listings: [WiskNoteLinkListing]
    var foldedSourceLocations: Binding<Set<Int>> = .constant([])
    var onJumpToSourceRange: ((NSRange) -> Void)?

    @Environment(\.wiskOpenNote) private var openNote

    init(
        note: Note,
        listings: [WiskNoteLinkListing],
        foldedSourceLocations: Binding<Set<Int>> = .constant([]),
        onJumpToSourceRange: ((NSRange) -> Void)? = nil
    ) {
        self.note = note
        self.listings = listings
        self.foldedSourceLocations = foldedSourceLocations
        self.onJumpToSourceRange = onJumpToSourceRange
    }

    init(
        note: Note,
        notes: [Note],
        foldedSourceLocations: Binding<Set<Int>> = .constant([]),
        onJumpToSourceRange: ((NSRange) -> Void)? = nil
    ) {
        self.init(
            note: note,
            listings: notes.map(WiskNoteLinkListing.init(note:)),
            foldedSourceLocations: foldedSourceLocations,
            onJumpToSourceRange: onJumpToSourceRange
        )
    }

    private var outline: [WiskMarkdownOutlineItem] {
        parsedDocument.outline
    }

    private var parsedDocument: WiskMarkdownDocument {
        WiskMarkdownDocumentEngine.parse(note.body)
    }

    private var linked: [WiskNoteLinkListing] {
        WiskNoteLinkService.linkedNotes(from: note.body, in: listings)
    }

    private var backlinks: [WiskNoteLinkListing] {
        WiskNoteLinkService.backlinks(to: note.title, excluding: note.id, in: listings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !outline.isEmpty {
                extrasSection(title: "Outline", identifier: "wisk.note.outline") {
                    ForEach(outline) { item in
                        HStack(spacing: 6) {
                            if WiskMarkdownFolding.interiorSourceRange(forFoldAt: item.sourceRange.location, in: parsedDocument) != nil {
                                Button {
                                    var folds = foldedSourceLocations.wrappedValue
                                    if folds.contains(item.sourceRange.location) {
                                        folds.remove(item.sourceRange.location)
                                    } else {
                                        folds.insert(item.sourceRange.location)
                                    }
                                    foldedSourceLocations.wrappedValue = folds
                                } label: {
                                    Image(systemName: foldedSourceLocations.wrappedValue.contains(item.sourceRange.location) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(foldedSourceLocations.wrappedValue.contains(item.sourceRange.location) ? "Unfold heading" : "Fold heading")
                            }
                            Button {
                                onJumpToSourceRange?(item.sourceRange)
                            } label: {
                                Text(item.title.isEmpty ? "Heading" : item.title)
                                    .padding(.leading, CGFloat((item.level - 1) * 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("wisk.note.outline.\(item.sourceRange.location)")
                        }
                    }
                }
            }

            if !linked.isEmpty {
                extrasSection(title: "Linked from this note", identifier: "wisk.note.linked") {
                    ForEach(linked) { linkedNote in
                        Button(linkedNote.title) {
                            openNote(linkedNote.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !backlinks.isEmpty {
                extrasSection(title: "Backlinks", identifier: "wisk.note.backlinks") {
                    ForEach(backlinks) { linkedNote in
                        Button(linkedNote.title) {
                            openNote(linkedNote.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func extrasSection<Content: View>(
        title: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
