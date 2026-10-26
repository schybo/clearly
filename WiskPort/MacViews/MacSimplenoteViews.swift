import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import ImageIO
#endif

enum MacPasteSupport {
    static let imagePasteTypes: [UTType] = [
        .image,
        .png,
        .jpeg,
        .tiff,
        .heic,
    ]

    static func hasImageContent(_ pasteboard: NSPasteboard = .general) -> Bool {
        if imagePasteTypes.contains(where: { pasteboard.data(forType: NSPasteboard.PasteboardType($0.identifier)) != nil }) {
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { WiskAttachmentImportTypes.contentType(for: $0).hasPrefix("image/") }) {
            return true
        }
        return NSImage(pasteboard: pasteboard) != nil
    }

    static func isCommandV(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .help, .function])
        return flags == .command
    }

    static func encodedImageData(from image: NSImage) -> Data? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        return encodedImageData(from: cgImage, contentType: UTType.png.identifier, quality: nil)
            ?? encodedImageData(from: cgImage, contentType: UTType.jpeg.identifier, quality: 0.92)
    }

    private static func encodedImageData(from image: CGImage, contentType: String, quality: CGFloat?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, contentType as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

typealias MacNoteSortMode = WiskNoteSortMode

enum MacSidebarSelection: Hashable, Identifiable {
    case allNotes
    case adages
    case buckets
    case trash
    case untagged
    case tag(String)

    var id: String {
        switch self {
        case .allNotes: return "all"
        case .adages: return "adages"
        case .buckets: return "buckets"
        case .trash: return "trash"
        case .untagged: return "untagged"
        case .tag(let tag): return "tag:\(tag)"
        }
    }
}

extension Notification.Name {
    static let wiskNewNote = Notification.Name("wisk.newNote")
    static let wiskNewList = Notification.Name("wisk.newList")
    static let wiskNewStructuredNote = Notification.Name("wisk.newStructuredNote")
    static let wiskNewTracker = Notification.Name("wisk.newTracker")
    static let wiskDeleteNote = Notification.Name("wisk.deleteNote")
    static let wiskInsertChecklist = Notification.Name("wisk.insertChecklist")
    static let wiskToggleMarkdownPreview = Notification.Name("wisk.toggleMarkdownPreview")
    static let wiskShowShare = Notification.Name("wisk.showShare")
    static let wiskShowAI = Notification.Name("wisk.showAI")
    static let wiskOrganizeNote = Notification.Name("wisk.organizeNote")
    static let wiskRouteNote = Notification.Name("wisk.routeNote")
    static let wiskCleanUpNote = Notification.Name("wisk.cleanUpNote")
    static let wiskFocusSearch = Notification.Name("wisk.focusSearch")
    static let wiskShowCommandPalette = Notification.Name("wisk.showCommandPalette")
    static let wiskApplyFormatting = Notification.Name("wisk.applyFormatting")
    static let wiskCopyAs = Notification.Name("wisk.copyAs")
    static let wiskExportNote = Notification.Name("wisk.exportNote")
    static let wiskImportNote = Notification.Name("wisk.importNote")
    static let wiskImportSimplenote = Notification.Name("wisk.importSimplenote")
    static let wiskImportSimplenoteJSON = Notification.Name("wisk.importSimplenoteJSON")
    static let wiskUndoSimplenoteImport = Notification.Name("wisk.undoSimplenoteImport")
    static let wiskRestoreSimplenoteDates = Notification.Name("wisk.restoreSimplenoteDates")
    static let wiskRemoveDuplicateSimplenoteNotes = Notification.Name("wisk.removeDuplicateSimplenoteNotes")
    static let wiskNoteListBecameFirstResponder = Notification.Name("wisk.noteListBecameFirstResponder")
    static let wiskPasteImageIntoSelectedNote = Notification.Name("wisk.pasteImageIntoSelectedNote")
}

struct MacCommandPaletteView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let selectedNote: Note?
    let createNote: () -> Void
    let createStructuredNote: () -> Void
    let createList: () -> Void
    let createTracker: () -> Void
    let focusSearch: () -> Void
    let showBuckets: () -> Void
    let showAllNotes: () -> Void
    let insertChecklist: () -> Void
    let toggleMarkdownPreview: () -> Void
    let showAI: () -> Void
    let cleanUpNote: () -> Void
    let routeNote: () -> Void
    let showShare: () -> Void
    let importSimplenote: () -> Void
    let undoSimplenoteImport: () -> Void
    let restoreSimplenoteDates: () -> Void
    let removeDuplicateSimplenoteNotes: () -> Void
    let emptyArchivedNotes: () -> Void
    let canUndoSimplenoteImport: Bool
    let canRestoreSimplenoteDates: Bool
    let canRemoveDuplicateSimplenoteNotes: Bool
    let canEmptyArchivedNotes: Bool
    let dismiss: () -> Void

    @State private var query = ""
    @State private var appeared = false
    @FocusState private var queryFocused: Bool

    private var commands: [MacCommandPaletteCommand] {
        [
            MacCommandPaletteCommand(title: "New Note", subtitle: "Start a blank Markdown note", systemImage: "square.and.pencil", keywords: "create write", action: createNote),
            MacCommandPaletteCommand(title: "New Structured Note", subtitle: "Create a templated capture surface", systemImage: "rectangle.stack.badge.plus", keywords: "template structure daily", action: createStructuredNote),
            MacCommandPaletteCommand(title: "New List", subtitle: "Create a checklist-style note", systemImage: "checklist", keywords: "tasks todos checklist", action: createList),
            MacCommandPaletteCommand(title: "New Tracker", subtitle: "Track counters and quick adds", systemImage: "plus.forwardslash.minus", keywords: "counter time habit", action: createTracker),
            MacCommandPaletteCommand(title: "Search Notes", subtitle: "Focus the note search field", systemImage: "magnifyingglass", keywords: "find filter", action: focusSearch),
            MacCommandPaletteCommand(title: "Show Buckets", subtitle: "Review AI suggestions and bucket definitions", systemImage: "square.stack.3d.up", keywords: "review ai triage", action: showBuckets),
            MacCommandPaletteCommand(title: "Show All Notes", subtitle: "Return to the writing library", systemImage: "note.text", keywords: "library sidebar", action: showAllNotes),
            MacCommandPaletteCommand(title: "Insert Checklist", subtitle: "Append a Markdown checklist item", systemImage: "checklist", keywords: "markdown task", isEnabled: selectedNote != nil, action: insertChecklist),
            MacCommandPaletteCommand(title: "Show Markdown Characters", subtitle: "Toggle Markdown syntax in the note editor", systemImage: "textformat.abc", keywords: "render preview source markdown syntax", isEnabled: selectedNote != nil, action: toggleMarkdownPreview),
            MacCommandPaletteCommand(title: "Review with Wisk", subtitle: "Open AI extraction and buckets for this note", systemImage: "sparkles.rectangle.stack", keywords: "ai organize buckets", isEnabled: selectedNote != nil, action: showAI),
            MacCommandPaletteCommand(title: "Clean Up", subtitle: "Group similar lines by prefix and topic", systemImage: "line.3.horizontal.decrease", keywords: "cleanup group prefix gale kite", isEnabled: selectedNote != nil, action: cleanUpNote),
            MacCommandPaletteCommand(title: "Route", subtitle: "File prefixed lines into Adages, SCHYBO, and Todoist", systemImage: "arrowshape.turn.up.right", keywords: "route file adage todoist schybo prefix", isEnabled: selectedNote != nil, action: routeNote),
            MacCommandPaletteCommand(title: "Collaborate", subtitle: "Invite a viewer to this note", systemImage: "person.2", keywords: "share invite", isEnabled: selectedNote != nil, action: showShare),
            MacCommandPaletteCommand(title: "Import Notes from Simplenote", subtitle: "Add new Simplenote notes and update ones already in Wisk", systemImage: "square.and.arrow.down", keywords: "import migrate transfer simplenote", action: importSimplenote),
            MacCommandPaletteCommand(title: "Restore Simplenote Dates", subtitle: "Reset last-edited times from the last Simplenote import", systemImage: "calendar.badge.clock", keywords: "restore dates modified simplenote sort", isEnabled: canRestoreSimplenoteDates, action: restoreSimplenoteDates),
            MacCommandPaletteCommand(title: "Remove Duplicate Simplenote Notes", subtitle: "Move extra imported copies to Trash and keep the mapped notes", systemImage: "doc.on.doc", keywords: "duplicate copies extra simplenote trash cleanup", isEnabled: canRemoveDuplicateSimplenoteNotes, action: removeDuplicateSimplenoteNotes),
            MacCommandPaletteCommand(title: "Delete All Archived Notes", subtitle: "Permanently delete every note in Archived", systemImage: "trash", keywords: "delete all permanently archived trash empty", isEnabled: canEmptyArchivedNotes, action: emptyArchivedNotes),
            MacCommandPaletteCommand(title: "Undo Last Simplenote Import", subtitle: "Move the last imported batch to Archived", systemImage: "arrow.uturn.backward", keywords: "undo import simplenote", isEnabled: canUndoSimplenoteImport, action: undoSimplenoteImport),
        ]
    }

    private var filteredCommands: [MacCommandPaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { $0.matches(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Search commands, create notes, organize with Wisk...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit {
                        runFirstCommand()
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14))
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredCommands) { command in
                        Button {
                            guard command.isEnabled else { return }
                            AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                                command.action()
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: command.systemImage)
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(command.isEnabled ? Color.accent : Color.secondary)
                                    .background((command.isEnabled ? Color.accent : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(command.isEnabled ? .primary : .secondary)
                                    Text(command.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!command.isEnabled)
                        .transition(AppMotion.transition(reduceMotion: reduceMotion))
                    }
                }
                .padding(8)
                .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: filteredCommands.map(\.id))
            }
            .frame(height: 360)
        }
        .frame(width: 520)
        .wiskGlassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: Radius.glassOverlay, style: .continuous)
        )
        .opacity(appeared ? 1 : 0)
        .animation(AppMotion.animation(AppMotion.macQuick, reduceMotion: reduceMotion), value: appeared)
        .onAppear {
            queryFocused = true
            AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                appeared = true
            }
        }
    }

    private func runFirstCommand() {
        guard let firstCommand = filteredCommands.first, firstCommand.isEnabled else { return }
        firstCommand.action()
        dismiss()
    }
}

private struct MacCommandPaletteCommand: Identifiable {
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: String
    var isEnabled = true
    let action: () -> Void

    var id: String { title }

    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(subtitle) \(keywords)".lowercased()
        return query
            .lowercased()
            .split(separator: " ")
            .allSatisfy { haystack.contains($0) }
    }
}

extension MacSidebarSelection {
    var title: String {
        switch self {
        case .allNotes: return "All Notes"
        case .adages: return "Adages"
        case .buckets: return "Buckets"
        case .trash: return "Archived"
        case .untagged: return "Untagged"
        case .tag(let tag): return "#\(tag)"
        }
    }
}

struct MacInputFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.roundedBorder)
    }
}

struct MacPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

extension View {
    func macInputField() -> some View {
        modifier(MacInputFieldModifier())
    }

    func macPanel(cornerRadius: CGFloat = 8) -> some View {
        modifier(MacPanelModifier(cornerRadius: cornerRadius))
    }
}

/// One-pass sidebar counts so a large library does not re-scan every note's tags
/// once per tag row on every SwiftUI body evaluation.
private struct MacSidebarNotesSnapshot {
    struct TagCount: Identifiable, Equatable {
        var name: String
        var count: Int
        var id: String { name }
    }

    let activeCount: Int
    let trashCount: Int
    let untaggedCount: Int
    let tags: [TagCount]

    init(notes: [Note]) {
        self.init(records: notes.map { note in
            SidebarRecord(
                id: note.id,
                deletedAt: note.deletedAt,
                tagNames: note.tags.map(\.name)
            )
        })
    }

    init(records: [NoteLibraryRecord]) {
        self.init(records: records.map { record in
            SidebarRecord(
                id: record.noteID,
                deletedAt: record.deletedAt,
                tagNames: record.tagNames
            )
        })
    }

    private struct SidebarRecord {
        var id: UUID
        var deletedAt: Date?
        var tagNames: [String]
    }

    private init(records: [SidebarRecord]) {
        var tagCounts: [String: Int] = [:]
        var activeCount = 0
        var trashCount = 0
        var untaggedCount = 0
        for record in records {
            if record.deletedAt != nil {
                trashCount += 1
                continue
            }
            activeCount += 1
            if record.tagNames.isEmpty {
                untaggedCount += 1
            } else {
                for name in record.tagNames {
                    tagCounts[name, default: 0] += 1
                }
            }
        }
        self.activeCount = activeCount
        self.trashCount = trashCount
        self.untaggedCount = untaggedCount
        self.tags = tagCounts.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { TagCount(name: $0, count: tagCounts[$0] ?? 0) }
    }
}

private final class MacSidebarSnapshotCache {
    private var key: Int?
    private var snapshot: MacSidebarNotesSnapshot?

    func snapshot(for records: [NoteLibraryRecord]) -> MacSidebarNotesSnapshot {
        let hash = WiskLibraryRecordFingerprint.hash(records)
        if hash == key, let snapshot {
            return snapshot
        }
        let computed = MacSidebarNotesSnapshot(records: records)
        key = hash
        snapshot = computed
        return computed
    }
}

struct MacNotesSidebarView: View {
    let records: [NoteLibraryRecord]
    @Binding var selection: MacSidebarSelection
    @State private var snapshotCache = MacSidebarSnapshotCache()
    @Query(filter: #Predicate<Adage> { $0.deletedAt == nil }) private var adages: [Adage]

    var body: some View {
        let snapshot = snapshotCache.snapshot(for: records)
        List(selection: $selection) {
            Section {
                sidebarRow("All Notes", systemImage: "note.text", count: snapshot.activeCount)
                    .tag(MacSidebarSelection.allNotes)
                sidebarRow("Adages", systemImage: "text.quote", count: adages.count)
                    .tag(MacSidebarSelection.adages)
                sidebarRow("Buckets", systemImage: "square.stack.3d.up", count: nil)
                    .tag(MacSidebarSelection.buckets)
                sidebarRow("Archived", systemImage: "archivebox", count: snapshot.trashCount)
                    .tag(MacSidebarSelection.trash)
                sidebarRow("Untagged", systemImage: "tag.slash", count: snapshot.untaggedCount)
                    .tag(MacSidebarSelection.untagged)
            }

            Section("Tags") {
                ForEach(snapshot.tags) { tag in
                    sidebarRow(tag.name, systemImage: "number", count: tag.count)
                        .contextMenu {
                            Button("Search tag:\(tag.name)") {
                                selection = .tag(tag.name)
                            }
                        }
                        .tag(MacSidebarSelection.tag(tag.name))
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 28)
        .navigationTitle("Wisk")
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
    }

    private func sidebarRow(_ title: String, systemImage: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
    }
}

/// Memoizes `MacNoteSearch.filteredRecords` so one list body evaluation does not
/// rebuild the filtered list more than once. Keyed on library identity
/// (`noteID`, `updatedAt`, `title`, `excerpt`) plus the other filter/sort
/// inputs — not a 3,500-element `Equatable` array.
final class MacVisibleNotesCache {
    private struct Key: Equatable {
        let recordsHash: Int
        let sidebarSelection: MacSidebarSelection
        let searchText: String
        let sortMode: MacNoteSortMode
        let includeAIFields: Bool
        let pendingHiddenNoteIDs: Set<UUID>
    }

    private var key: Key?
    private var result: [NoteLibraryRecord] = []

    func visibleRecords(
        records: [NoteLibraryRecord],
        sidebarSelection: MacSidebarSelection,
        searchText: String,
        sortMode: MacNoteSortMode,
        includeAIFields: Bool,
        pendingHiddenNoteIDs: Set<UUID>,
        compute: () -> [NoteLibraryRecord]
    ) -> [NoteLibraryRecord] {
        let newKey = Key(
            recordsHash: Self.recordsHash(records),
            sidebarSelection: sidebarSelection,
            searchText: searchText,
            sortMode: sortMode,
            includeAIFields: includeAIFields,
            pendingHiddenNoteIDs: pendingHiddenNoteIDs
        )
        if newKey == key {
            return result
        }
        let computed = compute()
        key = newKey
        result = computed
        return computed
    }

    static func recordsHash(_ records: [NoteLibraryRecord]) -> Int {
        NoteLibraryIndex.listIdentityHash(for: records)
    }
}

struct MacNoteListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAuthService.self) private var authService
    @Environment(SyncService.self) private var syncService
    @State private var visibleNotesCache = MacVisibleNotesCache()
    @State private var rowModelCache = MacNoteRowModelCache()
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    let records: [NoteLibraryRecord]
    @Binding var pendingHiddenNoteIDs: Set<UUID>
    @Binding var selectedNoteID: UUID?
    @Binding var selectedNoteIDs: Set<UUID>
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool
    let sidebarSelection: MacSidebarSelection
    @Binding var sortMode: MacNoteSortMode
    let includeAIFields: Bool
    let liveListTitle: MacLiveListTitle?
    let createNote: () -> Void
    let deleteNote: (Note) -> Void
    let restoreNote: (Note) -> Void
    let permanentlyDeleteNote: (Note) -> Void
    let togglePinned: (Note) -> Void
    let duplicateNote: (Note) -> Void
    let addTagToNotes: (String, Set<UUID>) -> Void
    let deleteNotes: (Set<UUID>) -> Void
    let restoreNotes: (Set<UUID>) -> Void
    let permanentlyDeleteNotes: (Set<UUID>) -> Void
    let emptyArchivedNotes: () -> Void

    @State private var didApplyInitialSelection = false
    @State private var didPaintList = false
    @State private var showingBulkTagSheet = false
    @State private var bulkTagDraft = ""
    @State private var pendingBulkActionIDs = Set<UUID>()

    private var visibleNotes: [NoteLibraryRecord] {
        visibleNotesCache.visibleRecords(
            records: records,
            sidebarSelection: sidebarSelection,
            searchText: debouncedSearchText,
            sortMode: sortMode,
            includeAIFields: includeAIFields,
            pendingHiddenNoteIDs: pendingHiddenNoteIDs
        ) {
            let source: [NoteLibraryRecord]
            if sidebarSelection == .trash {
                source = records
            } else {
                source = NoteLibraryIndex.excludingPendingHidden(records, pendingIDs: pendingHiddenNoteIDs)
            }
            return MacNoteSearch.filteredRecords(
                source,
                sidebarSelection: sidebarSelection,
                searchText: debouncedSearchText,
                sortMode: sortMode
            )
        }
    }

    private var pendingArchiveConfirmation: Int {
        var hasher = Hasher()
        for id in pendingHiddenNoteIDs {
            hasher.combine(id)
            hasher.combine(records.contains { $0.noteID == id && $0.deletedAt != nil })
        }
        return hasher.finalize()
    }

    var body: some View {
        let snapshot = rowModelCache.snapshot(for: visibleNotes)
        let rows = snapshot.models.map { model in
            guard let liveListTitle, liveListTitle.noteID == model.id else { return model }
            return model.replacingTitle(liveListTitle.title)
        }
        let visibleIDs = snapshot.visibleIDs
        let deletedIDs = snapshot.deletedIDs
        let pinnedIDs = snapshot.pinnedIDs
        Group {
            if rows.isEmpty {
                macEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(macLibraryEmptyKind)
                    .transition(.opacity)
            } else {
                MacNoteTableView(
                    rows: rows,
                    selectedNoteIDs: noteListSelection,
                    contextMenu: { ids in
                        noteContextMenu(
                            for: ids,
                            deletedIDs: deletedIDs,
                            pinnedIDs: pinnedIDs
                        )
                    }
                )
                .ignoresSafeArea(edges: .trailing)
                .onAppear {
                    didPaintList = true
                    selectInitialNoteIfNeeded()
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: rows.isEmpty)
        .wiskNoteListCanvas()
        .navigationTitle(sidebarSelection.title)
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search notes")
        .toolbar {
            if sidebarSelection == .trash, records.contains(where: { $0.deletedAt != nil }) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete All Permanently", systemImage: "trash", role: .destructive, action: emptyArchivedNotes)
                        .help("Delete every archived note permanently")
                        .accessibilityIdentifier("wisk.mac.noteList.deleteAllArchivedButton")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort Notes", selection: $sortMode) {
                        ForEach(MacNoteSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Label("Sort Notes", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort: \(sortMode.title)")
                .accessibilityIdentifier("wisk.mac.noteList.filterButton")
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 560)
        .onChange(of: pendingArchiveConfirmation) { _, _ in
            let remaining = NoteLibraryIndex.remainingPendingHiddenIDs(pendingHiddenNoteIDs, records: records)
            if remaining != pendingHiddenNoteIDs {
                pendingHiddenNoteIDs = remaining
            }
        }
        .animation(AppMotion.animation(AppMotion.macQuick, reduceMotion: reduceMotion), value: searchText)
        .task {
            if debouncedSearchText != searchText {
                debouncedSearchText = searchText
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                debouncedSearchText = ""
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: WiskEditorAutosave.searchDebounceDelay)
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
            }
        }
        .onChange(of: debouncedSearchText) { _, _ in
            selectReplacementIfNeeded(visibleNoteIDs: visibleIDs)
        }
        .onChange(of: visibleIDs) { _, newIDs in
            if didPaintList {
                selectInitialNoteIfNeeded()
            }
            selectReplacementIfNeeded(visibleNoteIDs: newIDs)
        }
        .sheet(isPresented: $showingBulkTagSheet) {
            MacBulkTagSheet(
                noteCount: pendingBulkActionIDs.count,
                tagDraft: $bulkTagDraft,
                add: {
                    addTagToNotes(bulkTagDraft, pendingBulkActionIDs)
                    bulkTagDraft = ""
                    pendingBulkActionIDs = []
                    showingBulkTagSheet = false
                },
                cancel: {
                    bulkTagDraft = ""
                    pendingBulkActionIDs = []
                    showingBulkTagSheet = false
                }
            )
        }
    }

    private var noteListSelection: Binding<Set<UUID>> {
        Binding(
            get: { selectedNoteIDs },
            set: { newValue in
                // SwiftUI/AppKit lists can emit a transient empty set during rebuilds.
                guard !newValue.isEmpty else { return }
                let added = newValue.subtracting(selectedNoteIDs)
                selectedNoteIDs = newValue
                if let addedID = added.first {
                    selectedNoteID = addedID
                } else if let selectedNoteID, newValue.contains(selectedNoteID) {
                    return
                } else {
                    selectedNoteID = newValue.first
                }
            }
        )
    }

    private func noteContextMenu(
        for targetIDs: Set<UUID>,
        deletedIDs: Set<UUID>,
        pinnedIDs: Set<UUID>
    ) -> NSMenu? {
        guard targetIDs.isEmpty == false else { return nil }
        let deletedCount = targetIDs.reduce(into: 0) { count, id in
            if deletedIDs.contains(id) { count += 1 }
        }
        let activeCount = targetIDs.count - deletedCount
        let activeIDs = targetIDs.filter { deletedIDs.contains($0) == false }
        let deletedTargetIDs = targetIDs.filter { deletedIDs.contains($0) }
        let menu = NSMenu()

        if activeCount > 0 {
            menu.addItem(NSMenuItem(
                title: addTagLabel(count: activeCount),
                action: nil,
                keyEquivalent: ""
            ).withHandler { [self] in
                pendingBulkActionIDs = activeIDs
                bulkTagDraft = ""
                showingBulkTagSheet = true
            })

            if activeCount == 1, let activeID = activeIDs.first {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(
                    title: pinnedIDs.contains(activeID) ? "Unpin Note" : "Pin Note",
                    action: nil,
                    keyEquivalent: ""
                ).withHandler { [self] in
                    if let note = note(withID: activeID) {
                        togglePinned(note)
                    }
                })
                menu.addItem(NSMenuItem(
                    title: "Duplicate Note",
                    action: nil,
                    keyEquivalent: ""
                ).withHandler { [self] in
                    if let note = note(withID: activeID) {
                        duplicateNote(note)
                    }
                })
            }

            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: archiveLabel(count: activeCount),
                action: nil,
                keyEquivalent: ""
            ).withHandler { [self] in
                if activeCount == 1, let note = activeIDs.first.flatMap(note(withID:)) {
                    deleteNote(note)
                } else {
                    deleteNotes(activeIDs)
                }
            })
        }

        if deletedCount > 0 {
            if activeCount > 0 {
                menu.addItem(.separator())
            }
            menu.addItem(NSMenuItem(
                title: restoreLabel(count: deletedCount),
                action: nil,
                keyEquivalent: ""
            ).withHandler { [self] in
                if deletedCount == 1, let note = deletedTargetIDs.first.flatMap(note(withID:)) {
                    restoreNote(note)
                } else {
                    restoreNotes(deletedTargetIDs)
                }
            })
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: permanentDeleteLabel(count: deletedCount),
                action: nil,
                keyEquivalent: ""
            ).withHandler { [self] in
                if deletedCount == 1, let note = deletedTargetIDs.first.flatMap(note(withID:)) {
                    permanentlyDeleteNote(note)
                } else {
                    permanentlyDeleteNotes(deletedTargetIDs)
                }
            })
        }

