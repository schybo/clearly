import SwiftData
import SwiftUI

#if os(iOS)
/// Reuses a filtered note list when SwiftUI re-renders without a library change.
private final class WiskIOSVisibleNotesCache {
    private struct Key: Equatable {
        let recordsHash: Int
        let scope: WiskNotesScope
        let searchText: String
        let sortMode: WiskNoteSortMode
    }

    private var key: Key?
    private var records: [NoteLibraryRecord] = []
    private var tags: [String] = []

    func snapshot(
        libraryRecords: [NoteLibraryRecord],
        scope: WiskNotesScope,
        searchText: String,
        sortMode: WiskNoteSortMode
    ) -> (records: [NoteLibraryRecord], tags: [String]) {
        let newKey = Key(
            recordsHash: NoteLibraryIndex.listIdentityHash(for: libraryRecords),
            scope: scope,
            searchText: searchText,
            sortMode: sortMode
        )
        if newKey == key {
            return (records, tags)
        }
        let visible = NoteLibraryIndex.visibleRecords(
            libraryRecords,
            scope: scope,
            searchText: searchText,
            sortMode: sortMode
        )
        let activeTags = NoteLibraryIndex.activeTagNames(from: libraryRecords)
        key = newKey
        records = visible
        tags = activeTags
        return (visible, activeTags)
    }
}

private struct WiskLibraryPurgeProgress: Equatable {
    var status: String
    var completed: Int
    var total: Int
}