        return menu
    }

    @ViewBuilder
    private func contextMenu(
        for targetIDs: Set<UUID>,
        deletedIDs: Set<UUID>,
        pinnedIDs: Set<UUID>
    ) -> some View {
        if targetIDs.isEmpty {
            EmptyView()
        } else {
            let deletedCount = targetIDs.reduce(into: 0) { count, id in
                if deletedIDs.contains(id) { count += 1 }
            }
            let activeCount = targetIDs.count - deletedCount
            let activeIDs = targetIDs.filter { deletedIDs.contains($0) == false }
            let deletedTargetIDs = targetIDs.filter { deletedIDs.contains($0) }

            if activeCount > 0 {
                Button {
                    pendingBulkActionIDs = activeIDs
                    bulkTagDraft = ""
                    showingBulkTagSheet = true
                } label: {
                    Label(addTagLabel(count: activeCount), systemImage: "tag")
                }

                if activeCount == 1, let activeID = activeIDs.first {
                    Divider()

                    Button {
                        if let note = note(withID: activeID) {
                            togglePinned(note)
                        }
                    } label: {
                        Label(
                            pinnedIDs.contains(activeID) ? "Unpin Note" : "Pin Note",
                            systemImage: pinnedIDs.contains(activeID) ? "pin.slash" : "pin"
                        )
                    }

                    Button {
                        if let note = note(withID: activeID) {
                            duplicateNote(note)
                        }
                    } label: {
                        Label("Duplicate Note", systemImage: "doc.on.doc")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    if activeCount == 1, let note = activeIDs.first.flatMap(note(withID:)) {
                        deleteNote(note)
                    } else {
                        deleteNotes(activeIDs)
                    }
                } label: {
                    Label(archiveLabel(count: activeCount), systemImage: "archivebox")
                }
            }

            if activeCount > 0 && deletedCount > 0 {
                Divider()
            }

            if deletedCount > 0 {
                Button {
                    if deletedCount == 1, let note = deletedTargetIDs.first.flatMap(note(withID:)) {
                        restoreNote(note)
                    } else {
                        restoreNotes(deletedTargetIDs)
                    }
                } label: {
                    Label(restoreLabel(count: deletedCount), systemImage: "arrow.uturn.backward")
                }

                Divider()

                Button(role: .destructive) {
                    if deletedCount == 1, let note = deletedTargetIDs.first.flatMap(note(withID:)) {
                        permanentlyDeleteNote(note)
                    } else {
                        permanentlyDeleteNotes(deletedTargetIDs)
                    }
                } label: {
                    Label(permanentDeleteLabel(count: deletedCount), systemImage: "trash")
                }
            }
        }
    }

    private func note(withID id: UUID) -> Note? {
        WiskNoteFetch.note(id: id, in: modelContext)
    }

    private func addTagLabel(count: Int) -> String {
        count == 1 ? "Add Tag..." : "Add Tag to \(count) Notes..."
    }

    private func archiveLabel(count: Int) -> String {
        count == 1 ? "Archive Note" : "Archive \(count) Notes"
    }

    private func restoreLabel(count: Int) -> String {
        count == 1 ? "Restore Note" : "Restore \(count) Notes"
    }

    private func permanentDeleteLabel(count: Int) -> String {
        count == 1 ? "Delete Permanently" : "Delete \(count) Permanently"
    }

    private var macLibraryEmptyKind: WiskLibraryEmptyKind {
        WiskLibraryEmptyKind.resolve(
            hasVisibleNotes: visibleNotes.isEmpty == false,
            isUnfilteredLibrary: sidebarSelection == .allNotes
                && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isSignedIn: authService.firebaseUID != nil,
            hasCompletedAccountSync: syncService.hasCompletedAccountSync,
            syncState: syncService.state
        )
    }

    @ViewBuilder
    private var macEmptyState: some View {
        switch macLibraryEmptyKind {
        case .initialSync, .initialSyncFailed:
            WiskInitialSyncPlaceholderView(kind: macLibraryEmptyKind, onRetry: retryInitialSync)
        case .none, .contentUnavailable:
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySystemImage)
            } description: {
                Text(searchText.isEmpty ? "Create a note to get started." : "Try a different search or tag.")
            } actions: {
                if searchText.isEmpty {
                    MacEmptyCreateCard(
                        action: .newNote(
                            accessibilityIdentifier: "wisk.mac.list.empty.createNote",
                            assignsKeyboardShortcut: false,
                            action: createNote
                        )
                    )
                    .frame(maxWidth: 240)
                }
            }
        }
    }

    private func retryInitialSync() {
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }

    private var emptyTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No Results"
        }
        switch sidebarSelection {
        case .allNotes: return "No Notes"
        case .adages: return "No Adages"
        case .buckets: return "Buckets"
        case .trash: return "Archive Is Empty"
        case .untagged: return "No Untagged Notes"
        case .tag(let tag): return "No #\(tag) Notes"
        }
    }

    private var emptySystemImage: String {
        switch sidebarSelection {
        case .allNotes: return "note.text"
        case .adages: return "text.quote"
        case .buckets: return "square.stack.3d.up"
        case .trash: return "archivebox"
        case .untagged: return "tag.slash"
        case .tag: return "number"
        }
    }

    private func selectInitialNoteIfNeeded() {
        guard !didApplyInitialSelection else { return }
        if selectedNoteID == nil, let firstVisibleNoteID = visibleNotes.first?.noteID {
            selectedNoteID = firstVisibleNoteID
            selectedNoteIDs = [firstVisibleNoteID]
        }
        if selectedNoteID != nil || visibleNotes.isEmpty == false {
            didApplyInitialSelection = true
        }
    }

    private func selectReplacementIfNeeded(visibleNoteIDs: Set<UUID>) {
        selectedNoteIDs.formIntersection(visibleNoteIDs)
        if let selectedNoteID, visibleNoteIDs.contains(selectedNoteID) {
            if selectedNoteIDs.contains(selectedNoteID) == false {
                selectedNoteIDs = [selectedNoteID]
            }
            return
        }
        self.selectedNoteID = visibleNotes.first?.noteID
        if let selectedNoteID = self.selectedNoteID {
            selectedNoteIDs = [selectedNoteID]
        } else {
            selectedNoteIDs = []
        }
    }
}

private struct MacBulkTagSheet: View {
    let noteCount: Int
    @Binding var tagDraft: String
    let add: () -> Void
    let cancel: () -> Void

    private var canAdd: Bool {
        !tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Tag name", text: $tagDraft)
                    .onSubmit {
                        if canAdd { add() }
                    }
            } header: {
                Text("Add Tag")
            } footer: {
                Text("Apply a tag to \(noteCount) selected note\(noteCount == 1 ? "" : "s").")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                    Button("Add", action: add)
                        .disabled(!canAdd)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding(8)
    }
}

private enum MacNoteDateDisplay {
    static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func created(_ date: Date) -> String {
        "Created \(formatted(date))"
    }

    static func edited(_ date: Date) -> String {
        "Edited \(formatted(date))"
    }
}

private struct MacNoteDateSummary: View {
    let note: Note

    var body: some View {
        HStack(spacing: 8) {
            Label(MacNoteDateDisplay.edited(note.updatedAt), systemImage: "pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("•")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Label(MacNoteDateDisplay.created(note.createdAt), systemImage: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct MacNoteRow: View, Equatable {
    let model: MacNoteRowModel

    static func == (lhs: MacNoteRow, rhs: MacNoteRow) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if model.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.kind == .list {
                    Image(systemName: "checklist")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if model.kind == .structured {
                    Image(systemName: "rectangle.stack")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if model.kind == .tracker {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(model.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.hasShares {
                    Image(systemName: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if model.excerpt.isEmpty == false {
                Text(model.excerpt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(MacNoteDateDisplay.edited(model.updatedAt))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)

                if model.deletedAt == nil {
                    ForEach(model.tagNames, id: \.self) { name in
                        Text("#\(name)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private enum MacEditorFocus {
    case title
    case body
}

private struct MacNoteDraftBodyEditor: View {
    @Bindable var draft: WiskEditorDraft
    let noteID: UUID
    let noteBody: String
    let attachments: [NoteAttachment]
    let fontSelection: WiskEditorFontSelection
    let baseFontSize: CGFloat
    let isEditable: Bool
    let showSourceMarkers: Bool
    let searchHighlightText: String
    let wikiLinkTitles: [String]
    let jumpToSourceRange: NSRange?
    @Binding var foldedSourceLocations: Set<Int>
    @Binding var selectedMarkdownRange: Range<String.Index>?
    var editorFocus: FocusState<MacEditorFocus?>.Binding
    let horizontalInset: CGFloat
    @Binding var suppressedBodyAutosaveValue: String?
    let onDraftBodyChanged: (String) -> Void
    let onOpenWikiLink: (String) -> Void
    let onJumpHandled: () -> Void
    let onWikiQueryChanged: (String?) -> Void
    let onEditAttachmentDetails: (NoteAttachment) -> Void
    let applySlashCommand: (MacSlashCommand) -> Void
    let handleFileDrop: ([NSItemProvider]) -> Bool
    let pasteImageFromClipboard: () -> Void
    let bodyFocusRequestID: UUID?
    let onBodyFocusHandled: () -> Void

    private var showsSlashCommands: Bool {
        guard editorFocus.wrappedValue == .body, isEditable else { return false }
        let currentLine = editorMarkdown.components(separatedBy: .newlines).last ?? ""
        return currentLine == "/" || currentLine.hasPrefix("/")
    }

    /// Draft lags one frame behind `note.id` on switch. Read the note body until
    /// the draft identity matches so `openDocument` sees the real source.
    private var editorMarkdown: String {
        WiskEditorLifecycle.displayedBody(
            draftNoteID: draft.noteID,
            draftBody: draft.body,
            noteID: noteID,
            noteBody: noteBody
        )
    }

    private var markdownBinding: Binding<String> {
        Binding(
            get: { editorMarkdown },
            set: { newValue in
                guard draft.noteID == noteID else { return }
                draft.body = newValue
            }
        )
    }

    private var selectedRangeBinding: Binding<Range<String.Index>?> {
        Binding(
            get: {
                WiskEditorLifecycle.displayedSelection(
                    draftNoteID: draft.noteID,
                    draftSelection: selectedMarkdownRange,
                    noteID: noteID
                )
            },
            set: { newValue in
                guard draft.noteID == noteID else { return }
                selectedMarkdownRange = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WiskRichMarkdownEditor(
                markdownText: markdownBinding,
                selectedMarkdownRange: selectedRangeBinding,
                attachments: attachments,
                fontSelection: fontSelection,
                baseFontSize: baseFontSize,
                isEditable: isEditable,
                showSourceMarkers: showSourceMarkers,
                searchHighlightText: searchHighlightText,
                contentGutter: horizontalInset,
                wikiLinkTitles: wikiLinkTitles,
                jumpToSourceRange: jumpToSourceRange,
                foldedSourceLocations: $foldedSourceLocations,
                documentIdentity: noteID,
                accessibilityIdentifier: "wisk.mac.note.bodyEditor",
                onFocusChange: { isFocused in
                    editorFocus.wrappedValue = isFocused ? .body : nil
                },
                onOpenWikiLink: onOpenWikiLink,
                onJumpHandled: onJumpHandled,
                onWikiQueryChanged: onWikiQueryChanged,
                onEditAttachmentDetails: onEditAttachmentDetails,
                onPasteImage: pasteImageFromClipboard,
                bodyFocusRequestID: bodyFocusRequestID,
                onBodyFocusHandled: onBodyFocusHandled
            )
            .focusedValue(\.wiskEditorBodyFocused, editorFocus.wrappedValue == .body)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.macEditorBackground)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: handleFileDrop)
            .onPasteCommand(of: MacPasteSupport.imagePasteTypes) { _ in
                pasteImageFromClipboard()
            }

            if showsSlashCommands {
                MacSlashCommandBar(apply: applySlashCommand)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            MacImagePasteKeyMonitor(
                isActive: isEditable
                    && editorFocus.wrappedValue != .title
                    && (editorFocus.wrappedValue == .body || WiskMacBodyEditorFocus.isFirstResponder),
                pasteImage: pasteImageFromClipboard
            )
        )
        .onChange(of: draft.body) { _, newBody in
            if suppressedBodyAutosaveValue == newBody {
                suppressedBodyAutosaveValue = nil
                return
            }
            onDraftBodyChanged(newBody)
        }
    }
}

private struct WiskEditorDetailWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct MacNoteEditorView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Environment(NoteParsingService.self) private var parsingService
    @Environment(BackgroundNoteOrganizer.self) private var organizer
    @Environment(SyncService.self) private var syncService
    @Environment(WiskAttachmentService.self) private var attachmentService
    @Environment(WiskFontManager.self) private var fontManager
    @Environment(\.wiskOpenNote) private var openNote
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var activeBuckets: [NoteBucket]

    @Bindable var note: Note
    let libraryRecords: [NoteLibraryRecord]
    let searchText: String
    @Binding var titleSelectionRequestNoteID: UUID?
    @Binding var liveListTitle: MacLiveListTitle?
    let deleteNote: () -> Void
    let restoreNote: () -> Void
    let permanentlyDeleteNote: () -> Void

    @AppStorage(WiskEditorDefaults.macFontSizeKey) private var editorFontSize = WiskEditorDefaults.defaultFontSize
    @AppStorage(WiskEditorDefaults.showMarkdownSyntaxKey) private var showMarkdownSyntax = false
    @AppStorage(WiskEditorDefaults.showReviewPanelKey) private var showReviewPanel = true
    @State private var editorDetailWidth: CGFloat = 800
    @State private var tagDraft = ""
    @State private var shareEmail = ""
    @State private var publishSlug = ""
    @State private var statusMessage: String?
    @State private var isRouting = false
    @State private var routeSettings = NoteRouteSettings.shared
    @State private var showingShare = false
    @State private var showingPublish = false
    @State private var showingInfo = false
    @State private var showingTags = false
    @State private var showingAI = false
    @State private var showingFormattingOverlay = false
    @State private var showingListStatusEditor = false
    @State private var listItemDraft = ""
    @State private var trackerCounterDraft = ""
    @State private var trackerMemoDraft = ""
    @State private var trackerUnitDraft = ""
    @State private var trackerQuickAddsDraft = ""
    @State private var structuredTemplateTitle = ""
    @State private var structuredQuickAddDrafts: [String: String] = [:]
    @State private var structuredSectionTitleFocusRequestID: String?
    @State private var structuredSectionScrollRequestID: String?
    @State private var activeStructuredSectionID: String?
    @State private var showingSaveStructuredTemplateAlert = false
    @State private var showingImageImporter = false
    @State private var showingFileImporter = false
    @State private var showingSketchSheet = false
    @State private var suppressedBodyAutosaveValue: String?
    @State private var suppressNextMarkdownAutosave = false
    @State private var editorAutosave = WiskEditorAutosave()
    @State private var draft = WiskEditorDraft()
    @State private var needsCommit = false
    @State private var autosaveTarget: Note?
    @State private var bodySelection: TextSelection?
    @State private var richBodySelection: Range<String.Index>?
    @State private var structuredRichSelections: [String: Range<String.Index>] = [:]
    @State private var jumpToSourceRange: NSRange?
    @State private var wikiQuery: String?
    @State private var foldedSourceLocations: Set<Int> = []
    @State private var attachmentDetails: NoteAttachment?
    @FocusState private var editorFocus: MacEditorFocus?
    @FocusState private var listItemFocused: Bool
    @State private var bodyFocusRequestID: UUID?
    @State private var reviewPanelLaidOut = true
    @State private var detailWidthCoalescer = WiskWidthCoalescer()
    @State private var detailWidthSettleTask: Task<Void, Never>?

    var body: some View {
        editorWithSheets
            .navigationTitle(displayedTitle.isEmpty ? "Untitled" : displayedTitle)
            .navigationSubtitle(MacNoteDateDisplay.edited(note.updatedAt))
    }

    private var editorChrome: some View {
        ZStack(alignment: .bottom) {
            editorChromeColumns
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WiskEditorDetailWidthKey.self, value: geometry.size.width)
                    }
                }
                .onPreferenceChange(WiskEditorDetailWidthKey.self) { width in
                    considerDetailWidth(width)
                }
                .onChange(of: showReviewPanel) { _, enabled in
                    reviewPanelLaidOut = WiskEditorChromeLayout.showsReviewPanel(
                        availableWidth: editorDetailWidth,
                        currentlyShowing: enabled && reviewPanelLaidOut,
                        userEnabled: enabled
                    )
                }

            if showsFormattingOverlay {
                GlassEffectContainer {
                    macFormattingOverlay
                }
            }
        }
        .wiskEditorCanvas()
    }

    @ViewBuilder
    private var editorChromeColumns: some View {
        let showsReviewPanel = laidOutReviewPanel
        let editorAvailableWidth = WiskEditorChromeLayout.editorAvailableWidth(
            detailWidth: editorDetailWidth,
            showsReviewPanel: showsReviewPanel
        )
        let editorInset = WiskEditorChromeLayout.horizontalInset(for: editorAvailableWidth)

        if showsReviewPanel {
            HSplitView {
                editorColumn(horizontalInset: editorInset)
                    .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                MacInlineReviewPanel(
                    note: note,
                    buckets: activeBuckets,
                    hasProAccess: proEntitlement.hasProAccess,
                    organizationPhase: organizationPhase,
                    organizeNow: proEntitlement.hasProAccess ? organizeNow : { openProUpgrade(.ai) },
                    hideReview: { showReviewPanel = false },
                    acceptItem: toggleAccepted,
                    rejectItem: reject,
                    assignBucket: assignBucket
                )
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 330, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            editorColumn(horizontalInset: editorInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var editorWithDraftPersistence: some View {
        editorChrome
        .onChange(of: draft.title) { _, newTitle in
            publishLiveListTitle()
            guard WiskEditorLifecycle.shouldScheduleIdlePersist(
                draftNoteID: draft.noteID,
                boundNoteID: note.id,
                draftValue: newTitle,
                noteValue: note.title
            ) else { return }
            editorAutosave.schedule { persistIdleDraft() }
        }
        .onChange(of: draft.body) { _, _ in
            publishLiveListTitle()
        }
        .onChange(of: WiskEditorNoteIdentity(id: note.id, markdownEnabled: note.markdownEnabled)) { old, new in
            if old.id != new.id {
                let leavingNote = autosaveTarget
                let captured = leavingDraft(from: leavingNote)
                persistLeavingNote(leavingNote, captured: captured)
                foldedSourceLocations = WiskEditorSessionCache.shared.snapshot(id: new.id)?.foldedLocations ?? []
                autosaveTarget = note
                resetTransientEditorState()
                loadEditorDraftFromNote()
                requestNewNoteBodyFocusIfNeeded()
                return
            }
            if suppressNextMarkdownAutosave {
                suppressNextMarkdownAutosave = false
                return
            }
            saveAndQueue()
        }
        .onChange(of: note.body) { _, newBody in
            guard editorAutosave.hasPending == false, newBody != draft.body else { return }
            draft.body = newBody
        }
        .onChange(of: note.title) { _, newTitle in
            guard editorAutosave.hasPending == false, newTitle != draft.title else { return }
            draft.title = newTitle
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                commitEditorDraft(to: autosaveTarget ?? note)
            }
        }
        .onAppear {
            autosaveTarget = note
            loadEditorDraftFromNote()
            consumePendingJump()
            syncTrackerDrafts()
            requestNewNoteBodyFocusIfNeeded()
            selectTitleIfRequested()
        }
        .onDisappear {
            detailWidthSettleTask?.cancel()
            commitEditorDraft(to: autosaveTarget ?? note)
        }
    }

    private var editorWithLifecycle: some View {
        editorWithDraftPersistence
        .task(id: attachmentHydrationKey) {
            for attachment in note.attachments
            where attachment.deletedAt == nil
                && attachment.localCachePath == nil
                && attachment.storagePath != nil {
                _ = await attachmentService.data(for: attachment)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskNoteListBecameFirstResponder)) { _ in
            editorFocus = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskPasteImageIntoSelectedNote)) { _ in
            pasteImageIntoOpenNoteFromList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskToggleMarkdownPreview)) { _ in
            toggleMarkdownSyntax()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskShowShare)) { _ in
            showingShare = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskShowAI)) { _ in
            presentReview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskOrganizeNote)) { _ in
            if proEntitlement.hasProAccess {
                organizeNow()
            } else {
                openProUpgrade(.ai)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskRouteNote)) { _ in
            routeNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskCleanUpNote)) { _ in
            cleanUpNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskApplyFormatting)) { notification in
            guard note.deletedAt == nil,
                  let action = notification.object as? WiskMarkdownFormattingAction,
                  formattingControlsEnabled else { return }
            applyFormatting(action)
            editorFocus = .body
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskCopyAs)) { notification in
            guard let format = notification.object as? WiskCopyAsFormat else { return }
            copyAs(format)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskExportNote)) { notification in
            guard let format = notification.object as? WiskExportFormat else { return }
            exportNote(format)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiskImportNote)) { _ in
            importNote()
        }
    }

    private var editorWithSheets: some View {
        editorWithLifecycle
        .sheet(isPresented: $showingShare) {
            MacShareView(note: note, email: $shareEmail) {
                saveAndQueue()
            }
        }
        .sheet(isPresented: $showingPublish) {
            MacPublishView(note: note, slug: $publishSlug) {
                saveAndQueue()
            }
        }
        .sheet(isPresented: $showingAI) {
            MacAIInspectorView(
                note: note,
                buckets: activeBuckets,
                hasProAccess: proEntitlement.hasProAccess,
                organizationPhase: organizationPhase,
                statusMessage: $statusMessage,
                organizeNow: proEntitlement.hasProAccess ? organizeNow : { openProUpgrade(.ai) },
                acceptItem: toggleAccepted,
                rejectItem: reject,
                assignBucket: assignBucket
            )
        }
        .sheet(isPresented: $showingListStatusEditor) {
            ChecklistStatusEditorSheet(list: NoteChecklist.list(from: note.body)) { updatedList in
                note.body = NoteChecklist.body(from: updatedList)
                saveAndQueue(snapshotReason: "list", fromDraft: false)
            }
            .frame(width: 520, height: 520)
        }
        .sheet(isPresented: $showingSketchSheet) {
            MacSketchSheet { data in
                insertAttachment(from: data, altText: "Sketch", structuredSectionID: activeStructuredFormattingSectionID)
            }
            .frame(width: 720, height: 560)
        }
        .alert("Save Structure as Template", isPresented: $showingSaveStructuredTemplateAlert) {
            TextField("Template name", text: $structuredTemplateTitle)
            Button("Save") {
                saveStructuredTemplate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wisk will save section names, order, and collapsed defaults for future notes.")
        }
        .popover(isPresented: $showingTags) {
            MacTagEditor(note: note, tagDraft: $tagDraft) {
                saveAndQueue()
            }
        }
        .inspector(isPresented: $showingInfo) {
            MacNoteInfoView(
                note: note,
                listings: showingInfo ? libraryListings : [],
                foldedSourceLocations: $foldedSourceLocations
            ) { range in
                jumpToSourceRange = range
            }
            .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar {
            MacNoteToolbar(
                note: note,
                showMarkdownSyntax: $showMarkdownSyntax,
                showingInfo: $showingInfo,
                showingShare: $showingShare,
                showingPublish: $showingPublish,
                showingTags: $showingTags,
                showingFormattingOverlay: $showingFormattingOverlay,
                isReviewPanelVisible: isReviewPanelVisible,
                isOrganizing: organizationPhase.isOrganizing,
                formattingControlsEnabled: formattingControlsEnabled,
                formattingControlsHelp: formattingControlsHelp,
                toggleMarkdownSyntax: toggleMarkdownSyntax,
                toggleReview: toggleReview,
                presentReview: presentReview,
                organizeNow: proEntitlement.hasProAccess ? organizeNow : { openProUpgrade(.ai) },
                cleanUpNow: cleanUpNow,
                routeNow: routeNow,
                isRouting: isRouting,
                canRoute: NoteLineRouter.unavailableReason(
                    mappings: routeSettings.mappings,
                    todoistConnected: routeSettings.isTodoistConnected,
                    schyboConnected: routeSettings.isSchyboConnected
                ) == nil,
                routeHelp: routeHelp,
                addStructuredSection: structuredAddSectionAction,
                saveStructuredTemplate: structuredSaveTemplateAction,
                deleteNote: deleteNote,
                restoreNote: restoreNote,
                permanentlyDeleteNote: permanentlyDeleteNote
            )
        }
        .modifier(WiskNoteEditorChrome(
            noteID: note.id,
            attachmentDetails: $attachmentDetails,
            onJump: consumePendingJump,
            onSaveAttachment: { saveAndQueue() }
        ))
        .fileImporter(isPresented: $showingImageImporter, allowedContentTypes: [.image]) { result in
            handleImageImport(result)
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: WiskAttachmentImportTypes.fileTypes) { result in
            handleFileImport(result)
        }
    }

    private var isReviewPanelVisible: Bool {
        laidOutReviewPanel
    }

    private var organizationPhase: WiskNoteOrganizationPhase {
        WiskNoteOrganizationPhase(organizer: organizer.state, parsing: parsingService.state)
    }

    private var laidOutReviewPanel: Bool {
        WiskEditorChromeLayout.showsReviewPanel(
            availableWidth: editorDetailWidth,
            currentlyShowing: reviewPanelLaidOut,
            userEnabled: showReviewPanel
        )
    }

    private func considerDetailWidth(_ width: CGFloat) {
        switch detailWidthCoalescer.noteWidth(width) {
        case .unchanged:
            return
        case .commitNow(let committed):
            detailWidthSettleTask?.cancel()
            applySettledDetailWidth(committed)
        case .deferUntilSettled:
            detailWidthSettleTask?.cancel()
            detailWidthSettleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: WiskEditorPerformance.widthSettleNanoseconds)
                guard !Task.isCancelled else { return }
                if let settled = detailWidthCoalescer.settle() {
                    applySettledDetailWidth(settled)
                }
            }
        }
    }

    private func applySettledDetailWidth(_ width: CGFloat) {
        editorDetailWidth = width
        reviewPanelLaidOut = WiskEditorChromeLayout.showsReviewPanel(
            availableWidth: width,
            currentlyShowing: reviewPanelLaidOut,
            userEnabled: showReviewPanel
        )
    }

    private func toggleReview() {
        if editorDetailWidth >= WiskEditorChromeLayout.reviewShowWidth {
            showReviewPanel.toggle()
        } else {
            showingAI.toggle()
        }
    }

    private func presentReview() {
        if editorDetailWidth >= WiskEditorChromeLayout.reviewShowWidth {
            showReviewPanel = true
        } else {
            showingAI = true
        }
    }

    private func openProUpgrade(_ context: WiskProUpgradeContext) {
        openWindow(id: "wisk-pro", value: context)
    }

    @ViewBuilder
    private func editorColumn(horizontalInset: CGFloat) -> some View {
        Group {
            if note.kind == .structured {
                VStack(alignment: .leading, spacing: 0) {
                    editorColumnChrome(horizontalInset: horizontalInset)
                    ScrollViewReader { proxy in
                        ScrollView {
                            editorColumnScrollContent(horizontalInset: horizontalInset)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .defaultScrollAnchor(.top)
                        .onChange(of: structuredSectionScrollRequestID) { _, sectionID in
                            scrollToStructuredSection(sectionID, proxy: proxy)
                        }
                    }
                }
            } else {
                editorColumnContent(horizontalInset: horizontalInset)
            }
        }
        .ignoresSafeArea(edges: .trailing)
    }

    private func scrollToStructuredSection(_ sectionID: String?, proxy: ScrollViewProxy) {
        guard let sectionID else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            proxy.scrollTo(sectionID, anchor: .top)
            structuredSectionScrollRequestID = nil
        }
    }

    private func editorColumnContent(horizontalInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editorColumnChrome(horizontalInset: horizontalInset)
            editorColumnScrollContent(horizontalInset: horizontalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editorColumnChrome(horizontalInset: CGFloat) -> some View {
        TextField("Title", text: draftTitleBinding)
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, horizontalInset)
            .padding(.top, 16)
            .padding(.bottom, 0)
            .focused($editorFocus, equals: .title)
            .onSubmit {
                editorFocus = note.kind == .general || note.kind == .daily ? .body : nil
            }
            .disabled(note.deletedAt != nil)
    }

    private func editorColumnScrollContent(horizontalInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editor(horizontalInset: horizontalInset)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, 8)
            }
        }
    }

    private var structuredAddSectionAction: (() -> Void)? {
        guard note.kind == .structured else { return nil }
        return addStructuredSection
    }

    private var structuredSaveTemplateAction: (() -> Void)? {
        guard note.kind == .structured else { return nil }
        return showSaveStructuredTemplateAlert
    }

    private func showSaveStructuredTemplateAlert() {
        structuredTemplateTitle = note.title.nilIfEmpty ?? "Custom Template"
        showingSaveStructuredTemplateAlert = true
    }