struct WiskIOSNotesRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(SyncService.self) private var syncService
    @Query(sort: \NoteLibraryRecord.updatedAt, order: .reverse) private var libraryRecords: [NoteLibraryRecord]

    @Binding var navigationPath: [UUID]
    @State private var selectedNoteID: UUID?
    @State private var searchText = ""
    @State private var scope: WiskNotesScope = .all
    @AppStorage("wisk.ios.noteSort") private var sortRawValue = WiskNoteSortMode.modifiedNewest.rawValue
    @State private var structuredTemplates = NoteStructuredSections.allTemplates()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var emptyingProgress: WiskLibraryPurgeProgress?
    @State private var emptyingTask: Task<Void, Never>?
    @State private var visibleNotesCache = WiskIOSVisibleNotesCache()

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var sortMode: WiskNoteSortMode {
        WiskNoteSortMode(rawValue: sortRawValue) ?? .modifiedNewest
    }

    private var listSnapshot: (records: [NoteLibraryRecord], tags: [String]) {
        visibleNotesCache.snapshot(
            libraryRecords: libraryRecords,
            scope: scope,
            searchText: searchText,
            sortMode: sortMode
        )
    }

    private var visibleRecords: [NoteLibraryRecord] {
        listSnapshot.records
    }

    private var activeTags: [String] {
        listSnapshot.tags
    }

    var body: some View {
        Group {
            if isRegularWidth {
                splitBrowser
            } else {
                compactBrowser
            }
        }
        .environment(\.wiskOpenNote, openNote)
        .overlay {
            if let emptyingProgress {
                WiskIOSLibraryPurgeOverlay(progress: emptyingProgress)
            }
        }
        .onAppear {
            refreshStructuredTemplates()
        }
    }

    private var compactBrowser: some View {
        NavigationStack(path: $navigationPath) {
            NotesHomeView(
                records: visibleRecords,
                allTags: activeTags,
                searchText: $searchText,
                scope: $scope,
                sortRawValue: $sortRawValue,
                structuredTemplates: $structuredTemplates,
                selectedNoteID: $selectedNoteID,
                usesSplitSelection: false,
                toggleSidebar: nil,
                openNote: openNote,
                createNote: createNote,
                createStructuredNote: createStructuredNote,
                createList: createList,
                createTracker: createTracker,
                archive: archive,
                trash: trash,
                restore: restore,
                togglePinned: togglePinned,
                duplicate: duplicate,
                emptyableCount: emptyableCount,
                emptyPermanently: emptyCurrentScopePermanently
            )
            .navigationDestination(for: UUID.self) { id in
                noteEditor(for: id)
            }
        }
    }

    private var splitBrowser: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WiskIOSNotesSidebar(
                scope: $scope,
                records: libraryRecords,
                tags: activeTags
            )
        } content: {
            NotesHomeView(
                records: visibleRecords,
                allTags: activeTags,
                searchText: $searchText,
                scope: $scope,
                sortRawValue: $sortRawValue,
                structuredTemplates: $structuredTemplates,
                selectedNoteID: $selectedNoteID,
                usesSplitSelection: true,
                toggleSidebar: toggleSidebar,
                openNote: openNote,
                createNote: createNote,
                createStructuredNote: createStructuredNote,
                createList: createList,
                createTracker: createTracker,
                archive: archive,
                trash: trash,
                restore: restore,
                togglePinned: togglePinned,
                duplicate: duplicate,
                emptyableCount: emptyableCount,
                emptyPermanently: emptyCurrentScopePermanently
            )
        } detail: {
            if let selectedNoteID, let note = note(for: selectedNoteID) {
                NavigationStack {
                    NoteEditorView(note: note)
                }
            } else {
                ContentUnavailableView(
                    "Select a Note",
                    systemImage: "note.text",
                    description: Text("Choose a note from the list, or create a new one.")
                )
                .wiskEditorCanvas()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func noteEditor(for id: UUID) -> some View {
        if let note = note(for: id) {
            NoteEditorView(note: note)
        } else {
            ContentUnavailableView("Note not found", systemImage: "questionmark.folder")
        }
    }

    private func toggleSidebar() {
        if columnVisibility == .all {
            columnVisibility = .doubleColumn
        } else if columnVisibility == .doubleColumn {
            columnVisibility = .detailOnly
        } else {
            columnVisibility = .all
        }
    }

    private func openNote(_ id: UUID) {
        if isRegularWidth {
            selectedNoteID = id
        } else {
            navigationPath.append(id)
        }
    }

    private func createNote() {
        insertAndOpen(Note(title: "", body: "", kind: .general))
    }

    private func createStructuredNote(template: StructuredNoteTemplate) {
        let note = Note(
            title: NoteStructuredSections.titleForNewNote(from: template),
            body: NoteStructuredSections.body(from: template),
            kind: .structured
        )
        note.markdownEnabled = true
        note.addTagIfNeeded(template.title)
        insertAndOpen(note)
    }

    private func createList() {
        insertAndOpen(Note(title: "", body: "", kind: .list))
    }

    private func createTracker() {
        insertAndOpen(Note(title: "", body: NoteTrackerStore.defaultBody(), kind: .tracker))
    }

    private func insertAndOpen(_ note: Note) {
        note.snapshotIfNeeded(reason: "created")
        modelContext.insert(note)
        NoteLibraryIndex.upsert(note, in: modelContext)
        try? modelContext.save()
        openNote(note.id)
    }

    private func archive(_ record: NoteLibraryRecord) {
        guard let note = note(for: record.noteID) else { return }
        note.archivedAt = Date()
        note.deletedAt = nil
        persistLibraryChange(note)
        if selectedNoteID == note.id { selectedNoteID = nil }
        navigationPath.removeAll { $0 == note.id }
    }

    private func trash(_ record: NoteLibraryRecord) {
        guard let note = note(for: record.noteID) else { return }
        note.deletedAt = Date()
        persistLibraryChange(note)
        if selectedNoteID == note.id { selectedNoteID = nil }
        navigationPath.removeAll { $0 == note.id }
    }

    private func restore(_ record: NoteLibraryRecord) {
        guard let note = note(for: record.noteID) else { return }
        note.deletedAt = nil
        note.archivedAt = nil
        persistLibraryChange(note)
    }

    private func togglePinned(_ record: NoteLibraryRecord) {
        guard let note = note(for: record.noteID), note.deletedAt == nil, note.archivedAt == nil else { return }
        note.pinned.toggle()
        persistLibraryChange(note)
    }

    private func duplicate(_ record: NoteLibraryRecord) {
        guard let note = note(for: record.noteID), note.deletedAt == nil else { return }
        let copy = note.duplicated()
        copy.snapshotIfNeeded(reason: "duplicated")
        modelContext.insert(copy)
        NoteLibraryIndex.upsert(copy, in: modelContext)
        copy.syncStatus = .queued
        try? modelContext.save()
        syncService.enqueue(note: copy, context: modelContext)
        Task {
            await syncService.syncNow(context: modelContext)
        }
        openNote(copy.id)
    }

    private func persistLibraryChange(_ note: Note) {
        note.updatedAt = Date()
        note.syncStatus = .queued
        NoteLibraryIndex.updateListFlags(note, in: modelContext)
        try? modelContext.save()
        syncService.enqueue(note: note, context: modelContext)
        // List-level mutations (pin, rename, archive, restore) are discrete
        // user actions, so push immediately — the 45s tick can't be relied on
        // because the app suspends before it fires when the user switches to
        // another device. Same pattern as the Mac's `saveAndQueue` and
        // `persistReviewChange` above.
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }

    private var emptyableCount: Int {
        switch scope {
        case .archive:
            return libraryRecords.filter { NoteLibraryIndex.matches($0, scope: .archive) }.count
        case .trash:
            return libraryRecords.filter { NoteLibraryIndex.matches($0, scope: .trash) }.count
        default:
            return 0
        }
    }

    private func emptyCurrentScopePermanently() {
        guard emptyingProgress == nil else { return }
        emptyingTask = Task { @MainActor in
            await performEmptyCurrentScope()
        }
    }

    private func performEmptyCurrentScope() async {
        let notes = WiskNoteFetch.allNotes(in: modelContext)
        switch scope {
        case .archive:
            await tombstoneAndPurgeArchivedNotes(NoteLibraryIndex.archivedNotes(in: notes))
        case .trash:
            await purgeNotes(
                NoteLibraryIndex.trashedNotes(in: notes),
                status: "Deleting notes in Trash…"
            )
        default:
            return
        }
        selectedNoteID = nil
        navigationPath.removeAll()
    }

    private func tombstoneAndPurgeArchivedNotes(_ notes: [Note]) async {
        guard notes.isEmpty == false else { return }
        let total = notes.count
        let now = Date()
        var completed = 0
        emptyingProgress = WiskLibraryPurgeProgress(
            status: "Marking archived notes as deleted…",
            completed: 0,
            total: total
        )
        for note in notes {
            note.deletedAt = now
            note.updatedAt = now
            NoteLibraryIndex.updateListFlags(note, in: modelContext)
            completed += 1
            if completed == total || completed % 25 == 0 {
                emptyingProgress = WiskLibraryPurgeProgress(
                    status: "Marking archived notes as deleted…",
                    completed: completed,
                    total: total
                )
                await Task.yield()
            }
        }
        try? modelContext.save()
        emptyingProgress = WiskLibraryPurgeProgress(
            status: "Syncing deleted notes…",
            completed: total,
            total: total
        )
        syncService.enqueue(notes: notes, operation: .noteDelete, context: modelContext)
        await syncService.syncNow(context: modelContext)
        await purgeNotes(notes, status: "Deleting archived notes…")
    }

    private func purgeNotes(_ notes: [Note], status: String) async {
        guard notes.isEmpty == false else {
            emptyingProgress = nil
            return
        }
        let total = notes.count
        var completed = 0
        emptyingProgress = WiskLibraryPurgeProgress(status: status, completed: 0, total: total)
        for note in notes {
            NoteLibraryIndex.purgeNote(note, in: modelContext)
            completed += 1
            if completed == total || completed % 25 == 0 {
                emptyingProgress = WiskLibraryPurgeProgress(
                    status: status,
                    completed: completed,
                    total: total
                )
                await Task.yield()
            }
        }
        try? modelContext.save()
        emptyingProgress = nil
    }

    private func refreshStructuredTemplates() {
        structuredTemplates = NoteStructuredSections.allTemplates()
    }

    private func note(for id: UUID) -> Note? {
        WiskNoteFetch.note(id: id, in: modelContext)
    }
}

private struct WiskIOSNotesSidebar: View {
    @Binding var scope: WiskNotesScope
    let records: [NoteLibraryRecord]
    let tags: [String]

    private var allCount: Int {
        records.filter { NoteLibraryIndex.matches($0, scope: .all) }.count
    }

    private var archiveCount: Int {
        records.filter { NoteLibraryIndex.matches($0, scope: .archive) }.count
    }

    private var trashCount: Int {
        records.filter { NoteLibraryIndex.matches($0, scope: .trash) }.count
    }

    var body: some View {
        List {
            Section("Library") {
                sidebarRow(.all, count: allCount)
                sidebarRow(.archive, count: archiveCount)
                sidebarRow(.trash, count: trashCount)
                sidebarRow(.untagged, count: records.filter { NoteLibraryIndex.matches($0, scope: .untagged) }.count)
            }
            if tags.isEmpty == false {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        sidebarRow(.tag(tag), count: records.filter { NoteLibraryIndex.matches($0, scope: .tag(tag)) }.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 32)
        .navigationTitle("Wisk")
    }

    private func sidebarRow(_ value: WiskNotesScope, count: Int) -> some View {
        Button {
            scope = value
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text(value.title)
                        .lineLimit(1)
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: value.systemImage)
                    .font(.system(size: 15, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .font(.body)
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .foregroundStyle(scope == value ? Color.accent : Color.primary)
        .accessibilityAddTraits(scope == value ? .isSelected : [])
        .accessibilityIdentifier("wisk.notes.scope.\(value.id)")
    }
}

struct NotesHomeView: View {
    let records: [NoteLibraryRecord]
    let allTags: [String]
    @Binding var searchText: String
    @Binding var scope: WiskNotesScope
    @Binding var sortRawValue: String
    @Binding var structuredTemplates: [StructuredNoteTemplate]
    @Binding var selectedNoteID: UUID?
    let usesSplitSelection: Bool
    let toggleSidebar: (() -> Void)?
    let openNote: (UUID) -> Void
    let createNote: () -> Void
    let createStructuredNote: (StructuredNoteTemplate) -> Void
    let createList: () -> Void
    let createTracker: () -> Void
    let archive: (NoteLibraryRecord) -> Void
    let trash: (NoteLibraryRecord) -> Void
    let restore: (NoteLibraryRecord) -> Void
    let togglePinned: (NoteLibraryRecord) -> Void
    let duplicate: (NoteLibraryRecord) -> Void
    let emptyableCount: Int
    let emptyPermanently: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAuthService.self) private var authService
    @Environment(SyncService.self) private var syncService
    @State private var confirmingEmptyPermanently = false
    @State private var showingAdages = false
    @State private var showingFilter = false
    @State private var filterFollowUp: WiskIOSNotesFilterFollowUp?

    private var sortMode: WiskNoteSortMode {
        WiskNoteSortMode(rawValue: sortRawValue) ?? .modifiedNewest
    }

    /// `List(selection:)` can emit a transient nil while the library query refreshes.
    private var splitListSelection: Binding<UUID?> {
        Binding(
            get: { selectedNoteID },
            set: { newValue in
                if let newValue {
                    selectedNoteID = newValue
                }
            }
        )
    }

    private var libraryEmptyKind: WiskLibraryEmptyKind {
        WiskLibraryEmptyKind.resolve(
            hasVisibleNotes: records.isEmpty == false,
            isUnfilteredLibrary: scope == .all && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isSignedIn: authService.firebaseUID != nil,
            hasCompletedAccountSync: syncService.hasCompletedAccountSync,
            syncState: syncService.state
        )
    }

    private var filterIsActive: Bool {
        if usesSplitSelection {
            return sortMode != .modifiedNewest
        }
        return scope != .all || sortMode != .modifiedNewest
    }

    private var topBar: some View {
        WiskIOSNotesTopBar(
            title: scope.title,
            filterIsActive: filterIsActive,
            showsSidebarToggle: toggleSidebar != nil,
            searchText: $searchText,
            onFilter: { showingFilter = true },
            onToggleSidebar: { toggleSidebar?() }
        )
    }

    var body: some View {
        notesList
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: records.isEmpty)
            .wiskNoteListCanvas()
            .navigationTitle(usesSplitSelection ? "" : scope.title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .modifier(WiskIOSNotesTopPlacement(bar: topBar))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    WiskIOSNotesCreateButtons(
                        structuredTemplates: structuredTemplates,
                        createNote: createNote,
                        createStructuredNote: createStructuredNote,
                        createList: createList,
                        createTracker: createTracker
                    )
                }
                .padding(.trailing, Spacing.lg)
                .padding(.bottom, Spacing.sm)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .sheet(isPresented: $showingFilter, onDismiss: {
                switch filterFollowUp {
                case .adages:
                    showingAdages = true
                case .emptyPermanently:
                    confirmingEmptyPermanently = true
                case nil:
                    break
                }
                filterFollowUp = nil
            }) {
                WiskIOSNotesFilterSheet(
                    scope: $scope,
                    sortRawValue: $sortRawValue,
                    tags: allTags,
                    showsLibrary: usesSplitSelection == false,
                    emptyableCount: emptyableCount,
                    onAdages: {
                        filterFollowUp = .adages
                        showingFilter = false
                    },
                    onEmptyPermanently: {
                        filterFollowUp = .emptyPermanently
                        showingFilter = false
                    }
                )
            }
            .sheet(isPresented: $showingAdages) {
                NavigationStack {
                    AdagesLibraryView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    showingAdages = false
                                }
                            }
                        }
                }
            }
            .confirmationDialog(
            "Delete \(emptyableCount.formatted()) \(scope == .archive ? "archived" : "trashed") notes permanently?",
            isPresented: $confirmingEmptyPermanently,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive, action: emptyPermanently)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Other devices keep their copies until you empty this list there too.")
        }
        .onAppear {
            seedIfNeeded()
            structuredTemplates = NoteStructuredSections.allTemplates()
        }
    }

    @ViewBuilder
    private var notesList: some View {
        if records.isEmpty {
            emptyState
        } else if usesSplitSelection {
            List(records, id: \.noteID, selection: splitListSelection) { record in
                listRow(record)
                    .tag(Optional(record.noteID))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            List {
                ForEach(records, id: \.noteID) { record in
                    Button {
                        openNote(record.noteID)
                    } label: {
                        WiskIOSNoteRow(record: record)
                    }
                    .buttonStyle(.plain)
                    .modifier(WiskIOSListRowChrome(record: record, scope: scope, archive: archive, trash: trash, restore: restore, togglePinned: togglePinned, duplicate: duplicate))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func listRow(_ record: NoteLibraryRecord) -> some View {
        WiskIOSNoteRow(record: record)
            .modifier(WiskIOSListRowChrome(record: record, scope: scope, archive: archive, trash: trash, restore: restore, togglePinned: togglePinned, duplicate: duplicate))
    }

    private var emptyState: some View {
        Group {
            switch libraryEmptyKind {
            case .initialSync, .initialSyncFailed:
                WiskInitialSyncPlaceholderView(kind: libraryEmptyKind, onRetry: retryInitialSync)
            case .none, .contentUnavailable:
                if searchText.isEmpty == false {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: scope.systemImage)
                    } description: {
                        Text(emptyDescription)
                    }
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
        switch scope {
        case .all: return "No Notes"
        case .archive: return "Archive Is Empty"
        case .trash: return "Trash Is Empty"
        case .untagged: return "No Untagged Notes"
        case .tag(let tag): return "No Notes in #\(tag)"
        }
    }

    private var emptyDescription: String {
        switch scope {
        case .all: return "Create a note to get started."
        case .archive: return "Archived notes will appear here."
        case .trash: return "Deleted notes will appear here."
        case .untagged, .tag: return "Try a different filter or search."
        }
    }

    private func seedIfNeeded() {
        #if DEBUG
        guard ScreenshotSeed.isActive else { return }
        let noteCount = (try? modelContext.fetchCount(FetchDescriptor<Note>())) ?? 0
        guard noteCount == 0 else { return }
        let note = Note(title: ScreenshotSeed.sampleNoteTitle, body: ScreenshotSeed.sampleNoteBody, kind: .daily, dailyDate: Date())
        note.parsedItems = ScreenshotSeed.sampleParsedItems.enumerated().map { index, item in
            ParsedNoteItem(
                rawText: item.rawText,
                title: item.title,
                itemType: item.itemType,
                status: item.status,
                confidence: item.confidence,
                sourceLineIndex: item.sourceLineIndex,
                dueHint: item.dueHint,
                project: item.project,
                people: item.people,
                bucketId: item.bucketId,
                bucketReason: item.bucketReason,
                sortOrder: index,
                note: note
            )
        }
        note.tags = [NoteTag(name: "daily", suggestedByAI: true, note: note), NoteTag(name: "action", suggestedByAI: true, note: note)]
        note.projects = [NoteProject(name: "Saffron", suggestedByAI: true, note: note), NoteProject(name: "Thorble", suggestedByAI: true, note: note)]
        modelContext.insert(note)
        NoteLibraryIndex.upsert(note, in: modelContext)
        try? modelContext.save()
        #endif
    }
}

private struct WiskIOSNoteRow: View {
    let record: NoteLibraryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(record.title.wiskNonEmptyTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if record.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                kindGlyph
                if record.hasShares {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(record.updatedAt.wiskEditedLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if record.excerpt.isEmpty == false {
                Text(record.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if record.tagNames.isEmpty == false {
                Text(record.tagNames.prefix(3).map { "#\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if record.imageAttachmentIDs.isEmpty == false {
                HStack(spacing: Spacing.sm) {
                    ForEach(record.imageAttachmentIDs, id: \.self) { attachmentID in
                        WiskIOSNoteListThumb(noteID: record.noteID, attachmentID: attachmentID)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        // Full-row tap target: without this, the Button hit area is only the
        // union of the visible subviews, so tapping empty space beside the
        // thumbnails or short text lines did nothing.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var kindGlyph: some View {
        switch record.kind {
        case .list:
            Image(systemName: "checklist")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .structured:
            Image(systemName: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .tracker:
            Image(systemName: "plus.forwardslash.minus")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .general, .daily:
            EmptyView()
        }
    }
}

private enum WiskIOSNoteThumbMetrics {
    static let width: CGFloat = 96
    static let height: CGFloat = 72
    static let cornerRadius: CGFloat = 6
    static let borderWidth: CGFloat = 0.5
    static let displayWidth: CGFloat = 96
    static let pollInterval: Duration = .milliseconds(400)
    static let resolutionTimeout: TimeInterval = 30
}

/// Note-list image thumbnail, matching the Gale iOS session-row preview:
/// a fixed 96x72 rounded card that fills in asynchronously once the
/// attachment's bytes resolve (local cache or Firebase Storage download).
private struct WiskIOSNoteListThumb: View {
    let noteID: UUID
    let attachmentID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var thumbnail: WiskAttachmentPlatformImage?
    @State private var settled = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WiskIOSNoteThumbMetrics.cornerRadius, style: .continuous)
                .fill(cardFill)
            if let thumbnail {
                platformImage(thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if settled {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: WiskIOSNoteThumbMetrics.width, height: WiskIOSNoteThumbMetrics.height)
        .clipShape(RoundedRectangle(cornerRadius: WiskIOSNoteThumbMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WiskIOSNoteThumbMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: WiskIOSNoteThumbMetrics.borderWidth)
        )
        .accessibilityLabel(accessibilityLabel)
        .task(id: attachmentID) {
            await load()
        }
    }

    private var accessibilityLabel: String {
        resolvedAttachment()?.displayName ?? "Image"
    }

    private var cardFill: Color {
        Color.wiskInputBackground
    }

    private func platformImage(_ image: WiskAttachmentPlatformImage) -> Image {
        #if os(iOS)
        return Image(uiImage: image)
        #elseif os(macOS)
        return Image(nsImage: image)
        #endif
    }

    private func resolvedAttachment() -> NoteAttachment? {
        guard let note = WiskNoteFetch.note(id: noteID, in: modelContext) else { return nil }
        return note.attachments.first {
            $0.id == attachmentID && $0.deletedAt == nil && $0.isImage
        }
    }

    private func load() async {
        guard let attachment = resolvedAttachment() else {
            thumbnail = nil
            settled = true
            return
        }
        let store = WiskAttachmentImageStore.shared
        thumbnail = nil
        settled = false
        if store.phase(for: attachment) == .failed {
            // A previous attempt this session failed; retry once per
            // appearance so transient download failures and newly-available
            // Storage recover without leaving the row pinned on fallback.
            store.retry(for: attachment)
        }
        if let image = store.displayImage(for: attachment, displayWidth: WiskIOSNoteThumbMetrics.displayWidth) {
            thumbnail = image
            settled = true
            return
        }
        // Remote attachment: the store downloads asynchronously. Poll until it
        // settles or this row scrolls away and the task is cancelled. The
        // deadline keeps a hung download from spinning on a visible row.
        let deadline = Date().addingTimeInterval(WiskIOSNoteThumbMetrics.resolutionTimeout)
        while !Task.isCancelled {
            switch store.phase(for: attachment) {
            case .loaded:
                thumbnail = store.displayImage(for: attachment, displayWidth: WiskIOSNoteThumbMetrics.displayWidth)
                settled = true
                return
            case .failed:
                settled = true
                return
            case .idle, .loading:
                break
            }
            guard Date() < deadline else {
                settled = true
                return
            }
            try? await Task.sleep(for: WiskIOSNoteThumbMetrics.pollInterval)
        }
    }
}

private struct WiskIOSListRowChrome: ViewModifier {
    let record: NoteLibraryRecord
    let scope: WiskNotesScope
    let archive: (NoteLibraryRecord) -> Void
    let trash: (NoteLibraryRecord) -> Void
    let restore: (NoteLibraryRecord) -> Void
    let togglePinned: (NoteLibraryRecord) -> Void
    let duplicate: (NoteLibraryRecord) -> Void

    func body(content: Content) -> some View {
        content
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 18))
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("wisk.notes.row.\(record.noteID.uuidString)")
            .modifier(WiskIOSNoteRowActions(
                record: record,
                scope: scope,
                archive: archive,
                trash: trash,
                restore: restore,
                togglePinned: togglePinned,
                duplicate: duplicate
            ))
    }
}

private struct WiskIOSNoteRowActions: ViewModifier {
    let record: NoteLibraryRecord
    let scope: WiskNotesScope
    let archive: (NoteLibraryRecord) -> Void
    let trash: (NoteLibraryRecord) -> Void
    let restore: (NoteLibraryRecord) -> Void
    let togglePinned: (NoteLibraryRecord) -> Void
    let duplicate: (NoteLibraryRecord) -> Void

    private var canPinOrDuplicate: Bool {
        scope != .trash && scope != .archive
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                trailingActions
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                leadingActions
            }
            .contextMenu {
                contextMenuActions
            }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if scope == .trash || scope == .archive {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                restore(record)
            }
            .tint(.accent)
            .accessibilityIdentifier("wisk.notes.restoreButton")
        } else {
            Button("Archive", systemImage: "archivebox") {
                archive(record)
            }
            .tint(.orange)
            Button("Trash", systemImage: "trash", role: .destructive) {
                trash(record)
            }
        }
    }

    @ViewBuilder
    private var leadingActions: some View {
        if canPinOrDuplicate {
            Button(record.pinned ? "Unpin" : "Pin", systemImage: record.pinned ? "pin.slash" : "pin") {
                togglePinned(record)
            }
            .tint(.accent)
            .accessibilityIdentifier("wisk.notes.pinButton")
            Button("Duplicate", systemImage: "doc.on.doc") {
                duplicate(record)
            }
            .tint(.indigo)
            .accessibilityIdentifier("wisk.notes.duplicateButton")
        }
    }

    @ViewBuilder
    private var contextMenuActions: some View {
        if canPinOrDuplicate {
            Button(record.pinned ? "Unpin Note" : "Pin Note", systemImage: record.pinned ? "pin.slash" : "pin") {
                togglePinned(record)
            }
            Button("Duplicate Note", systemImage: "doc.on.doc") {
                duplicate(record)
            }
        }
        if scope == .trash || scope == .archive {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                restore(record)
            }
        } else {
            Button("Archive", systemImage: "archivebox") {
                archive(record)
            }
            Button("Trash", systemImage: "trash", role: .destructive) {
                trash(record)
            }
        }
    }
}

struct WiskIOSNoteInfoInspector: View {
    let note: Note
    let notes: [Note]
    var foldedSourceLocations: Binding<Set<Int>>
    var onJumpToSourceRange: ((NSRange) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.accent)
                        .frame(width: 28, height: 28)
                        .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Note Info")
                            .font(.headline)
                        Text(note.title.wiskNonEmptyTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(note.updatedAt.wiskEditedLabel, systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(note.createdAt.wiskCreatedLabel, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                WiskNoteStatsView(statistics: WiskNoteStatistics.from(title: note.title, body: note.body))

                WiskNoteLinkExtrasView(
                    note: note,
                    notes: notes,
                    foldedSourceLocations: foldedSourceLocations,
                    onJumpToSourceRange: onJumpToSourceRange
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.wiskCanvasBackground)
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension String {
    var wiskNonEmptyTitle: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

private extension Date {
    var wiskEditedLabel: String {
        "Edited \(formatted(date: .abbreviated, time: .shortened))"
    }

    var wiskCreatedLabel: String {
        "Created \(formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct WiskIOSLibraryPurgeOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let progress: WiskLibraryPurgeProgress

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.4 : 0.28)
                .ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(.accent)
                        .frame(width: 220)
                } else {
                    ProgressView()
                        .tint(.accent)
                }
                Text(progress.status)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
                if progress.total > 0 {
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.xl)
            .frame(minWidth: 280)
            .wiskGlassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: Radius.glassOverlay, style: .continuous)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.status)
    }
}
#endif