    @ViewBuilder
    private func editor(horizontalInset: CGFloat) -> some View {
        if note.kind == .list {
            MacChecklistEditorView(
                checklist: NoteChecklist.list(from: note.body),
                itemDraft: $listItemDraft,
                itemFocused: $listItemFocused,
                addItem: addListItem,
                toggleItem: toggleListItem,
                setStatus: setListItemStatus,
                deleteItem: deleteListItem,
                clearCompleted: clearCompletedListItems,
                customizeStatuses: customizeListStatuses,
                applyTemplate: applyListStatusTemplate,
                convertToChecklist: convertListToChecklist,
                editStatuses: { showingListStatusEditor = true }
            )
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 16)
            .disabled(note.deletedAt != nil)
        } else if note.kind == .structured {
            MacStructuredNoteEditorView(
                structuredNote: NoteStructuredSections.structuredNote(from: note.body),
                attachments: note.attachments,
                richSelections: Binding(
                    get: {
                        WiskEditorLifecycle.displayedSelection(
                            draftNoteID: draft.noteID,
                            draftSelection: structuredRichSelections,
                            noteID: note.id
                        ) ?? [:]
                    },
                    set: { newValue in
                        guard draft.noteID == note.id else { return }
                        structuredRichSelections = newValue
                    }
                ),
                quickAddDrafts: $structuredQuickAddDrafts,
                activeSectionID: $activeStructuredSectionID,
                titleFocusRequestSectionID: $structuredSectionTitleFocusRequestID,
                titleForSection: sectionTitle,
                bodyForSection: sectionBody,
                updateTitle: updateStructuredSectionTitle,
                updateBody: updateStructuredSectionBody,
                pasteImage: { sectionID, utf16Range in
                    pasteImageIntoStructuredSection(sectionID, utf16Range: utf16Range)
                },
                toggleSection: toggleStructuredSection,
                addQuickItems: addStructuredQuickItems,
                setMode: setStructuredSectionMode,
                moveSection: moveStructuredSection,
                deleteSection: deleteStructuredSection,
                toggleChecklistItem: toggleStructuredChecklistItem,
                deleteChecklistItem: deleteStructuredChecklistItem
            )
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 16)
            .disabled(note.deletedAt != nil)
        } else if note.kind == .tracker {
            MacTrackerEditorView(
                tracker: NoteTrackerStore.tracker(from: note.body),
                counterDraft: $trackerCounterDraft,
                memoDraft: $trackerMemoDraft,
                unitDraft: $trackerUnitDraft,
                quickAddsDraft: $trackerQuickAddsDraft,
                addCounter: addTrackerCounter,
                record: recordTrackerEvent,
                archiveCounter: archiveTrackerCounter,
                undoLastEvent: undoLastTrackerEvent,
                saveSettings: saveTrackerSettings
            )
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 16)
            .disabled(note.deletedAt != nil)
        } else {
            MacNoteDraftBodyEditor(
                draft: draft,
                noteID: note.id,
                noteBody: note.body,
                attachments: note.attachments,
                fontSelection: fontManager.selection,
                baseFontSize: editorFontSize,
                isEditable: note.deletedAt == nil,
                showSourceMarkers: showMarkdownSyntax,
                searchHighlightText: searchText,
                wikiLinkTitles: wikiLinkTitles,
                jumpToSourceRange: jumpToSourceRange,
                foldedSourceLocations: $foldedSourceLocations,
                selectedMarkdownRange: $richBodySelection,
                editorFocus: $editorFocus,
                horizontalInset: horizontalInset,
                suppressedBodyAutosaveValue: $suppressedBodyAutosaveValue,
                onDraftBodyChanged: { newBody in
                    publishLiveListTitle()
                    guard WiskEditorLifecycle.shouldScheduleIdlePersist(
                        draftNoteID: draft.noteID,
                        boundNoteID: note.id,
                        draftValue: newBody,
                        noteValue: note.body
                    ) else { return }
                    editorAutosave.schedule { persistIdleDraft() }
                },
                onOpenWikiLink: openWikiLink,
                onJumpHandled: { jumpToSourceRange = nil },
                onWikiQueryChanged: { query in
                    wikiQuery = query
                },
                onEditAttachmentDetails: { attachmentDetails = $0 },
                applySlashCommand: applySlashCommand,
                handleFileDrop: handleFileDrop,
                pasteImageFromClipboard: pasteImageFromClipboard,
                bodyFocusRequestID: bodyFocusRequestID,
                onBodyFocusHandled: { bodyFocusRequestID = nil }
            )
        }
    }

    private func toggleMarkdownSyntax() {
        showingFormattingOverlay = false
        showMarkdownSyntax.toggle()
        save()
    }

    private var attachmentHydrationKey: String {
        note.attachments
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                [
                    $0.id.uuidString,
                    $0.storagePath ?? "",
                    $0.localCachePath ?? "",
                    $0.deletedAt?.ISO8601Format() ?? "",
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    private var showsFormattingOverlay: Bool {
        guard showingFormattingOverlay else { return false }
        return formattingControlsEnabled
    }

    private var formattingControlsEnabled: Bool {
        switch note.kind {
        case .general, .daily:
            return true
        case .structured:
            return activeStructuredFormattingSectionID != nil
        case .list, .tracker:
            return false
        }
    }

    private var formattingControlsHelp: String {
        switch note.kind {
        case .general, .daily:
            return "Show formatting controls"
        case .structured:
            return activeStructuredFormattingSectionID == nil
                ? "Focus a text section body before formatting."
                : "Show formatting controls for the focused section"
        case .list, .tracker:
            return "Formatting controls are available in notes and structured text sections."
        }
    }

    private var activeStructuredFormattingSectionID: String? {
        guard note.kind == .structured, let activeStructuredSectionID else { return nil }
        let structuredNote = NoteStructuredSections.structuredNote(from: note.body)
        guard structuredNote.sections.contains(where: {
            $0.id == activeStructuredSectionID && !$0.isCollapsed && $0.mode != .checklist
        }) else {
            return nil
        }
        return activeStructuredSectionID
    }

    private var macFormattingOverlay: some View {
        WiskFormattingBar(applyFormatting: applyFormatting, accessoryPlacement: .leading) {
            Button {
                showingFormattingOverlay = false
                showingSketchSheet = true
            } label: {
                Label("Sketch", systemImage: "scribble")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: [.command, .option])
            .accessibilityIdentifier("wisk.mac.note.sketchButton")

            Button {
                NotificationCenter.default.post(name: .wiskFindInNote, object: nil)
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("f", modifiers: [.command, .option])
            .accessibilityIdentifier("wisk.mac.note.findButton")

            Button {
                pasteImageFromClipboard()
            } label: {
                Label("Paste Image", systemImage: "doc.on.clipboard")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("v", modifiers: [.command, .option])

            Button {
                showingFormattingOverlay = false
                showingImageImporter = true
            } label: {
                Label("Insert Image", systemImage: "photo")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showingFormattingOverlay = false
                showingFileImporter = true
            } label: {
                Label("Insert File", systemImage: "paperclip")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .wiskGlassEffect(.regular.interactive(), in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var displayedTitle: String {
        WiskEditorLifecycle.displayedTitle(
            draftNoteID: draft.noteID,
            draftTitle: draft.title,
            noteID: note.id,
            noteTitle: note.title,
            libraryTitle: libraryRecordTitle
        )
    }

    private var liveListDisplayTitle: String {
        NoteLibraryIndex.displayTitle(
            title: displayedTitle,
            body: WiskEditorLifecycle.displayedBody(
                draftNoteID: draft.noteID,
                draftBody: draft.body,
                noteID: note.id,
                noteBody: note.body
            ),
            kind: note.kind
        )
    }

    private func publishLiveListTitle() {
        liveListTitle = MacLiveListTitle(noteID: note.id, title: liveListDisplayTitle)
    }

    private var libraryRecordTitle: String? {
        libraryRecords.first { $0.noteID == note.id }?.title
    }

    private var libraryListings: [WiskNoteLinkListing] {
        libraryRecords.map(WiskNoteLinkListing.init(record:))
    }

    private var draftTitleBinding: Binding<String> {
        Binding(
            get: { displayedTitle },
            set: { newValue in
                guard draft.noteID == note.id else { return }
                draft.title = newValue
            }
        )
    }

    private func applySlashCommand(_ command: MacSlashCommand) {
        note.markdownEnabled = true
        draft.body = command.apply(to: draft.body)
        bodySelection = nil
        editorFocus = .body
        saveAndQueue(snapshotReason: "slash-command")
    }

    private func applyFormatting(_ action: WiskMarkdownFormattingAction) {
        if WiskActiveMarkdownEditor.apply(action) {
            if note.markdownEnabled == false {
                note.markdownEnabled = true
            }
            if let sectionID = activeStructuredFormattingSectionID {
                activeStructuredSectionID = sectionID
            }
            bodySelection = nil
            saveAndQueue()
            return
        }
        note.markdownEnabled = true
        if let sectionID = activeStructuredFormattingSectionID {
            let section = sectionBody(sectionID)
            let updatedSectionBody: String
            if let mutation = WiskMarkdownDocumentEngine.apply(
                action,
                to: section,
                sourceRange: NSRange(location: 0, length: 0)
            ) {
                updatedSectionBody = mutation.source
            } else {
                updatedSectionBody = WiskMarkdownFormatter.apply(action, to: section)
            }
            note.body = NoteStructuredSections.updatingSectionBody(id: sectionID, sectionBody: updatedSectionBody, in: note.body)
            activeStructuredSectionID = sectionID
            saveAndQueue(fromDraft: false)
            return
        }
        let sourceRange = WiskRichMarkdownDocument.replacingCollapsedDocumentEnd(
            formattingSourceRange,
            textLength: (draft.body as NSString).length
        )
        if let mutation = WiskMarkdownDocumentEngine.apply(
            action,
            to: draft.body,
            sourceRange: sourceRange
        ) {
            draft.body = mutation.source
            richBodySelection = Range(mutation.selectedSourceRange, in: draft.body)
        } else {
            draft.body = WiskMarkdownFormatter.apply(action, to: draft.body, selectedRange: formattingTargetRange)
            richBodySelection = nil
        }
        bodySelection = nil
        saveAndQueue()
    }

    private func pasteImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let image = imageDataFromPasteboard(pasteboard) {
            insertAttachment(from: image.data, altText: image.altText)
            return
        }
        statusMessage = "Copy a screenshot or image first."
    }

    private func pasteImageIntoOpenNoteFromList() {
        guard note.deletedAt == nil else { return }
        switch note.kind {
        case .general, .daily:
            pasteImageFromClipboard()
        case .structured:
            let structuredNote = NoteStructuredSections.structuredNote(from: note.body)
            let sectionID = activeStructuredSectionID
                ?? structuredNote.sections.first(where: { !$0.isCollapsed && $0.mode != .checklist })?.id
                ?? structuredNote.sections.first?.id
            guard let sectionID else { return }
            pasteImageIntoStructuredSection(sectionID)
        case .list, .tracker:
            break
        }
    }

    private func copyAs(_ format: WiskCopyAsFormat) {
        let source = selectedBodyRange.map { String(draft.body[$0]) } ?? draft.body
        Task {
            var attachmentSnapshots: [WiskNoteInterchange.AttachmentSnapshot] = []
            for attachment in note.attachments where source.contains(attachment.id.uuidString) {
                guard let data = await attachmentService.data(for: attachment) else { continue }
                attachmentSnapshots.append(.init(
                    id: attachment.id,
                    fileName: attachment.fileName,
                    contentType: attachment.contentType,
                    data: data,
                    altText: attachment.altText
                ))
            }
            let snapshot = WiskNoteInterchange.NoteSnapshot(
                title: draft.title,
                body: source,
                attachments: attachmentSnapshots
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            switch format {
            case .plainText:
                let document = WiskNoteInterchange.exportPlainText(snapshot)
                pasteboard.setString(String(data: document.data, encoding: .utf8) ?? "", forType: .string)
            case .markdown:
                pasteboard.setString(source, forType: .string)
                pasteboard.setString(
                    source,
                    forType: NSPasteboard.PasteboardType((UTType(filenameExtension: "md") ?? .plainText).identifier)
                )
            case .richText:
                guard let document = WiskNoteInterchange.exportRTF(snapshot) else {
                    statusMessage = "Rich text could not be created."
                    return
                }
                pasteboard.setData(document.data, forType: .rtf)
            case .html:
                let document = WiskNoteInterchange.exportHTML(snapshot)
                pasteboard.setData(document.data, forType: .html)
            }
            statusMessage = "Copied as \(format.title)."
        }
    }

    private func exportNote(_ format: WiskExportFormat) {
        statusMessage = "Preparing \(format.title) export..."
        Task {
            let snapshot = await interchangeSnapshot(body: draft.body)
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(safeExportBaseName(note.title)).\(exportFileExtension(format))"
            panel.allowedContentTypes = [exportContentType(format)]
            guard panel.runModal() == .OK, let destination = panel.url else {
                statusMessage = nil
                return
            }
            do {
                switch format {
                case .markdown:
                    try WiskNoteInterchange.exportMarkdown(snapshot).data.write(to: destination, options: .atomic)
                case .textBundle:
                    let bundle = WiskNoteInterchange.exportTextBundle(snapshot)
                    try? FileManager.default.removeItem(at: destination)
                    for file in bundle.files {
                        let fileURL = destination.appendingPathComponent(file.relativePath)
                        try FileManager.default.createDirectory(
                            at: fileURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try file.data.write(to: fileURL, options: .atomic)
                    }
                case .richText:
                    guard let document = WiskNoteInterchange.exportRTF(snapshot) else {
                        statusMessage = "Rich text could not be created."
                        return
                    }
                    try document.data.write(to: destination, options: .atomic)
                case .html:
                    try WiskNoteInterchange.exportHTML(snapshot).data.write(to: destination, options: .atomic)
                case .pdf:
                    let payload = WiskNoteInterchange.printablePayload(snapshot)
                    try macPDFData(fromHTML: payload.html).write(to: destination, options: .atomic)
                }
                statusMessage = "Exported \(format.title)."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func importNote() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
            UTType(filenameExtension: "textbundle") ?? .package,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        statusMessage = "Importing \(url.lastPathComponent)..."
        Task {
            do {
                let imported = try await Task.detached {
                    try WiskNoteInterchange.importDocument(at: url)
                }.value
                applyInterchangeImport(
                    imported,
                    suggestedTitle: url.deletingPathExtension().lastPathComponent
                )
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func confirmReplacingCurrentNoteForImport() -> Bool {
        guard note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || note.attachments.contains(where: { $0.deletedAt == nil })
        else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Replace this note with the import?"
        alert.informativeText = "The current note body will be replaced. Its existing attachments remain available until you remove them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace and Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func applyInterchangeImport(
        _ imported: WiskNoteInterchange.ImportResult,
        suggestedTitle: String
    ) {
        guard confirmReplacingCurrentNoteForImport() else {
            statusMessage = nil
            return
        }
        var pendingUploads: [(NoteAttachment, Data)] = []
        do {
            for descriptor in imported.attachments {
                let attachment = try attachmentService.makePendingFileAttachment(
                    from: descriptor.data,
                    fileName: descriptor.fileName,
                    contentType: descriptor.contentType,
                    note: note
                )
                attachment.id = descriptor.id
                attachment.altText = descriptor.fileName
                note.attachments.append(attachment)
                pendingUploads.append((attachment, descriptor.data))
            }
            note.body = imported.body
            note.markdownEnabled = true
            if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note.title = suggestedTitle
            }
            saveAndQueue(fromDraft: false)
            statusMessage = pendingUploads.isEmpty
                ? "Imported Markdown."
                : "Imported Markdown and \(pendingUploads.count) attachments."
            for (attachment, data) in pendingUploads {
                Task {
                    await attachmentService.upload(attachment, data: data, noteID: note.id)
                    saveAndQueue()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func interchangeSnapshot(body: String) async -> WiskNoteInterchange.NoteSnapshot {
        var snapshots: [WiskNoteInterchange.AttachmentSnapshot] = []
        for attachment in note.attachments where body.contains(attachment.id.uuidString) {
            guard let data = await attachmentService.data(for: attachment) else { continue }
            snapshots.append(.init(
                id: attachment.id,
                fileName: attachment.fileName,
                contentType: attachment.contentType,
                data: data,
                altText: attachment.altText
            ))
        }
        return .init(title: note.title, body: body, attachments: snapshots)
    }

    private func safeExportBaseName(_ title: String) -> String {
        let filtered = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return filtered.isEmpty ? "Untitled-Note" : String(filtered.prefix(80))
    }

    private func exportFileExtension(_ format: WiskExportFormat) -> String {
        switch format {
        case .markdown: "md"
        case .textBundle: "textbundle"
        case .richText: "rtf"
        case .html: "html"
        case .pdf: "pdf"
        }
    }

    private func exportContentType(_ format: WiskExportFormat) -> UTType {
        switch format {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .textBundle: UTType(filenameExtension: "textbundle") ?? .package
        case .richText: .rtf
        case .html: .html
        case .pdf: .pdf
        }
    }

    private func macPDFData(fromHTML html: String) throws -> Data {
        let attributed = try NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.textStorage?.setAttributedString(attributed)
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 720
        let bounds = NSRect(x: 0, y: 0, width: 612, height: max(792, usedHeight + 72))
        textView.frame = bounds.insetBy(dx: 36, dy: 36)
        return textView.dataWithPDF(inside: bounds)
    }

    private func imageDataFromPasteboard(_ pasteboard: NSPasteboard) -> (data: Data, altText: String)? {
        let dataTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "Screenshot"),
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "Image"),
            (NSPasteboard.PasteboardType(UTType.heic.identifier), "Image"),
        ]

        for (type, altText) in dataTypes {
            if let data = pasteboard.data(forType: type) {
                return (data, altText)
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let image = imageDataFromURLs(urls) {
            return image
        }

        if let image = NSImage(pasteboard: pasteboard),
           let data = MacPasteSupport.encodedImageData(from: image) {
            return (data, "Screenshot")
        }

        if let data = pasteboard.data(forType: .tiff) {
            return (data, "Screenshot")
        }

        return nil
    }

    private func pasteImageIntoStructuredSection(_ sectionID: String, utf16Range: NSRange? = nil) {
        let pasteboard = NSPasteboard.general
        if let image = imageDataFromPasteboard(pasteboard) {
            insertAttachment(
                from: image.data,
                altText: image.altText,
                structuredSectionID: sectionID,
                utf16Range: utf16Range
            )
            return
        }
        statusMessage = "Copy a screenshot or image first."
    }

    private func imageDataFromURLs(_ urls: [URL]) -> (data: Data, altText: String)? {
        for url in urls {
            let contentType = WiskAttachmentImportTypes.contentType(for: url)
            guard contentType.hasPrefix("image/"),
                  let data = try? Data(contentsOf: url) else {
                continue
            }
            let altText = url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "Image"
            return (data, altText)
        }
        return nil
    }

    private func handleImageImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            insertAttachment(from: data, altText: url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "Image")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            importAttachmentFile(at: url)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        statusMessage = fileProviders.count == 1
            ? "Adding attachment..."
            : "Adding \(fileProviders.count) attachments..."

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let errorMessage = error?.localizedDescription
                let droppedURL: URL?
                if let url = item as? URL {
                    droppedURL = url
                } else if let data = item as? Data {
                    droppedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    droppedURL = nil
                }
                Task { @MainActor in
                    if let errorMessage {
                        statusMessage = errorMessage
                        return
                    }
                    if let droppedURL {
                        importAttachmentFile(at: droppedURL)
                    }
                }
            }
        }
        return true
    }

    private func importAttachmentFile(at url: URL) {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            let contentType = WiskAttachmentImportTypes.contentType(for: url)
            let displayName = url.lastPathComponent.nilIfEmpty ?? "Attachment"
            if contentType.hasPrefix("image/") {
                insertAttachment(from: data, altText: url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "Image")
            } else {
                insertFileAttachment(from: data, fileName: displayName, contentType: contentType)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func insertAttachment(
        from imageData: Data,
        altText: String,
        structuredSectionID: String? = nil,
        utf16Range: NSRange? = nil
    ) {
        do {
            let result = try attachmentService.makePendingAttachment(from: imageData, note: note, altText: altText)
            modelContext.insert(result.attachment)
            if note.attachments.contains(where: { $0.id == result.attachment.id }) == false {
                note.attachments.append(result.attachment)
            }
            if note.markdownEnabled == false {
                suppressNextMarkdownAutosave = true
                note.markdownEnabled = true
            }
            insertAttachmentMarkdown(
                id: result.attachment.id,
                title: result.attachment.altText,
                isImage: true,
                structuredSectionID: structuredSectionID,
                utf16Range: utf16Range
            )
            note.updatedAt = Date()
            note.snapshotIfNeeded(reason: "attachment")
            try? modelContext.save()
            if structuredSectionID == nil, showMarkdownSyntax {
                showMarkdownSyntax = false
            }

            Task {
                await attachmentService.upload(result.attachment, imageData: result.normalizedImage.data, noteID: note.id)
                if result.attachment.uploadStatus == .uploaded {
                    saveAndQueue(snapshotReason: "attachment")
                } else {
                    try? modelContext.save()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func insertFileAttachment(from fileData: Data, fileName: String, contentType: String) {
        do {
            let attachment = try attachmentService.makePendingFileAttachment(
                from: fileData,
                fileName: fileName,
                contentType: contentType,
                note: note
            )
            modelContext.insert(attachment)
            if note.attachments.contains(where: { $0.id == attachment.id }) == false {
                note.attachments.append(attachment)
            }
            if note.markdownEnabled == false {
                suppressNextMarkdownAutosave = true
                note.markdownEnabled = true
            }
            insertAttachmentMarkdown(id: attachment.id, title: attachment.displayName, isImage: false)
            note.updatedAt = Date()
            note.snapshotIfNeeded(reason: "attachment")
            try? modelContext.save()

            Task {
                if let data = await attachmentService.data(for: attachment) {
                    await attachmentService.upload(attachment, data: data, noteID: note.id)
                }
                if attachment.uploadStatus == .uploaded {
                    saveAndQueue(snapshotReason: "attachment")
                } else {
                    try? modelContext.save()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func insertAttachmentMarkdown(
        id: UUID,
        title: String,
        isImage: Bool,
        structuredSectionID: String? = nil,
        utf16Range: NSRange? = nil
    ) {
        applyDraftToNote()
        let reference = WiskAttachmentMarkdown.reference(title: title, id: id, isImage: isImage)
        if let structuredSectionID {
            insertStructuredAttachmentMarkdown(reference, sectionID: structuredSectionID, utf16Range: utf16Range)
            return
        }
        let insertionRange = utf16Range ?? formattingTargetRange.map { NSRange($0, in: draft.body) }
        note.body = WiskAttachmentMarkdown.inserting(reference, into: note.body, utf16Range: insertionRange)
        adoptNoteContentIntoDraft()
        suppressedBodyAutosaveValue = note.body
        bodySelection = nil
        richBodySelection = nil
        editorFocus = .body
    }

    private func insertStructuredAttachmentMarkdown(
        _ reference: String,
        sectionID: String,
        utf16Range: NSRange? = nil
    ) {
        let sectionText = sectionBody(sectionID)
        note.body = NoteStructuredSections.updatingSectionBody(
            id: sectionID,
            sectionBody: WiskAttachmentMarkdown.inserting(reference, into: sectionText, utf16Range: utf16Range),
            in: note.body
        )
        adoptNoteContentIntoDraft()
        suppressedBodyAutosaveValue = note.body
    }

    private var selectedBodyRange: Range<String.Index>? {
        if let richBodySelection, richBodySelection.isEmpty == false {
            return richBodySelection
        }
        guard let bodySelection else { return nil }
        switch bodySelection.indices {
        case .selection(let range):
            return range.isEmpty ? nil : range
        case .multiSelection(let rangeSet):
            return rangeSet.ranges.first { $0.isEmpty == false }
        @unknown default:
            return nil
        }
    }

    private var formattingTargetRange: Range<String.Index>? {
        if let richBodySelection {
            return richBodySelection
        }
        guard let bodySelection else { return nil }
        switch bodySelection.indices {
        case .selection(let range):
            return range
        case .multiSelection(let rangeSet):
            return rangeSet.ranges.first
        @unknown default:
            return nil
        }
    }

    private var formattingSourceRange: NSRange {
        if let formattingTargetRange {
            return NSRange(formattingTargetRange, in: draft.body)
        }
        return NSRange(location: 0, length: 0)
    }

    private func requestNewNoteBodyFocusIfNeeded() {
        guard note.deletedAt == nil,
              note.kind == .general || note.kind == .daily,
              note.title == "Untitled",
              note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            bodyFocusRequestID = nil
            return
        }
        editorFocus = .body
        bodyFocusRequestID = UUID()
    }

    private func selectTitleIfRequested() {
        guard titleSelectionRequestNoteID == note.id else { return }
        titleSelectionRequestNoteID = nil

        guard note.deletedAt == nil,
              note.title == "Untitled",
              note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        editorFocus = .title

        #if os(macOS)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
        #endif
    }

    private func organizeNow() {
        applyDraftToNote()
        guard proEntitlement.hasProAccess else {
            statusMessage = "Wisk Pro is required for AI organization."
            return
        }
        let bodyForAI = note.kind == .structured
            ? NoteStructuredSections.aiText(from: "", body: note.body)
            : note.body
        let combined = BackgroundNoteOrganizer.combinedText(title: note.title, body: bodyForAI)
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Add note text before organizing."
            return
        }

        presentReview()
        guard organizationPhase.isOrganizing == false else { return }

        organizer.cancel()
        statusMessage = "Organizing this note…"

        Task {
            do {
                let response = try await parsingService.parse(note: combined, bucketDefinitions: activeBuckets)
                apply(response.asDraft(rawText: combined, fallbackDate: Date()), "wisk-pro-ai")
                statusMessage = response.items.isEmpty
                    ? "AI did not find any organized items in this note."
                    : "Organized \(response.items.count) item\(response.items.count == 1 ? "" : "s") with AI."
            } catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func cleanUpNow() {
        applyDraftToNote()
        guard note.deletedAt == nil else { return }
        guard NoteCleanup.supports(note.kind) else {
            statusMessage = "Clean Up is for freeform notes."
            return
        }
        let source = draft.body
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Add note text before cleaning up."
            return
        }
        let cleaned = NoteCleanup.cleanedBody(source)
        guard cleaned != source else {
            statusMessage = "Already grouped."
            return
        }
        draft.body = cleaned
        saveAndQueue(snapshotReason: "cleanup")
        statusMessage = "Grouped similar items."
    }

    private var routeHelp: String {
        NoteLineRouter.unavailableReason(
            mappings: routeSettings.mappings,
            todoistConnected: routeSettings.isTodoistConnected,
            schyboConnected: routeSettings.isSchyboConnected
        ) ?? "Send prefixed lines to Adages, SCHYBO, and Todoist"
    }

    private func routeNow() {
        applyDraftToNote()
        guard note.deletedAt == nil else { return }
        if let reason = NoteLineRouter.unavailableReason(
            mappings: routeSettings.mappings,
            todoistConnected: routeSettings.isTodoistConnected,
            schyboConnected: routeSettings.isSchyboConnected
        ) {
            statusMessage = reason
            return
        }
        let source = draft.body
        guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            statusMessage = "Add note text before routing."
            return
        }
        guard isRouting == false else { return }
        isRouting = true
        statusMessage = "Routing…"
        let mappings = routeSettings.mappings
        let lessonsURL = routeSettings.lessonsURL()
        let schyboToken = routeSettings.schyboToken
        let todoistToken = routeSettings.todoistToken
        Task {
            let result = await NoteLineRouteSession.route(
                body: source,
                mappings: mappings,
                context: modelContext,
                publisher: NoteRouteHTTPClient(),
                lessonsURL: lessonsURL,
                schyboToken: schyboToken,
                todoistToken: todoistToken
            )
            if result.body != source {
                draft.body = result.body
                saveAndQueue(snapshotReason: "route")
            }
            statusMessage = result.message
            isRouting = false
            if result.savedAdageCount > 0 {
                await syncService.syncNow(context: modelContext)
            }
        }
    }

    private func apply(_ draft: ParsedDailyNoteDraft, _ modelName: String) {
        note.lastOrganizedAt = Date()
        note.parsedItems.forEach { modelContext.delete($0) }
        let defaultTasksBucketID = activeBuckets.first(where: \.isDefault)?.id.uuidString
        let normalizedItems = draft.items.map { item in
            var normalized = item
            if normalized.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               normalized.itemType == .action,
               let defaultTasksBucketID {
                normalized.bucketId = defaultTasksBucketID
                normalized.bucketReason = "Default task bucket"
            }
            return normalized
        }
        note.parsedItems = normalizedItems.enumerated().map { index, item in
            ParsedNoteItem(draft: item, sortOrder: index, note: note)
        }
        note.replaceSuggestedTags(
            with: Array(Set(normalizedItems.map { $0.itemType.rawValue })),
            suggestedByAI: modelName != LocalNoteParser.modelIdentifier
        )
        note.projects = Array(Set(normalizedItems.compactMap(\.project))).sorted().map {
            NoteProject(name: $0, suggestedByAI: modelName != LocalNoteParser.modelIdentifier, note: note)
        }
        saveAndQueue(snapshotReason: "organized")
    }

    private func toggleAccepted(_ item: ParsedNoteItem) {
        item.acceptedAt = item.acceptedAt == nil ? Date() : nil
        item.userEdited = true
        item.updatedAt = Date()
        saveAndQueue()
    }

    private func reject(_ item: ParsedNoteItem) {
        item.rejectedAt = Date()
        item.userEdited = true
        item.updatedAt = Date()
        saveAndQueue()
    }

    private func assignBucket(_ item: ParsedNoteItem, bucketID: String?) {
        item.bucketId = bucketID
        item.userEdited = true
        item.updatedAt = Date()
        saveAndQueue()
    }

    private func leavingDraft(from target: Note?) -> WiskEditorLeavingDraft? {
        guard let target else { return nil }
        return WiskEditorLeavingDraft(
            draftNoteID: draft.noteID,
            draftTitle: draft.title,
            draftBody: draft.body,
            needsCommit: needsCommit,
            hadPendingAutosave: editorAutosave.hasPending,
            targetTitle: target.title,
            targetBody: target.body
        )
    }

    private func persistLeavingNote(_ target: Note?, captured: WiskEditorLeavingDraft?) {
        guard let target, let captured else { return }
        let shouldCommit = WiskEditorLifecycle.shouldCommitLeavingEditor(
            draftNoteID: captured.draftNoteID,
            targetID: target.id,
            needsCommit: captured.needsCommit,
            hadPendingAutosave: captured.hadPendingAutosave,
            draftTitle: captured.draftTitle,
            draftBody: captured.draftBody,
            targetTitle: captured.targetTitle,
            targetBody: captured.targetBody
        )
        guard shouldCommit else { return }
        WiskEditorPersist.stampDraft(title: captured.draftTitle, body: captured.draftBody, onto: target)
        guard WiskEditorLifecycle.shouldScheduleDetachedLeaveCommit(deletedAt: target.deletedAt) else {
            try? modelContext.save()
            return
        }
        WiskEditorPersist.scheduleDetachedCommit(
            noteID: target.id,
            title: captured.draftTitle,
            body: captured.draftBody,
            container: modelContext.container
        ) { [syncService] message in
            syncService.reportFailure(message)
        }
    }

    private func loadEditorDraftFromNote() {
        editorAutosave.cancel()
        needsCommit = false
        draft.load(from: note)
        publishLiveListTitle()
    }

    private func applyDraftToNote() {
        if note.title != draft.title {
            note.title = draft.title
        }
        if note.body != draft.body {
            note.body = draft.body
        }
    }

    private func adoptNoteContentIntoDraft() {
        draft.load(from: note)
        publishLiveListTitle()
    }

    private func persistIdleDraft() {
        guard draft.noteID == note.id else { return }
        let shouldMarkCommit = WiskEditorLifecycle.shouldMarkNeedsCommit(
            draftNoteID: draft.noteID,
            boundNoteID: note.id,
            draftTitle: draft.title,
            draftBody: draft.body,
            noteTitle: note.title,
            noteBody: note.body
        )
        // No `applyDraftToNote()` here: `WiskEditorPersist.apply` stamps the
        // draft itself, and its `.idle` change detection must see the
        // pre-stamp note to tell a real edit from a no-op lifecycle persist.
        WiskEditorPersist.apply(
            title: draft.title,
            body: draft.body,
            to: note,
            kind: .idle,
            syncService: syncService,
            context: modelContext
        )
        if shouldMarkCommit {
            needsCommit = true
            scheduleOrganizerIfNeeded()
        }
    }

    private func commitEditorDraft(to target: Note?, captured: WiskEditorLeavingDraft? = nil) {
        let hadPending: Bool
        let draftNoteID: UUID?
        let draftTitle: String
        let draftBody: String
        let needsCommitFlag: Bool
        let targetTitle: String
        let targetBody: String
        if let captured {
            hadPending = captured.hadPendingAutosave
            draftNoteID = captured.draftNoteID
            draftTitle = captured.draftTitle
            draftBody = captured.draftBody
            needsCommitFlag = captured.needsCommit
            targetTitle = captured.targetTitle
            targetBody = captured.targetBody
        } else {
            hadPending = editorAutosave.hasPending
            editorAutosave.cancel()
            draftNoteID = draft.noteID
            draftTitle = draft.title
            draftBody = draft.body
            needsCommitFlag = needsCommit
            targetTitle = target?.title ?? ""
            targetBody = target?.body ?? ""
        }
        guard let target else { return }
        let shouldCommit = WiskEditorLifecycle.shouldCommitLeavingEditor(
            draftNoteID: draftNoteID,
            targetID: target.id,
            needsCommit: needsCommitFlag,
            hadPendingAutosave: hadPending,
            draftTitle: draftTitle,
            draftBody: draftBody,
            targetTitle: targetTitle,
            targetBody: targetBody
        )
        guard shouldCommit else { return }
        WiskEditorPersist.apply(
            title: draftTitle,
            body: draftBody,
            to: target,
            kind: .commit,
            syncService: syncService,
            context: modelContext
        )
        if captured == nil {
            needsCommit = false
        }
        if target.id == note.id {
            scheduleOrganizerIfNeeded()
        }
    }

    private func resetTransientEditorState() {
        richBodySelection = nil
        structuredRichSelections = [:]
        bodySelection = nil
        jumpToSourceRange = nil
        wikiQuery = nil
        showingFormattingOverlay = false
        showingShare = false
        showingPublish = false
        showingAI = false
        showingTags = false
        showingInfo = false
        suppressedBodyAutosaveValue = nil
        listItemDraft = ""
        structuredQuickAddDrafts = [:]
        structuredSectionTitleFocusRequestID = nil
        structuredSectionScrollRequestID = nil
        activeStructuredSectionID = nil
        attachmentDetails = nil
        needsCommit = false
        statusMessage = nil
    }

    private var wikiLinkTitles: [String] {
        guard let wikiQuery else { return [] }
        return WiskNoteLinkService.autocompleteTitles(query: wikiQuery, in: libraryListings, excluding: note.id)
    }

    private func openWikiLink(_ rawTarget: String) {
        guard let resolved = WiskNoteLinkService.resolveOrCreate(
            rawTarget: rawTarget,
            in: libraryListings,
            context: modelContext
        ) else { return }
        if resolved.didCreate {
            syncService.enqueue(note: resolved.note, context: modelContext)
        }
        if resolved.note.id == note.id {
            if let heading = resolved.heading,
               let range = WiskMarkdownDocumentEngine.headingSourceRange(heading, in: draft.body) {
                jumpToSourceRange = range
            }
            return
        }
        WiskNoteLinkService.PendingJump.set(noteID: resolved.note.id, heading: resolved.heading)
        openNote(resolved.note.id)
    }

    private func scheduleOrganizerIfNeeded() {
        guard note.kind != .list && note.kind != .tracker else {
            organizer.cancel()
            return
        }
        guard proEntitlement.hasProAccess else { return }
        let bodyForAI = note.kind == .structured
            ? NoteStructuredSections.aiText(from: "", body: note.body)
            : note.body
        organizer.schedule(
            noteID: note.id,
            title: note.title,
            body: bodyForAI,
            bucketDefinitions: activeBuckets,
            parse: apply,
            aiService: parsingService
        )
    }

    private func consumePendingJump() {
        guard let heading = WiskNoteLinkService.PendingJump.consume(for: note.id),
              let range = WiskMarkdownDocumentEngine.headingSourceRange(heading, in: draft.body) else {
            return
        }
        jumpToSourceRange = range
    }

    private func saveAndQueue(snapshotReason: String = "edit", fromDraft: Bool = true) {
        editorAutosave.cancel()
        if fromDraft {
            applyDraftToNote()
        } else {
            adoptNoteContentIntoDraft()
        }
        WiskEditorPersist.apply(
            title: note.title,
            body: note.body,
            to: note,
            kind: .commit,
            snapshotReason: snapshotReason,
            syncService: syncService,
            context: modelContext
        )
        needsCommit = false
    }

    private func save() {
        try? modelContext.save()
    }

    private func addListItem() {
        let trimmed = listItemDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        note.body = NoteChecklist.addingItem(trimmed, to: note.body)
        listItemDraft = ""
        saveAndQueue(snapshotReason: "list", fromDraft: false)
        listItemFocused = true
    }

    private func toggleListItem(at index: Int) {
        note.body = NoteChecklist.togglingItem(at: index, in: note.body)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
    }

    private func setListItemStatus(_ statusID: String, at index: Int) {
        note.body = NoteChecklist.settingStatus(statusID, forItemAt: index, in: note.body)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
    }

    private func deleteListItem(at index: Int) {
        note.body = NoteChecklist.deletingItem(at: index, in: note.body)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
    }

    private func clearCompletedListItems() {
        note.body = NoteChecklist.removingCompletedItems(from: note.body)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
    }

    private func customizeListStatuses() {
        note.body = NoteChecklist.customizingStatuses(in: note.body)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
        showingListStatusEditor = true
    }

    private func applyListStatusTemplate(_ template: NoteChecklistTemplate) {
        note.body = NoteChecklist.customizingStatuses(in: note.body, template: template)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
        showingListStatusEditor = true
    }

    private func convertListToChecklist() {
        note.body = NoteChecklist.convertingToCheckbox(note.body)
        saveAndQueue(snapshotReason: "list", fromDraft: false)
    }

    private func sectionTitle(_ sectionID: String) -> String {
        NoteStructuredSections.structuredNote(from: note.body).sections.first { $0.id == sectionID }?.title ?? ""
    }

    private func sectionBody(_ sectionID: String) -> String {
        NoteStructuredSections.structuredNote(from: note.body).sections.first { $0.id == sectionID }?.body ?? ""
    }

    private func saveStructuredTemplate() {
        guard let template = NoteStructuredSections.templateFromCurrentStructure(
            title: structuredTemplateTitle,
            body: note.body
        ) else { return }
        NoteStructuredSections.saveUserTemplate(template)
        statusMessage = "Saved \"\(template.title)\" as a structured note template."
    }

    private func addStructuredSection() {
        var structuredNote = NoteStructuredSections.structuredNote(from: note.body)
        let sectionID = UUID().uuidString
        structuredNote.sections.append(StructuredNoteSection(
            id: sectionID,
            title: "New Section",
            sortOrder: structuredNote.sections.count
        ))
        note.body = NoteStructuredSections.body(from: structuredNote)
        structuredSectionScrollRequestID = sectionID
        structuredSectionTitleFocusRequestID = sectionID
        saveStructuredMutation()
    }

    private func updateStructuredSectionTitle(_ sectionID: String, _ title: String) {
        note.body = NoteStructuredSections.updatingSectionTitle(id: sectionID, title: title, in: note.body)
        adoptNoteContentIntoDraft()
        needsCommit = true
        editorAutosave.schedule { persistIdleDraft() }
    }

    private func updateStructuredSectionBody(_ sectionID: String, _ body: String) {
        note.body = NoteStructuredSections.updatingSectionBody(id: sectionID, sectionBody: body, in: note.body)
        adoptNoteContentIntoDraft()
        needsCommit = true
        editorAutosave.schedule { persistIdleDraft() }
    }

    private func toggleStructuredSection(_ sectionID: String) {
        let previousBody = note.body
        note.body = NoteStructuredSections.togglingSection(id: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        saveStructuredMutation()
    }

    private func addStructuredQuickItems(_ sectionID: String, _ items: [String]) {
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedItems.isEmpty else { return }

        let previousBody = note.body
        for item in trimmedItems {
            note.body = NoteStructuredSections.appendingItem(item, toSection: sectionID, in: note.body)
        }
        guard note.body != previousBody else { return }
        saveStructuredMutation()
    }

    private func setStructuredSectionMode(_ sectionID: String, _ mode: StructuredNoteSectionMode) {
        let previousBody = note.body
        note.body = NoteStructuredSections.settingSectionMode(mode, id: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        saveStructuredMutation()
    }

    private func toggleStructuredChecklistItem(_ sectionID: String, _ index: Int) {
        let previousBody = note.body
        note.body = NoteStructuredSections.togglingChecklistItem(at: index, sectionID: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        saveStructuredMutation()
    }

    private func deleteStructuredChecklistItem(_ sectionID: String, _ index: Int) {
        let previousBody = note.body
        note.body = NoteStructuredSections.deletingChecklistItem(at: index, sectionID: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        saveStructuredMutation()
    }

    private func moveStructuredSection(_ sectionID: String, _ direction: NoteStructuredSections.MoveDirection) {
        let previousBody = note.body
        note.body = NoteStructuredSections.movingSection(id: sectionID, direction: direction, in: note.body)
        guard note.body != previousBody else { return }
        saveStructuredMutation()
    }

    private func deleteStructuredSection(_ sectionID: String) {
        let previousBody = note.body
        note.body = NoteStructuredSections.deletingSection(id: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        structuredQuickAddDrafts[sectionID] = nil
        saveStructuredMutation()
    }

    private func saveStructuredMutation(snapshotReason: String = "structured") {
        suppressedBodyAutosaveValue = note.body
        saveAndQueue(snapshotReason: snapshotReason, fromDraft: false)
    }

    private func syncTrackerDrafts() {
        guard note.kind == .tracker else { return }
        let tracker = NoteTrackerStore.tracker(from: note.body)
        trackerUnitDraft = tracker.unitLabel
        trackerQuickAddsDraft = tracker.quickAdds.map(NoteTrackerStore.formatted).joined(separator: ", ")
    }

    private func addTrackerCounter() {
        let previousBody = note.body
        note.body = NoteTrackerStore.addingCounter(trackerCounterDraft, to: note.body)
        guard note.body != previousBody else { return }
        trackerCounterDraft = ""
        saveAndQueue(snapshotReason: "tracker", fromDraft: false)
    }

    private func recordTrackerEvent(counterID: UUID, amount: Double) {
        let previousBody = note.body
        note.body = NoteTrackerStore.recording(
            amount: amount,
            counterID: counterID,
            memo: trackerMemoDraft,
            in: note.body
        )
        guard note.body != previousBody else { return }
        trackerMemoDraft = ""
        saveAndQueue(snapshotReason: "tracker", fromDraft: false)
    }

    private func archiveTrackerCounter(_ counterID: UUID) {
        note.body = NoteTrackerStore.archivingCounter(id: counterID, in: note.body)
        saveAndQueue(snapshotReason: "tracker", fromDraft: false)
    }

    private func undoLastTrackerEvent() {
        note.body = NoteTrackerStore.removingLastEvent(from: note.body)
        saveAndQueue(snapshotReason: "tracker", fromDraft: false)
    }

    private func saveTrackerSettings() {
        let quickAdds = trackerQuickAddsDraft
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        note.body = NoteTrackerStore.updatingSettings(unitLabel: trackerUnitDraft, quickAdds: quickAdds, in: note.body)
        syncTrackerDrafts()
        saveAndQueue(snapshotReason: "tracker", fromDraft: false)
    }
}

private enum MacSlashCommand: String, CaseIterable, Identifiable {
    case heading
    case checklist
    case bullet
    case code
    case link
    case tag
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heading: return "Heading"
        case .checklist: return "Checklist"
        case .bullet: return "Bullet List"
        case .code: return "Code"
        case .link: return "Link"
        case .tag: return "Tag"
        case .ai: return "Review with Wisk"
        }
    }

    var detail: String {
        switch self {
        case .heading: return "# Heading"
        case .checklist: return "- [ ] Task"
        case .bullet: return "- List item"
        case .code: return "`code`"
        case .link: return "[Title](https://)"
        case .tag: return "#tag"
        case .ai: return "Open AI review"
        }
    }

    var systemImage: String {
        switch self {
        case .heading: return "textformat.size"
        case .checklist: return "checklist"
        case .bullet: return "list.bullet"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .tag: return "number"
        case .ai: return "sparkles"
        }
    }

    func apply(to text: String) -> String {
        if self == .ai {
            NotificationCenter.default.post(name: .wiskShowAI, object: nil)
            return Self.removingSlashTrigger(from: text)
        }

        let insertion: String
        switch self {
        case .heading:
            insertion = "# Heading"
        case .checklist:
            insertion = "- [ ] "
        case .bullet:
            insertion = "- "
        case .code:
            insertion = "`code`"
        case .link:
            insertion = "[Title](https://)"
        case .tag:
            insertion = "#tag"
        case .ai:
            insertion = ""
        }

        return Self.replacingSlashTrigger(in: text, with: insertion)
    }

    private static func replacingSlashTrigger(in text: String, with insertion: String) -> String {
        let components = text.components(separatedBy: .newlines)
        guard components.last?.hasPrefix("/") == true else {
            return text.isEmpty ? insertion : text + "\n" + insertion
        }
        var updated = components
        updated[updated.count - 1] = insertion
        return updated.joined(separator: "\n")
    }

    private static func removingSlashTrigger(from text: String) -> String {
        replacingSlashTrigger(in: text, with: "")
    }
}

private struct MacSlashCommandBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let apply: (MacSlashCommand) -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Insert")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Slash commands")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 8)], spacing: 8) {
                ForEach(MacSlashCommand.allCases) { command in
                    Button {
                        AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                            apply(command)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: command.systemImage)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(command.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(command.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: MacSlashCommand.allCases.map(\.id))
        }
        .padding(12)
        .wiskGlassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98, anchor: .top)
        .animation(AppMotion.animation(AppMotion.macQuick, reduceMotion: reduceMotion), value: appeared)
        .onAppear {
            AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                appeared = true
            }
        }
    }
}

private struct MacNoteToolbar: ToolbarContent {
    @Bindable var note: Note
    @Binding var showMarkdownSyntax: Bool
    @Binding var showingInfo: Bool
    @Binding var showingShare: Bool
    @Binding var showingPublish: Bool
    @Binding var showingTags: Bool
    @Binding var showingFormattingOverlay: Bool
    let isReviewPanelVisible: Bool
    let isOrganizing: Bool
    let formattingControlsEnabled: Bool
    let formattingControlsHelp: String
    let toggleMarkdownSyntax: () -> Void
    let toggleReview: () -> Void
    let presentReview: () -> Void
    let organizeNow: () -> Void
    let cleanUpNow: () -> Void
    let routeNow: () -> Void
    let isRouting: Bool
    let canRoute: Bool
    let routeHelp: String
    let addStructuredSection: (() -> Void)?
    let saveStructuredTemplate: (() -> Void)?
    let deleteNote: () -> Void
    let restoreNote: () -> Void
    let permanentlyDeleteNote: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            WiskFormattingToggleButton(isExpanded: $showingFormattingOverlay)
                .disabled(!formattingControlsEnabled)
                .help(formattingControlsHelp)

            Button {
                toggleMarkdownSyntax()
            } label: {
                Text(markdownButtonTitle)
                    .strikethrough(markdownButtonStrikethrough)
            }
            .help(markdownButtonHelp)
            .accessibilityLabel(markdownButtonAccessibilityLabel)
            .accessibilityValue(markdownButtonAccessibilityValue)
            .accessibilityIdentifier("wisk.mac.note.markdownSyntaxToggle")
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(note.deletedAt != nil)
            .contextMenu {
                Button(note.markdownEnabled ? "Turn Markdown Off" : "Turn Markdown On") {
                    note.markdownEnabled.toggle()
                    if note.markdownEnabled == false {
                        showMarkdownSyntax = false
                    }
                }
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            Button { showingInfo.toggle() } label: {
                Label("Info", systemImage: "info.circle")
            }
            .accessibilityIdentifier("wisk.mac.note.infoButton")

            Button(action: toggleReview) {
                Label("Review", systemImage: "sparkles.rectangle.stack")
            }
            .symbolVariant(isReviewPanelVisible ? .fill : .none)
            .help(isReviewPanelVisible ? "Hide Wisk Review" : "Show Wisk Review")
            .accessibilityLabel(isReviewPanelVisible ? "Hide Wisk Review" : "Show Wisk Review")
            .accessibilityIdentifier("wisk.mac.note.reviewButton")

            if let addStructuredSection {
                Button(action: addStructuredSection) {
                    Label("Add Section", systemImage: "rectangle.badge.plus")
                }
                .help("Add Section")
                .accessibilityLabel("Add Section")
            }
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                Button {
                    showingTags = true
                } label: {
                    Label("Manage Tags...", systemImage: "tag")
                }
                Divider()
                Button {
                    presentReview()
                } label: {
                    Label("Review with Wisk", systemImage: "sparkles.rectangle.stack")
                }
                Button {
                    organizeNow()
                } label: {
                    Label(isOrganizing ? "Organizing…" : "Organize", systemImage: "sparkles")
                }
                .disabled(isOrganizing)
                Button {
                    routeNow()
                } label: {
                    Label(isRouting ? "Routing…" : "Route", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(isRouting || canRoute == false || note.deletedAt != nil)
                .help(routeHelp)
                .accessibilityIdentifier("wisk.mac.note.routeButton")
                Button {
                    cleanUpNow()
                } label: {
                    Label("Clean Up", systemImage: "line.3.horizontal.decrease")
                }
                .disabled(!NoteCleanup.supports(note.kind) || note.deletedAt != nil)
                Divider()
                Button {
                    showingShare = true
                } label: {
                    Label("Collaborate", systemImage: "person.2")
                }
                .keyboardShortcut("s", modifiers: .command)
                Button {
                    showingPublish = true
                } label: {
                    Label("Publish to Web", systemImage: "globe")
                }
                if let saveStructuredTemplate {
                    Divider()
                    Button(action: saveStructuredTemplate) {
                        Label("Save Current Structure as Template", systemImage: "square.and.arrow.down")
                    }
                }
                Divider()
                if note.deletedAt == nil {
                    Button(role: .destructive, action: deleteNote) {
                        Label("Archive Note", systemImage: "archivebox")
                    }
                } else {
                    Button(action: restoreNote) {
                        Label("Restore Note", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive, action: permanentlyDeleteNote) {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
            .accessibilityIdentifier("wisk.mac.note.toolbar")
        }
    }

    private var markdownButtonTitle: String {
        showMarkdownSyntax ? "Edit" : "Markdown"
    }

    private var markdownButtonStrikethrough: Bool {
        note.markdownEnabled == false && showMarkdownSyntax == false
    }

    private var markdownButtonHelp: String {
        if showMarkdownSyntax {
            return "Hide Markdown characters"
        }
        return "Show Markdown characters"
    }

    private var markdownButtonAccessibilityLabel: String {
        if showMarkdownSyntax {
            return "Hide Markdown characters"
        }
        return "Show Markdown characters"
    }

    private var markdownButtonAccessibilityValue: String {
        note.markdownEnabled ? "Markdown on" : "Markdown off"
    }
}

private struct MacOverflowMenuLabel: View {
    var width: CGFloat = 24
    var height: CGFloat = 24

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
    }
}

private struct MacSketchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var canvasView = MacSketchCanvasNSView()

    let save: (Data) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sketch")
                        .font(.headline)
                    Text("Draw with your mouse or trackpad, then insert it into this note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Insert") {
                    insertSketch()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wisk.mac.sketch.insertButton")
            }
            .padding()
            .background(.regularMaterial)

            MacSketchCanvasView(canvasView: canvasView)
                .background(Color.white)
                .accessibilityIdentifier("wisk.mac.sketch.canvas")
        }
        .accessibilityIdentifier("wisk.mac.sketch.sheet")
    }

    private func insertSketch() {
        guard let data = canvasView.pngData() else { return }
        save(data)
        dismiss()
    }
}

private struct MacSketchCanvasView: NSViewRepresentable {
    let canvasView: MacSketchCanvasNSView

    func makeNSView(context: Context) -> MacSketchCanvasNSView {
        canvasView
    }

    func updateNSView(_ nsView: MacSketchCanvasNSView, context: Context) {}
}

private final class MacSketchCanvasNSView: NSView {
    private var paths: [[CGPoint]] = []
    private var currentPath: [CGPoint] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        currentPath = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPath.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPath.append(convert(event.locationInWindow, from: nil))
        if currentPath.count > 1 {
            paths.append(currentPath)
        }
        currentPath.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        NSColor.labelColor.setStroke()
        let strokeWidth: CGFloat = 4
        for path in paths + (currentPath.isEmpty ? [] : [currentPath]) {
            draw(path, strokeWidth: strokeWidth)
        }
    }

    func pngData() -> Data? {
        let exportBounds = bounds.isEmpty ? NSRect(x: 0, y: 0, width: 1024, height: 768) : bounds
        guard let bitmap = bitmapImageRepForCachingDisplay(in: exportBounds) else { return nil }
        cacheDisplay(in: exportBounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func draw(_ points: [CGPoint], strokeWidth: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        path.stroke()
    }
}

private struct MacStructuredImagePasteMonitor: NSViewRepresentable {
    let focusedSectionID: String?
    let pasteImage: (String, NSRange?) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.focusedSectionID = focusedSectionID
        context.coordinator.pasteImage = pasteImage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(focusedSectionID: focusedSectionID, pasteImage: pasteImage)
    }

    final class Coordinator {
        var focusedSectionID: String?
        var pasteImage: (String, NSRange?) -> Void
        private var monitor: Any?

        init(focusedSectionID: String?, pasteImage: @escaping (String, NSRange?) -> Void) {
            self.focusedSectionID = focusedSectionID
            self.pasteImage = pasteImage
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      MacPasteSupport.isCommandV(event),
                      let sectionID = self.focusedSectionID,
                      MacPasteSupport.hasImageContent(),
                      WiskMacBodyEditorFocus.isFirstResponder == false
                else {
                    return event
                }

                self.pasteImage(sectionID, nil)
                return nil
            }
        }
    }
}

private struct MacImagePasteKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let pasteImage: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.pasteImage = pasteImage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, pasteImage: pasteImage)
    }

    final class Coordinator {
        var isActive: Bool
        var pasteImage: () -> Void
        private var monitor: Any?

        init(isActive: Bool, pasteImage: @escaping () -> Void) {
            self.isActive = isActive
            self.pasteImage = pasteImage
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive,
                      WiskMacBodyEditorFocus.isFirstResponder == false,
                      MacPasteSupport.isCommandV(event),
                      MacPasteSupport.hasImageContent()
                else {
                    return event
                }

                self.pasteImage()
                return nil
            }
        }
    }
}

private struct MacStructuredNoteEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedSectionID: String?
    @FocusState private var focusedSectionTitleID: String?

    let structuredNote: StructuredNote
    let attachments: [NoteAttachment]
    @Binding var richSelections: [String: Range<String.Index>]
    @Binding var quickAddDrafts: [String: String]
    @Binding var activeSectionID: String?
    @Binding var titleFocusRequestSectionID: String?
    let titleForSection: (String) -> String
    let bodyForSection: (String) -> String
    let updateTitle: (String, String) -> Void
    let updateBody: (String, String) -> Void
    let pasteImage: (String, NSRange?) -> Void
    let toggleSection: (String) -> Void
    let addQuickItems: (String, [String]) -> Void
    let setMode: (String, StructuredNoteSectionMode) -> Void
    let moveSection: (String, NoteStructuredSections.MoveDirection) -> Void
    let deleteSection: (String) -> Void
    let toggleChecklistItem: (String, Int) -> Void
    let deleteChecklistItem: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if structuredNote.sections.isEmpty {
                ContentUnavailableView {
                    Label("No Sections", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Use Add Section in the toolbar to start structured capture.")
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    ForEach(structuredNote.sections) { section in
                        sectionCard(section)
                            .id(section.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(nil, value: focusedSectionTitleID)
        .background(
            MacStructuredImagePasteMonitor(focusedSectionID: focusedSectionID, pasteImage: pasteImage)
        )
        .onAppear {
            focusRequestedSectionTitleIfNeeded()
        }
        .onChange(of: titleFocusRequestSectionID) { _, _ in
            focusRequestedSectionTitleIfNeeded()
        }
        .onChange(of: focusedSectionID) { _, sectionID in
            if let sectionID {
                activeSectionID = sectionID
            }
        }
        .onChange(of: focusedSectionTitleID) { _, sectionID in
            if sectionID != nil {
                activeSectionID = nil
            }
        }
        .onChange(of: sectionsListMotionKey) { _, _ in
            validateActiveSectionID()
        }
    }

    private var sectionsListMotionKey: String {
        structuredNote.sections.map { "\($0.id):\($0.mode.rawValue):\($0.isCollapsed)" }.joined(separator: "|")
    }

    private func validateActiveSectionID() {
        guard let activeSectionID,
              structuredNote.sections.contains(where: { $0.id == activeSectionID && !$0.isCollapsed && $0.mode != .checklist })
        else {
            self.activeSectionID = nil
            return
        }
    }

    private func pasteImageIntoSection(_ sectionID: String) {
        let body = bodyForSection(sectionID)
        let utf16Range = richSelections[sectionID].map { NSRange($0, in: body) }
        pasteImage(sectionID, utf16Range)
    }

    private func sectionCard(_ section: StructuredNoteSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    animated {
                        toggleSection(section.id)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 16, height: 28)
                        .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.isCollapsed ? "Expand section" : "Collapse section")
                .accessibilityValue(section.isCollapsed ? "Collapsed" : "Expanded")

                TextField(
                    "Untitled Section",
                    text: Binding(
                        get: { titleForSection(section.id) },
                        set: { updateTitle(section.id, $0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($focusedSectionTitleID, equals: section.id)

                if !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(sectionSummary(section))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 12)
                }

                sectionMenu(section)
            }

            if !section.isCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    if section.mode == .checklist {
                        checklistRows(section)
                        checklistEntryEditor(section)
                    } else {
                        WiskRichMarkdownEditor(
                            markdownText: Binding(
                                get: { bodyForSection(section.id) },
                                set: { updateBody(section.id, $0) }
                            ),
                            selectedMarkdownRange: Binding(
                                get: { richSelections[section.id] },
                                set: { selection in
                                    if let selection {
                                        richSelections[section.id] = selection
                                    } else {
                                        richSelections.removeValue(forKey: section.id)
                                    }
                                }
                            ),
                            attachments: attachments,
                            baseFontSize: 13,
                            minHeight: textSectionEditorHeight(for: section),
                            accessibilityIdentifier: "wisk.mac.structured.sectionBody.\(section.id)",
                            onFocusChange: { focused in
                                focusedSectionID = focused ? section.id : nil
                            },
                            onPasteImage: {
                                pasteImageIntoSection(section.id)
                            }
                        )
                        .frame(height: textSectionEditorHeight(for: section))
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onPasteCommand(of: MacPasteSupport.imagePasteTypes) { _ in
                            pasteImageIntoSection(section.id)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button(section.mode == .checklist ? "Convert to Text Section" : "Convert to To-do List") {
                animated {
                    setMode(section.id, section.mode == .checklist ? .text : .checklist)
                }
            }
            Divider()
            Button(section.isCollapsed ? "Expand Section" : "Collapse Section") {
                animated {
                    toggleSection(section.id)
                }
            }
            Button("Move Up") {
                animated {
                    moveSection(section.id, .up)
                }
            }
                .disabled(structuredNote.sections.first?.id == section.id)
            Button("Move Down") {
                animated {
                    moveSection(section.id, .down)
                }
            }
                .disabled(structuredNote.sections.last?.id == section.id)
            Divider()
            Button("Delete Section", role: .destructive) {
                animated {
                    deleteSection(section.id)
                }
            }
            .disabled(structuredNote.sections.count <= 1)
        }
    }

    private func textSectionEditorHeight(for section: StructuredNoteSection) -> CGFloat {
        let text = bodyForSection(section.id).trimmingCharacters(in: .newlines)
        let visualLineCount = text.isEmpty
            ? 1
            : text.components(separatedBy: .newlines).reduce(0) { count, line in
                count + max(1, Int(ceil(Double(line.count) / 90.0)))
            }

        let lineHeight: CGFloat = 18
        let verticalPadding: CGFloat = 22
        return min(max(CGFloat(visualLineCount) * lineHeight + verticalPadding, 42), 220)
    }

    private func focusRequestedSectionTitleIfNeeded() {
        guard let sectionID = titleFocusRequestSectionID,
              structuredNote.sections.contains(where: { $0.id == sectionID })
        else { return }

        titleFocusRequestSectionID = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            focusedSectionTitleID = sectionID
            try? await Task.sleep(nanoseconds: 50_000_000)
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func sectionMenu(_ section: StructuredNoteSection) -> some View {
        Menu {
            Button(section.mode == .checklist ? "Convert to Text Section" : "Convert to To-do List") {
                animated {
                    setMode(section.id, section.mode == .checklist ? .text : .checklist)
                }
            }
            Divider()
            Button("Move Up") {
                animated {
                    moveSection(section.id, .up)
                }
            }
                .disabled(structuredNote.sections.first?.id == section.id)
            Button("Move Down") {
                animated {
                    moveSection(section.id, .down)
                }
            }
                .disabled(structuredNote.sections.last?.id == section.id)
            Button(section.isCollapsed ? "Expand" : "Collapse") {
                animated {
                    toggleSection(section.id)
                }
            }
            Divider()
            Button("Delete Section", role: .destructive) {
                animated {
                    deleteSection(section.id)
                }
            }
            .disabled(structuredNote.sections.count <= 1)
        } label: {
            MacOverflowMenuLabel(width: 42, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 54, alignment: .trailing)
    }

    private func sectionSummary(_ section: StructuredNoteSection) -> String {
        if section.mode == .checklist {
            return NoteStructuredSections.checklistProgressSummary(for: section)
        }
        return section.body.components(separatedBy: .newlines).first?.nilIfEmpty ?? "Has notes"
    }

    private func checklistEntryEditor(_ section: StructuredNoteSection) -> some View {
        let title = titleForSection(section.id).nilIfEmpty ?? "section"

        return ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { quickAddDrafts[section.id, default: ""] },
                set: { quickAddDrafts[section.id] = $0 }
            ))
            .font(.system(size: 13))
            .frame(minHeight: 72)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: quickAddDrafts[section.id, default: ""]) { _, draft in
                commitCompletedChecklistLines(in: section.id, draft: draft)
            }
            .accessibilityIdentifier("wisk.mac.structured.checklistEntry.\(section.id)")

            if quickAddDrafts[section.id, default: ""].isEmpty {
                Text("Type todos for \(title), one per line")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private func commitCompletedChecklistLines(in sectionID: String, draft: String) {
        guard draft.contains(where: \.isNewline) else { return }

        let lines = draft.components(separatedBy: .newlines)
        let hasTrailingNewline = draft.last?.isNewline == true
        let completedLines = hasTrailingNewline ? lines : Array(lines.dropLast())
        let remainingDraft = hasTrailingNewline ? "" : (lines.last ?? "")
        let items = completedLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        quickAddDrafts[sectionID] = remainingDraft

        guard !items.isEmpty else { return }
        animated {
            addQuickItems(sectionID, items)
        }
    }

    private func checklistRows(_ section: StructuredNoteSection) -> some View {
        let items = NoteStructuredSections.checklistItems(in: section)

        return VStack(spacing: 6) {
            if items.isEmpty {
                Text("Type a todo below, then press Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Button {
                            animated {
                                toggleChecklistItem(section.id, index)
                            }
                        } label: {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCompleted ? Color.accentColor : .secondary)
                                .scaleEffect(item.isCompleted ? 1.05 : 1)
                                .animation(AppMotion.animation(AppMotion.macQuick, reduceMotion: reduceMotion), value: item.isCompleted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.isCompleted ? "Mark item not done" : "Mark item done")

                        Text(item.text)
                            .font(.system(size: 13))
                            .foregroundStyle(item.isCompleted ? .secondary : .primary)
                            .strikethrough(item.isCompleted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: item.isCompleted)

                        Button {
                            animated {
                                deleteChecklistItem(section.id, index)
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete checklist item")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(AppMotion.transition(reduceMotion: reduceMotion))
                    .contextMenu {
                        Button(item.isCompleted ? "Mark Not Done" : "Mark Done") {
                            animated {
                                toggleChecklistItem(section.id, index)
                            }
                        }
                        Button("Delete Item", role: .destructive) {
                            animated {
                                deleteChecklistItem(section.id, index)
                            }
                        }
                    }
                }
            }
        }
        .animation(AppMotion.animation(AppMotion.macSpring, reduceMotion: reduceMotion), value: items.map { "\($0.id):\($0.isCompleted):\($0.statusID ?? "")" }.joined(separator: "|"))
    }

    private func animated(_ updates: () -> Void) {
        AppMotion.perform(reduceMotion: reduceMotion, updates)
    }
}

private struct MacChecklistEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let checklist: NoteChecklistList
    @Binding var itemDraft: String
    let itemFocused: FocusState<Bool>.Binding
    let addItem: () -> Void
    let toggleItem: (Int) -> Void
    let setStatus: (String, Int) -> Void
    let deleteItem: (Int) -> Void
    let clearCompleted: () -> Void
    let customizeStatuses: () -> Void
    let applyTemplate: (NoteChecklistTemplate) -> Void
    let convertToChecklist: () -> Void
    let editStatuses: () -> Void

    private var hasCompletedItems: Bool {
        checklist.items.contains(where: \.isCompleted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("List", systemImage: "checklist")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(progressSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasCompletedItems {
                    Button("Clear Completed", action: clearCompleted)
                        .controlSize(.small)
                }
                listOptionsMenu
            }

            if checklist.items.isEmpty {
                ContentUnavailableView {
                    Label("No Items", systemImage: "checklist")
                } description: {
                    Text("Add the first item to start this list.")
                } actions: {
                    Button {
                        animated {
                            focusItemDraft()
                        }
                    } label: {
                        Label("Add New Item", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .contentShape(Rectangle())
                .onTapGesture(perform: focusItemDraft)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(Array(checklist.items.enumerated()), id: \.offset) { index, item in
                        row(item: item, index: index)
                            .transition(AppMotion.transition(reduceMotion: reduceMotion))
                    }
                }
                .animation(AppMotion.animation(AppMotion.macSpring, reduceMotion: reduceMotion), value: checklistMotionKey)
            }

            HStack(spacing: 8) {
                TextField("Add item", text: $itemDraft)
                    .textFieldStyle(.plain)
                    .focused(itemFocused)
                    .onSubmit {
                        animated(addItem)
                    }

                Button {
                    animated(addItem)
                } label: {
                    Label("Add New Item", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(!canAddItem)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .macPanel(cornerRadius: 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var progressSummary: String {
        NoteChecklist.progressSummary(for: NoteChecklist.body(from: checklist))
    }

    private var canAddItem: Bool {
        !itemDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var checklistMotionKey: String {
        checklist.items.map { "\($0.id):\($0.text):\($0.isCompleted):\($0.statusID ?? "")" }
            .joined(separator: "|")
    }

    private func focusItemDraft() {
        itemFocused.wrappedValue = true
    }

    private var listOptionsMenu: some View {
        Menu {
            Button("Customize Statuses") {
                animated(customizeStatuses)
            }
            Menu("Apply Template") {
                ForEach(NoteChecklist.templates) { template in
                    Button(template.title) {
                        animated {
                            applyTemplate(template)
                        }
                    }
                }
            }
            if checklist.mode == .customStatus {
                Button("Edit Statuses", action: editStatuses)
                Button("Convert to Checklist") {
                    animated(convertToChecklist)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .help("List options")
    }

    private func row(item: NoteChecklistItem, index: Int) -> some View {
        HStack(spacing: 8) {
            if checklist.mode == .customStatus {
                macStatusPicker(item: item, index: index)
            } else {
                Button {
                    animated {
                        toggleItem(index)
                    }
                } label: {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isCompleted ? Color.accentColor : .secondary)
                        .scaleEffect(item.isCompleted ? 1.06 : 1)
                        .animation(AppMotion.animation(AppMotion.macQuick, reduceMotion: reduceMotion), value: item.isCompleted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isCompleted ? "Mark item not done" : "Mark item done")
            }

            Text(item.text)
                .font(.system(size: 14))
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .strikethrough(item.isCompleted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: item.isCompleted)

            Button {
                animated {
                    deleteItem(index)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete item")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .macPanel(cornerRadius: 10)
        .contextMenu {
            if checklist.mode == .customStatus {
                Menu("Set Status") {
                    ForEach(checklist.statuses.sorted { $0.sortOrder < $1.sortOrder }) { status in
                        Button(status.title) {
                            setStatus(status.id, index)
                        }
                    }
                }
            }
            Button("Delete Item", role: .destructive) {
                animated {
                    deleteItem(index)
                }
            }
        }
    }

    private func macStatusPicker(item: NoteChecklistItem, index: Int) -> some View {
        let status = NoteChecklist.status(for: item, in: checklist)
        return HStack(spacing: 4) {
            Button {
                animated {
                    toggleItem(index)
                }
            } label: {
                MacChecklistStatusChip(status: status)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cycle status")
            .accessibilityValue(status.title)

            Menu {
                ForEach(checklist.statuses.sorted { $0.sortOrder < $1.sortOrder }) { status in
                    Button {
                        animated {
                            setStatus(status.id, index)
                        }
                    } label: {
                        Label(status.title, systemImage: status.systemImage)
                    }
                }
                Divider()
                Button("Edit Statuses", action: editStatuses)
            } label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
        }
    }

    private func animated(_ updates: () -> Void) {
        AppMotion.perform(reduceMotion: reduceMotion, updates)
    }
}

private struct MacChecklistStatusChip: View {
    let status: NoteChecklistStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(status.isCompleted ? Color.accentColor : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((status.isCompleted ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
    }
}

private struct MacTrackerEditorView: View {
    let tracker: NoteTracker
    @Binding var counterDraft: String
    @Binding var memoDraft: String
    @Binding var unitDraft: String
    @Binding var quickAddsDraft: String
    let addCounter: () -> Void
    let record: (UUID, Double) -> Void
    let archiveCounter: (UUID) -> Void
    let undoLastEvent: () -> Void
    let saveSettings: () -> Void

    private var activeCounters: [NoteTracker.Counter] {
        NoteTrackerStore.activeCounters(in: tracker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            totals
            settings
            counterList
            recentEvent
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Tracker", systemImage: "plus.forwardslash.minus")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(NoteTrackerStore.summary(for: NoteTrackerStore.body(from: tracker)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var totals: some View {
        HStack(spacing: 8) {
            ForEach(NoteTrackerPeriod.allCases, id: \.title) { period in
                VStack(alignment: .leading, spacing: 4) {
                    Text(period.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(NoteTrackerStore.formatted(NoteTrackerStore.total(in: tracker, period: period))) \(tracker.unitLabel)")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Unit, e.g. hours", text: $unitDraft)
                    .macInputField()
                TextField("Quick adds, e.g. 0.25, 0.5, 1, 2", text: $quickAddsDraft)
                    .macInputField()
                Button("Save", action: saveSettings)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                TextField("Counter name, e.g. Engineering", text: $counterDraft)
                    .macInputField()
                    .onSubmit(addCounter)
                Button("Add Counter", action: addCounter)
                    .controlSize(.small)
                    .disabled(counterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var counterList: some View {
        if activeCounters.isEmpty {
            ContentUnavailableView(
                "No Counters",
                systemImage: "plus.forwardslash.minus",
                description: Text("Add counters like Engineering, Meetings, or Admin.")
            )
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Optional memo for the next entry", text: $memoDraft)
                        .macInputField()
                    if !memoDraft.isEmpty {
                        Button("Clear") { memoDraft = "" }
                            .controlSize(.small)
                    }
                }

                ForEach(activeCounters) { counter in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(counter.name)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("\(NoteTrackerStore.formatted(NoteTrackerStore.total(in: tracker, counterID: counter.id))) \(tracker.unitLabel) all time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Archive") { archiveCounter(counter.id) }
                                .controlSize(.small)
                        }

                        HStack(spacing: 8) {
                            ForEach(tracker.quickAdds, id: \.self) { amount in
                                Button("+\(NoteTrackerStore.formatted(amount))") {
                                    record(counter.id, amount)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private var recentEvent: some View {
        if let lastEvent = NoteTrackerStore.lastEventDescription(in: tracker) {
            HStack {
                Label("Last entry: \(lastEvent)", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo", action: undoLastEvent)
                    .controlSize(.small)
            }
            .padding(10)
            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct MacTagEditor: View {
    @Bindable var note: Note
    @Binding var tagDraft: String
    let save: () -> Void
    @FocusState private var tagFieldFocused: Bool

    private var canEdit: Bool {
        note.deletedAt == nil
    }

    private var canAdd: Bool {
        canEdit && !tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                if note.tags.isEmpty {
                    Text("No tags yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(note.tags) { tag in
                        tagChip(tag)
                    }
                }
            } header: {
                Text("Tags")
            } footer: {
                Text(canEdit ? "Organize this note without adding visible text." : "Archived notes are read-only.")
            }

            if canEdit {
                Section {
                    TextField("Tag name", text: $tagDraft)
                        .focused($tagFieldFocused)
                        .onSubmit {
                            if canAdd { addTag() }
                        }
                    Button("Add", action: addTag)
                        .disabled(!canAdd)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .onAppear {
            tagFieldFocused = canEdit
        }
    }

    private func tagChip(_ tag: NoteTag) -> some View {
        HStack(spacing: 5) {
            Text(tag.name)
                .lineLimit(1)

            if canEdit {
                Button {
                    remove(tag)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove tag")
                .accessibilityLabel("Remove \(tag.name) tag")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .contextMenu {
            if canEdit {
                Button("Remove Tag") {
                    remove(tag)
                }
            }
        }
    }

    private func addTag() {
        let name = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.addTagIfNeeded(name) else { return }
        tagDraft = ""
        save()
    }

    private func remove(_ tag: NoteTag) {
        note.tags.removeAll { $0.id == tag.id }
        save()
    }
}

private struct MacShareView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var note: Note
    @Binding var email: String
    let save: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)
                Button("Add Viewer") {
                    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    note.shares.append(NoteShare(email: trimmed, role: .viewer, note: note))
                    email = ""
                    save()
                }
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Collaborate")
            } footer: {
                Text("Invite someone by email to model Simplenote-style editable sharing.")
            }

            Section("Viewers") {
                if note.shares.isEmpty {
                    Text("No viewers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(note.shares) { share in
                        LabeledContent(share.email, value: share.role.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 480, height: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct MacPublishView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var note: Note
    @Binding var slug: String
    let save: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("public-slug", text: $slug)
                Button(note.publications.contains(where: \.isPublic) ? "Update Publication" : "Publish Note") {
                    let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let publication = note.publications.first ?? PublishedNote(note: note)
                    publication.slug = trimmed
                    publication.isPublic = true
                    publication.publishedAt = Date()
                    if note.publications.isEmpty {
                        note.publications.append(publication)
                    }
                    save()
                    dismiss()
                }
                .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Publish to Web")
            } footer: {
                Text("Anyone with the link can view published note contents. Avoid publishing private notes.")
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

private struct MacOrganizeActionButton: View {
    let title: String
    let isOrganizing: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isOrganizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isOrganizing ? "Organizing…" : title)
            }
        }
        .disabled(isOrganizing)
        .accessibilityIdentifier("wisk.mac.note.organizeButton")
        .accessibilityLabel(isOrganizing ? "Organizing this note" : title)
        .modifier(MacOrganizeButtonChrome(prominent: prominent))
    }
}

private struct MacOrganizeButtonChrome: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content
        }
    }
}

private struct MacReviewOrganizationPlaceholder: View {
    let phase: WiskNoteOrganizationPhase
    let emptyDescription: String
    let organizeNow: () -> Void

    var body: some View {
        switch phase {
        case .organizing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Organizing this note…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Organizing this note")
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not organize", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry", action: organizeNow)
                    .accessibilityIdentifier("wisk.mac.note.organizeRetryButton")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle:
            ContentUnavailableView(
                "No Review Items",
                systemImage: "sparkles",
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MacReviewOrganizationBanner: View {
    let phase: WiskNoteOrganizationPhase
    let organizeNow: () -> Void

    var body: some View {
        switch phase {
        case .organizing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Organizing this note…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Organizing this note")
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Retry", action: organizeNow)
                    .controlSize(.small)
                    .accessibilityIdentifier("wisk.mac.note.organizeRetryButton")
            }
        case .idle:
            EmptyView()
        }
    }
}

private struct MacInlineReviewPanel: View {
    @Bindable var note: Note
    let buckets: [NoteBucket]
    let hasProAccess: Bool
    let organizationPhase: WiskNoteOrganizationPhase
    let organizeNow: () -> Void
    let hideReview: () -> Void
    let acceptItem: (ParsedNoteItem) -> Void
    let rejectItem: (ParsedNoteItem) -> Void
    let assignBucket: (ParsedNoteItem, String?) -> Void

    private var visibleItems: [ParsedNoteItem] {
        note.parsedItems
            .filter { $0.rejectedAt == nil && $0.archivedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !hasProAccess {
                MacCompactProCallout(action: organizeNow)
            } else if visibleItems.isEmpty {
                MacReviewOrganizationPlaceholder(
                    phase: organizationPhase,
                    emptyDescription: "Click Organize to build tasks, learnings, references, and bucket suggestions from this note.",
                    organizeNow: organizeNow
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    MacReviewOrganizationBanner(phase: organizationPhase, organizeNow: organizeNow)
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleItems) { item in
                                MacReviewItemRow(
                                    item: item,
                                    bucketChoices: MacBucketChoice.choices(from: buckets, fallbackItems: visibleItems),
                                    showSourceLink: false,
                                    accept: { acceptItem(item) },
                                    reject: { rejectItem(item) },
                                    assignBucket: { assignBucket(item, $0) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(Color.macEditorBackground)
        .overlay(alignment: .leading) {
            Divider()
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.accent)
                .frame(width: 28, height: 28)
                .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Wisk Review")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if hasProAccess {
                MacOrganizeActionButton(
                    title: "Organize",
                    isOrganizing: organizationPhase.isOrganizing,
                    action: organizeNow
                )
                .controlSize(.small)
                .fixedSize()
            }

            Button(action: hideReview) {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .help("Hide Wisk Review")
            .accessibilityLabel("Hide Wisk Review")
            .accessibilityIdentifier("wisk.mac.note.hideReviewButton")
        }
    }

    private var headerSubtitle: String {
        if organizationPhase.isOrganizing {
            return "Organizing this note…"
        }
        if let message = organizationPhase.failureMessage {
            return message
        }
        return "Accept, reject, or bucket what Wisk finds without leaving the note."
    }
}

private struct MacCompactProCallout: View {
    @Environment(WiskProEntitlementService.self) private var proEntitlement

    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 28, height: 28)
                    .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Wisk AI")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Extract tasks, learnings, references, and bucket suggestions from your notes.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                calloutButtons(axis: .horizontal)
                calloutButtons(axis: .vertical)
            }

            if let purchaseError = proEntitlement.purchaseError {
                Text(purchaseError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.6)
        )
        .task {
            await proEntitlement.refreshEntitlements()
        }
    }

    @ViewBuilder
    private func calloutButtons(axis: Axis) -> some View {
        if axis == .horizontal {
            HStack(spacing: 8) {
                viewPlansButton
                restoreButton
            }
            .controlSize(.small)
            .fixedSize()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                viewPlansButton
                restoreButton
            }
            .controlSize(.small)
        }
    }

    private var viewPlansButton: some View {
        Button("View Plans", action: action)
            .buttonStyle(.borderedProminent)
    }

    private var restoreButton: some View {
        Button(proEntitlement.isRefreshingEntitlements ? "Checking..." : "Restore") {
            Task {
                await proEntitlement.restorePurchases()
            }
        }
        .buttonStyle(.borderless)
        .disabled(proEntitlement.isRefreshingEntitlements)
    }
}

enum MacBucketMode: String, CaseIterable, Identifiable {
    case inbox = "Inbox"
    case accepted = "Accepted"
    case definitions = "Definitions"

    var id: String { rawValue }
}

struct MacBucketQueueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Query(sort: \ParsedNoteItem.createdAt, order: .reverse) private var items: [ParsedNoteItem]
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var buckets: [NoteBucket]

    @Binding var mode: MacBucketMode
    @Binding var selectedItemID: UUID?
    @Binding var selectedBucketID: UUID?

    private var pendingItems: [ParsedNoteItem] {
        items.filter { $0.acceptedAt == nil && $0.rejectedAt == nil && $0.archivedAt == nil && $0.completedAt == nil }
    }

    private var acceptedItems: [ParsedNoteItem] {
        items.filter { $0.acceptedAt != nil && $0.rejectedAt == nil && $0.archivedAt == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Buckets mode", selection: $mode) {
                Text("Inbox").tag(MacBucketMode.inbox)
                Text("Accepted").tag(MacBucketMode.accepted)
                Text("Definitions").tag(MacBucketMode.definitions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    summaryCards

                    switch mode {
                    case .inbox:
                        itemList(
                            pendingItems,
                            emptyTitle: proEntitlement.hasProAccess ? "Inbox is clear" : "Bucket suggestions need Pro",
                            emptyDescription: proEntitlement.hasProAccess
                                ? "Run Review with Wisk on a note to fill this queue."
                                : "You can define buckets now, then upgrade when you want Wisk to triage notes automatically."
                        )
                    case .accepted:
                        itemList(
                            acceptedItems,
                            emptyTitle: "Nothing accepted yet",
                            emptyDescription: "Accepted suggestions will appear here grouped by bucket."
                        )
                    case .definitions:
                        bucketList
                    }
                }
                .padding(12)
                .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: mode)
                .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: selectedItemID)
                .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: selectedBucketID)
            }

            bucketStatusBar
        }
        .wiskNoteListCanvas()
        .navigationTitle("Buckets")
        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 560)
        .onAppear(perform: reconcileSelection)
        .onChange(of: mode) { _, _ in reconcileSelection() }
        .onChange(of: items.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: buckets.map(\.id)) { _, _ in reconcileSelection() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review Wisk’s queue and bucket definitions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var summaryCards: some View {
        HStack(spacing: 8) {
            summaryCard("Inbox", count: pendingItems.count, systemImage: "tray")
            summaryCard("Accepted", count: acceptedItems.count, systemImage: "checkmark.circle")
            summaryCard("Defs", count: buckets.count, systemImage: "square.stack.3d.up")
        }
        .padding(.bottom, 2)
    }

    private func summaryCard(_ title: String, count: Int, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.accent)
            Text("\(count)")
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private func itemList(_ items: [ParsedNoteItem], emptyTitle: String, emptyDescription: String) -> some View {
        if items.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: mode == .inbox ? "tray" : "checkmark.circle", description: Text(emptyDescription))
                .frame(maxWidth: .infinity, minHeight: 220)
                .transition(.opacity)
        } else {
            ForEach(items) { item in
                Button {
                    selectedItemID = item.id
                    selectedBucketID = nil
                } label: {
                    bucketItemRow(item)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wisk.mac.buckets.item.\(item.id.uuidString)")
            }
        }
    }

    private func bucketItemRow(_ item: ParsedNoteItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.itemType.iconName)
                .foregroundStyle(item.itemType.tint)
                .frame(width: 26, height: 26)
                .background(item.itemType.tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title.nilIfEmpty ?? "Untitled item")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(MacBucketChoice.title(for: item.bucketId, buckets: buckets))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note = item.note {
                    Text(note.title.nilIfEmpty ?? "Untitled note")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(selectedItemID == item.id ? Color.accent.opacity(0.14) : Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selectedItemID == item.id ? Color.accent.opacity(0.45) : Color.cardBorder, lineWidth: 0.6)
        )
        .transition(AppMotion.transition(reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private var bucketList: some View {
        if buckets.isEmpty {
            ContentUnavailableView(
                "No buckets yet",
                systemImage: "square.stack.3d.up",
                description: Text("Use the detail pane to create a definition for Wisk to sort against.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
            .transition(.opacity)
        } else {
            ForEach(buckets) { bucket in
                Button {
                    selectedBucketID = bucket.id
                    selectedItemID = nil
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: bucket.isDefault ? "star.fill" : "square.stack.3d.up")
                            .foregroundStyle(.accent)
                            .frame(width: 26, height: 26)
                            .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            Text(bucket.name.nilIfEmpty ?? "Untitled bucket")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(bucket.descriptionText.nilIfEmpty ?? "No description yet.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(selectedBucketID == bucket.id ? Color.accent.opacity(0.14) : Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selectedBucketID == bucket.id ? Color.accent.opacity(0.45) : Color.cardBorder, lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wisk.mac.buckets.definition.\(bucket.id.uuidString)")
            }
        }
    }

    private var bucketStatusBar: some View {
        HStack {
            Text(statusLabel)
            Spacer()
            Text("\(pendingItems.count) pending")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var statusLabel: String {
        switch mode {
        case .inbox: return "Bucket Inbox"
        case .accepted: return "Accepted Suggestions"
        case .definitions: return "Bucket Definitions"
        }
    }

    private func reconcileSelection() {
        switch mode {
        case .inbox:
            selectedBucketID = nil
            if let selectedItemID, pendingItems.contains(where: { $0.id == selectedItemID }) {
                return
            }
            selectedItemID = pendingItems.first?.id
        case .accepted:
            selectedBucketID = nil
            if let selectedItemID, acceptedItems.contains(where: { $0.id == selectedItemID }) {
                return
            }
            selectedItemID = acceptedItems.first?.id
        case .definitions:
            selectedItemID = nil
            if let selectedBucketID, buckets.contains(where: { $0.id == selectedBucketID }) {
                return
            }
            selectedBucketID = buckets.first?.id
        }
    }
}

struct MacBucketReviewView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Environment(SyncService.self) private var syncService
    @Query(sort: \ParsedNoteItem.createdAt, order: .reverse) private var items: [ParsedNoteItem]
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var buckets: [NoteBucket]

    @Binding var mode: MacBucketMode
    @Binding var selectedItemID: UUID?
    @Binding var selectedBucketID: UUID?
    let selectNote: (Note) -> Void

    @State private var editingBucketID: UUID?
    @State private var bucketNameDraft = ""
    @State private var bucketDescriptionDraft = ""
    @State private var bucketExamplesDraft = ""

    private var pendingItems: [ParsedNoteItem] {
        items.filter { $0.acceptedAt == nil && $0.rejectedAt == nil && $0.archivedAt == nil && $0.completedAt == nil }
    }

    private var acceptedItems: [ParsedNoteItem] {
        items.filter { $0.acceptedAt != nil && $0.rejectedAt == nil && $0.archivedAt == nil }
    }

    private var selectedReviewItem: ParsedNoteItem? {
        switch mode {
        case .inbox:
            return pendingItems.first { $0.id == selectedItemID }
        case .accepted:
            return acceptedItems.first { $0.id == selectedItemID }
        case .definitions:
            return nil
        }
    }

    private var selectedBucket: NoteBucket? {
        buckets.first { $0.id == selectedBucketID }
    }

    private var acceptedGroups: [MacAcceptedBucketGroup] {
        let accepted = items.filter { $0.acceptedAt != nil && $0.rejectedAt == nil && $0.archivedAt == nil }
        return Dictionary(grouping: accepted) { item in
            item.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        .map { bucketID, groupedItems in
            MacAcceptedBucketGroup(
                bucketID: bucketID,
                title: MacBucketChoice.title(for: bucketID, buckets: buckets),
                items: groupedItems.sorted { ($0.acceptedAt ?? .distantPast) > ($1.acceptedAt ?? .distantPast) }
            )
        }
        .sorted { lhs, rhs in
            if lhs.bucketID == nil { return false }
            if rhs.bucketID == nil { return true }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !proEntitlement.hasProAccess {
                        proInlineCallout
                    }

                    Group {
                        switch mode {
                        case .inbox, .accepted:
                            selectedItemDetail
                        case .definitions:
                            bucketDefinitions
                        }
                    }
                    .id(mode.rawValue)
                    .transition(AppMotion.transition(reduceMotion: reduceMotion))
                }
                .padding(24)
                .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: mode)
            }
        }
        .wiskEditorCanvas()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.accent)
                .frame(width: 44, height: 44)
                .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 24, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if proEntitlement.hasProAccess {
                if let sourceNote = selectedReviewItem?.note {
                    Button("Open Source Note") {
                        selectNote(sourceNote)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Unlock Pro") {
                    openProUpgrade()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private var headerTitle: String {
        switch mode {
        case .inbox: return "Bucket Inbox"
        case .accepted: return "Accepted Suggestions"
        case .definitions: return "Bucket Definitions"
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .inbox:
            return selectedReviewItem == nil
                ? "Choose a suggestion from the queue to review it here."
                : "Accept, reject, bucket, or jump back to the source note."
        case .accepted:
            return selectedReviewItem == nil
                ? "Accepted suggestions will appear here after review."
                : "Accepted items stay editable so you can rebucket them later."
        case .definitions:
            return selectedBucket == nil
                ? "Create and maintain the bucket definitions Wisk uses during organization."
                : "Edit the selected definition or add another bucket."
        }
    }

    private var acceptedItemCount: Int {
        items.filter { $0.acceptedAt != nil && $0.rejectedAt == nil && $0.archivedAt == nil }.count
    }

    private var proInlineCallout: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.accent)
                .frame(width: 32, height: 32)
                .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("AI triage is part of Wisk Pro")
                    .font(.system(size: 14, weight: .semibold))
                Text("You can still create bucket definitions. Upgrade when you want Wisk to extract and sort suggestions automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Unlock Pro") {
                openProUpgrade()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private var selectedItemDetail: some View {
        if !proEntitlement.hasProAccess {
            gatedEmptyState(
                title: "Unlock bucket suggestions",
                systemImage: "sparkles.rectangle.stack",
                description: "Wisk Pro extracts tasks, references, and learnings from notes, then suggests the best bucket for each item."
            )
        } else if let item = selectedReviewItem {
            VStack(alignment: .leading, spacing: 14) {
                MacReviewItemRow(
                    item: item,
                    bucketChoices: MacBucketChoice.choices(from: buckets, fallbackItems: items),
                    showSourceLink: true,
                    selectNote: selectNote,
                    accept: { accept(item) },
                    reject: { reject(item) },
                    assignBucket: { assignBucket(item, bucketID: $0) }
                )

                if let sourceNote = item.note {
                    sourceNoteCard(sourceNote)
                }
            }
        } else {
            ContentUnavailableView(
                mode == .inbox ? "No Suggestion Selected" : "No Accepted Item Selected",
                systemImage: mode == .inbox ? "tray" : "checkmark.circle",
                description: Text(mode == .inbox ? "Select a suggestion in the Buckets queue." : "Select an accepted suggestion in the Buckets queue.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private func sourceNoteCard(_ note: Note) -> some View {
        Button {
            selectNote(note)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "note.text")
                    .foregroundStyle(.accent)
                    .frame(width: 32, height: 32)
                    .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Source note")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(note.title.nilIfEmpty ?? "Untitled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(MacNoteSearch.excerpt(for: note, searchText: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cardBorder, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var inboxColumn: some View {
        if !proEntitlement.hasProAccess {
            gatedEmptyState(
                title: "Unlock bucket suggestions",
                systemImage: "sparkles.rectangle.stack",
                description: "Wisk Pro extracts tasks, references, and learnings from notes, then suggests the best bucket for each item."
            )
        } else if pendingItems.isEmpty {
            ContentUnavailableView(
                "No Bucket Suggestions Yet",
                systemImage: "tray",
                description: Text("Open a note and choose Review with Wisk to extract tasks, references, and learnings.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            ForEach(pendingItems) { item in
                MacReviewItemRow(
                    item: item,
                    bucketChoices: MacBucketChoice.choices(from: buckets, fallbackItems: pendingItems),
                    showSourceLink: true,
                    selectNote: selectNote,
                    accept: { accept(item) },
                    reject: { reject(item) },
                    assignBucket: { assignBucket(item, bucketID: $0) }
                )
                .transition(AppMotion.transition(reduceMotion: reduceMotion))
            }
        }
    }

    @ViewBuilder
    private var acceptedColumn: some View {
        if !proEntitlement.hasProAccess {
            gatedEmptyState(
                title: "Accepted items need Wisk Pro",
                systemImage: "checkmark.circle",
                description: "Accepted suggestions will appear here grouped by bucket after Wisk organizes your notes."
            )
        } else if acceptedGroups.isEmpty {
            ContentUnavailableView(
                "Nothing Accepted Yet",
                systemImage: "checkmark.circle",
                description: Text("Accepted items will be grouped by bucket here.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            ForEach(acceptedGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(group.items) { item in
                        MacReviewItemRow(
                            item: item,
                            bucketChoices: MacBucketChoice.choices(from: buckets, fallbackItems: group.items),
                            showSourceLink: true,
                            selectNote: selectNote,
                            accept: { accept(item) },
                            reject: { reject(item) },
                            assignBucket: { assignBucket(item, bucketID: $0) }
                        )
                        .transition(AppMotion.transition(reduceMotion: reduceMotion))
                    }
                }
                .transition(AppMotion.transition(reduceMotion: reduceMotion))
            }
        }
    }

    private var bucketDefinitions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bucket definitions")
                    .font(.headline)
                Text("Define how Wisk groups suggestions. Names, descriptions, and examples are sent with each organize request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Bucket name, e.g. Learnings", text: $bucketNameDraft)
                    .macInputField()
                TextField("Description", text: $bucketDescriptionDraft)
                    .macInputField()
                TextField("Examples, comma separated", text: $bucketExamplesDraft)
                    .macInputField()
                HStack {
                    Button(editingBucketID == nil ? "Add Bucket" : "Save Bucket", action: saveBucketDraft)
                        .buttonStyle(.borderedProminent)
                        .disabled(bucketNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editingBucketID != nil {
                        Button("Cancel", action: clearBucketDraft)
                    }
                    if buckets.isEmpty {
                        Button("Create Tasks Bucket", action: seedTasksBucket)
                    }
                }
            }
            .padding(14)
            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if buckets.isEmpty {
                ContentUnavailableView(
                    "No Buckets Yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Define buckets so Wisk knows how to sort tasks, references, learnings, and follow-ups.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(buckets) { bucket in
                    bucketCard(bucket)
                        .transition(AppMotion.transition(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func gatedEmptyState(title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            HStack {
                Button("Unlock Wisk Pro") {
                    openProUpgrade()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func bucketCard(_ bucket: NoteBucket) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(bucket.name.nilIfEmpty ?? "Untitled bucket")
                        .font(.system(size: 14, weight: .semibold))
                    if bucket.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accent.opacity(0.12), in: Capsule())
                    }
                    Text("\(acceptedCount(for: bucket)) accepted")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(bucket.descriptionText.nilIfEmpty ?? "No description yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !bucket.examples.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(bucket.examples.prefix(4), id: \.self) { example in
                            Text(example)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        }
                    }
                }
            }
            Spacer()
            Menu {
                Button("Edit") { edit(bucket) }
                Button("Set as Default") { setDefault(bucket) }
                    .disabled(bucket.isDefault)
                Divider()
                Button("Archive", role: .destructive) { archive(bucket) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
        }
        .padding(12)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.6)
        )
    }

    private func acceptedCount(for bucket: NoteBucket) -> Int {
        items.filter {
            $0.acceptedAt != nil &&
                $0.rejectedAt == nil &&
                $0.archivedAt == nil &&
                $0.bucketId == bucket.id.uuidString
        }.count
    }

    private func openProUpgrade() {
        openWindow(id: "wisk-pro", value: WiskProUpgradeContext.buckets)
    }

    private func accept(_ item: ParsedNoteItem) {
        item.reviewStatus = .accepted
        item.userEdited = true
        item.updatedAt = Date()
        save(item.note)
    }

    private func reject(_ item: ParsedNoteItem) {
        item.reviewStatus = .rejected
        item.userEdited = true
        item.updatedAt = Date()
        save(item.note)
    }

    private func assignBucket(_ item: ParsedNoteItem, bucketID: String?) {
        item.bucketId = bucketID
        item.userEdited = true
        item.updatedAt = Date()
        save(item.note)
    }

    private func saveBucketDraft() {
        let name = bucketNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if let editingBucketID, let bucket = buckets.first(where: { $0.id == editingBucketID }) {
            bucket.name = name
            bucket.descriptionText = bucketDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            bucket.examples = bucketExamplesDraft.split(separator: ",").map(String.init)
            bucket.updatedAt = Date()
        } else {
            let bucket = NoteBucket(
                name: name,
                descriptionText: bucketDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                examples: bucketExamplesDraft.split(separator: ",").map(String.init),
                sortOrder: (buckets.map(\.sortOrder).max() ?? -1) + 1,
                isDefault: buckets.isEmpty
            )
            modelContext.insert(bucket)
        }

        clearBucketDraft()
        save(nil)
    }

    private func seedTasksBucket() {
        bucketNameDraft = NoteBucketSeedService.defaultTasksBucketName
        bucketDescriptionDraft = "Default bucket for actionable tasks and reminders."
        bucketExamplesDraft = "Follow up with Alex, Pay internet bill, Book dentist appointment"
        saveBucketDraft()
    }

    private func edit(_ bucket: NoteBucket) {
        editingBucketID = bucket.id
        bucketNameDraft = bucket.name
        bucketDescriptionDraft = bucket.descriptionText
        bucketExamplesDraft = bucket.examples.joined(separator: ", ")
    }

    private func clearBucketDraft() {
        editingBucketID = nil
        bucketNameDraft = ""
        bucketDescriptionDraft = ""
        bucketExamplesDraft = ""
    }

    private func setDefault(_ bucket: NoteBucket) {
        for existing in buckets {
            existing.isDefault = existing.id == bucket.id
            existing.updatedAt = Date()
        }
        save(nil)
    }

    private func archive(_ bucket: NoteBucket) {
        bucket.archivedAt = Date()
        bucket.updatedAt = Date()
        save(nil)
    }

    private func save(_ note: Note?) {
        note?.updatedAt = Date()
        note?.syncStatus = .queued
        try? modelContext.save()
        if let note {
            syncService.enqueue(note: note, context: modelContext)
        }
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }
}

private struct MacReviewItemRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: ParsedNoteItem
    let bucketChoices: [MacBucketChoice]
    let showSourceLink: Bool
    var selectNote: ((Note) -> Void)?
    let accept: () -> Void
    let reject: () -> Void
    let assignBucket: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.itemType.iconName)
                    .foregroundStyle(item.itemType.tint)
                    .frame(width: 28, height: 28)
                    .background(item.itemType.tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title.nilIfEmpty ?? "Untitled item")
                        .font(.system(size: 13, weight: .semibold))
                    Text(item.rawText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    HStack(spacing: 6) {
                        MacChip(title: item.itemType.label, tint: item.itemType.tint)
                        MacChip(title: bucketChoices.first(where: { $0.bucketID == item.bucketId })?.name ?? "Unbucketed", tint: .accent)
                        Menu("Change") {
                            Button("No bucket") {
                                AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                                    assignBucket(nil)
                                }
                            }
                            ForEach(bucketChoices) { choice in
                                Button(choice.name) {
                                    AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                                        assignBucket(choice.bucketID)
                                    }
                                }
                            }
                        }
                        .font(.caption)
                    }
                }

                Spacer()

                VStack(spacing: 8) {
                    Button {
                        AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                            accept()
                        }
                    } label: {
                        Image(systemName: item.acceptedAt == nil ? "checkmark.circle" : "checkmark.circle.fill")
                    }
                    Button {
                        AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                            reject()
                        }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.accent)
            }

            if showSourceLink, let note = item.note {
                Button {
                    selectNote?(note)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                        Text("Source note: \(note.title.nilIfEmpty ?? "Untitled")")
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 0.6)
        )
        .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: item.acceptedAt)
        .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: item.bucketId)
    }
}

private struct MacChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct MacAcceptedBucketGroup: Identifiable {
    let bucketID: String?
    let title: String
    let items: [ParsedNoteItem]

    var id: String { bucketID ?? "__none" }
}

private struct MacBucketChoice: Identifiable, Hashable {
    let bucketID: String
    let name: String

    var id: String { bucketID }

    static func choices(from buckets: [NoteBucket], fallbackItems: [ParsedNoteItem]) -> [MacBucketChoice] {
        let configured = buckets.map {
            MacBucketChoice(bucketID: $0.id.uuidString, name: $0.name.nilIfEmpty ?? "Untitled bucket")
        }
        let dynamic = Set(fallbackItems.compactMap { $0.bucketId?.nilIfEmpty }).map {
            MacBucketChoice(bucketID: $0, name: title(for: $0, buckets: buckets))
        }
        var merged = Dictionary(uniqueKeysWithValues: configured.map { ($0.bucketID, $0) })
        dynamic.forEach { merged[$0.bucketID] = $0 }
        return merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func title(for bucketID: String?, buckets: [NoteBucket]) -> String {
        guard let raw = bucketID?.nilIfEmpty else { return "Unbucketed" }
        if let configured = buckets.first(where: { $0.id.uuidString == raw }) {
            return configured.name.nilIfEmpty ?? "Untitled bucket"
        }
        let normalized = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Unbucketed" : normalized.capitalized
    }
}

private struct MacAIInspectorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Bindable var note: Note
    let buckets: [NoteBucket]
    let hasProAccess: Bool
    let organizationPhase: WiskNoteOrganizationPhase
    @Binding var statusMessage: String?
    let organizeNow: () -> Void
    let acceptItem: (ParsedNoteItem) -> Void
    let rejectItem: (ParsedNoteItem) -> Void
    let assignBucket: (ParsedNoteItem, String?) -> Void

    private var visibleItems: [ParsedNoteItem] {
        note.parsedItems.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var inspectorStatusText: String {
        if organizationPhase.isOrganizing {
            return "Organizing this note…"
        }
        if let message = organizationPhase.failureMessage {
            return message
        }
        return statusMessage ?? "Extract tasks, learnings, references, tags, and bucket suggestions from this note."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasProAccess {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.accent)
                        .frame(width: 44, height: 44)
                        .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wisk Review")
                            .font(.system(size: 24, weight: .semibold))
                        Text(inspectorStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    MacOrganizeActionButton(
                        title: "Organize Now",
                        isOrganizing: organizationPhase.isOrganizing,
                        prominent: true,
                        action: organizeNow
                    )
                }
                .padding(20)

                Divider()

                if visibleItems.isEmpty {
                    MacReviewOrganizationPlaceholder(
                        phase: organizationPhase,
                        emptyDescription: "Run Wisk when this note has enough content to triage.",
                        organizeNow: organizeNow
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        MacReviewOrganizationBanner(phase: organizationPhase, organizeNow: organizeNow)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleItems) { item in
                                    MacReviewItemRow(
                                        item: item,
                                        bucketChoices: MacBucketChoice.choices(from: buckets, fallbackItems: visibleItems),
                                        showSourceLink: false,
                                        accept: { acceptItem(item) },
                                        reject: { rejectItem(item) },
                                        assignBucket: { assignBucket(item, $0) }
                                    )
                                    .transition(AppMotion.transition(reduceMotion: reduceMotion))
                                }
                            }
                            .padding(20)
                            .animation(AppMotion.animation(AppMotion.macSmooth, reduceMotion: reduceMotion), value: visibleItems.map(\.id))
                        }
                    }
                }
            } else {
                MacCompactProCallout(action: organizeNow)
                    .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)
            .background(.bar)
        }
        .background(Color.macEditorBackground)
        .frame(width: 560, height: 520)
    }
}

private struct MacNoteInfoView: View {
    let note: Note
    var listings: [WiskNoteLinkListing] = []
    var foldedSourceLocations: Binding<Set<Int>> = .constant([])
    var onJumpToSourceRange: ((NSRange) -> Void)? = nil

    var body: some View {
        Form {
            Section {
                LabeledContent("Created", value: MacNoteDateDisplay.formatted(note.createdAt))
                LabeledContent("Last edited", value: MacNoteDateDisplay.formatted(note.updatedAt))
            }

            Section("Statistics") {
                let statistics = WiskNoteStatistics.from(title: note.title, body: note.body)
                LabeledContent("Words", value: statistics.wordCount.formatted())
                LabeledContent("Characters", value: statistics.characterCount.formatted())
                LabeledContent("Read time", value: statistics.readTimeLabel)
            }

            WiskNoteLinkExtrasView(
                note: note,
                listings: listings,
                foldedSourceLocations: foldedSourceLocations,
                onJumpToSourceRange: onJumpToSourceRange
            )
        }
        .formStyle(.grouped)
        .navigationTitle("Note Info")
    }
}

enum MacNoteSearch {
    static func filteredNotes(
        _ notes: [Note],
        sidebarSelection: MacSidebarSelection,
        searchText: String,
        sortMode: MacNoteSortMode,
        includeAIFields: Bool
    ) -> [Note] {
        let parsedSearch = NoteSearchEngine.ParsedSearch(searchText)
        let filtered = notes.filter { note in
            matchesSidebar(note, sidebarSelection: sidebarSelection)
                && NoteSearchEngine.matchesTagQuery(note, tagQuery: parsedSearch.tagQuery)
                && NoteSearchEngine.matchesTerms(note, terms: parsedSearch.terms, includeAIFields: includeAIFields)
        }

        return sort(filtered, sortMode: sortMode)
    }

    static func filteredRecords(
        _ records: [NoteLibraryRecord],
        sidebarSelection: MacSidebarSelection,
        searchText: String,
        sortMode: MacNoteSortMode
    ) -> [NoteLibraryRecord] {
        let parsedSearch = NoteSearchEngine.ParsedSearch(searchText)
        let filtered = records.filter { record in
            matchesSidebar(record, sidebarSelection: sidebarSelection)
                && NoteLibraryIndex.matchesTagQuery(record, tagQuery: parsedSearch.tagQuery)
                && NoteLibraryIndex.matchesTerms(record, terms: parsedSearch.terms)
        }
        return sortRecords(filtered, sortMode: sortMode)
    }

    static func excerpt(for note: Note, searchText: String) -> String {
        if note.kind == .structured || NoteStructuredSections.containsStructuredMarkup(note.body) {
            return NoteStructuredSections.excerpt(for: note.body)
        }

        let terms = NoteSearchEngine.ParsedSearch(searchText).terms
        let lines = NoteStructuredSections.visibleBodyLines(in: note.body)
        guard !terms.isEmpty else {
            return lines.dropFirst().first ?? lines.first ?? ""
        }

        return lines.first { line in
            let lowercased = line.lowercased()
            return terms.contains { lowercased.contains($0) }
        } ?? lines.first ?? ""
    }

    private static func matchesSidebar(_ note: Note, sidebarSelection: MacSidebarSelection) -> Bool {
        switch sidebarSelection {
        case .allNotes:
            return note.deletedAt == nil
        case .adages:
            return false
        case .buckets:
            return note.deletedAt == nil
        case .trash:
            return note.deletedAt != nil
        case .untagged:
            return note.deletedAt == nil && note.tags.isEmpty
        case .tag(let tag):
            return note.deletedAt == nil && note.tags.contains { $0.name.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    private static func matchesSidebar(_ record: NoteLibraryRecord, sidebarSelection: MacSidebarSelection) -> Bool {
        switch sidebarSelection {
        case .allNotes:
            return record.deletedAt == nil
        case .adages:
            return false
        case .buckets:
            return record.deletedAt == nil
        case .trash:
            return record.deletedAt != nil
        case .untagged:
            return record.deletedAt == nil && record.tagNames.isEmpty
        case .tag(let tag):
            return record.deletedAt == nil && record.tagNames.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    private static func sortRecords(_ records: [NoteLibraryRecord], sortMode: MacNoteSortMode) -> [NoteLibraryRecord] {
        records.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned, lhs.deletedAt == nil, rhs.deletedAt == nil {
                return lhs.pinned
            }

            switch sortMode {
            case .modifiedNewest:
                return lhs.updatedAt > rhs.updatedAt
            case .modifiedOldest:
                return lhs.updatedAt < rhs.updatedAt
            case .createdNewest:
                return lhs.createdAt > rhs.createdAt
            case .createdOldest:
                return lhs.createdAt < rhs.createdAt
            case .titleAscending:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .titleDescending:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }
        }
    }

    private static func sort(_ notes: [Note], sortMode: MacNoteSortMode) -> [Note] {
        notes.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned, lhs.deletedAt == nil, rhs.deletedAt == nil {
                return lhs.pinned
            }

            switch sortMode {
            case .modifiedNewest:
                return lhs.updatedAt > rhs.updatedAt
            case .modifiedOldest:
                return lhs.updatedAt < rhs.updatedAt
            case .createdNewest:
                return lhs.createdAt > rhs.createdAt
            case .createdOldest:
                return lhs.createdAt < rhs.createdAt
            case .titleAscending:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .titleDescending:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }
        }
    }

}

private extension ParsedNoteItem {
    convenience init(draft: ParsedNoteItemDraft, sortOrder: Int, note: Note) {
        self.init(
            rawText: draft.rawText,
            title: draft.title,
            itemType: draft.itemType,
            status: draft.status,
            confidence: draft.confidence,
            sourceLineIndex: draft.sourceLineIndex,
            dueHint: draft.dueHint,
            project: draft.project,
            people: draft.people,
            bucketId: draft.bucketId,
            bucketReason: draft.bucketReason,
            acceptedAt: nil,
            completedAt: draft.status == .completed ? Date() : nil,
            sortOrder: sortOrder,
            note: note
        )
    }
}

private extension ParsedNoteItemType {
    var label: String {
        switch self {
        case .action: return "Action"
        case .learning: return "Learning"
        case .topic: return "Topic"
        case .reminder: return "Reminder"
        case .reference: return "Reference"
        }
    }

    var iconName: String {
        switch self {
        case .action: return "checkmark.circle"
        case .learning: return "lightbulb"
        case .topic: return "folder"
        case .reminder: return "bell"
        case .reference: return "bookmark"
        }
    }

    var tint: Color {
        switch self {
        case .action, .reminder: return .warmAction
        case .learning: return .learningMint
        case .topic: return .accent
        case .reference: return .wiskSecondaryText
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
