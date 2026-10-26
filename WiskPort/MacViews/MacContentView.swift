import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct MacContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Environment(SyncService.self) private var syncService
    @Environment(WiskProfileService.self) private var profileService
    @Query(sort: \NoteLibraryRecord.updatedAt, order: .reverse) private var libraryRecords: [NoteLibraryRecord]

    @AppStorage("wisk.mac.appearance") private var appearanceRawValue = WiskAppearance.light.rawValue
    @State private var sidebarSelection = MacSidebarSelection.allNotes
    @State private var selectedNoteID: UUID?
    @State private var selectedNoteIDs = Set<UUID>()
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var sortMode = MacNoteSortMode.modifiedNewest
    @State private var showingCommandPalette = false
    @State private var titleSelectionRequestNoteID: UUID?
    @State private var bucketMode = MacBucketMode.inbox
    @State private var selectedBucketItemID: UUID?
    @State private var selectedBucketID: UUID?
    @State private var selectedAdageID: UUID?
    @State private var simplenoteImportProgress: SimplenoteImportProgress?
    @State private var simplenoteImportTask: Task<Void, Never>?
    @State private var selectedNoteCache = MacSelectedNoteCache()
    @State private var pendingHiddenNoteIDs = Set<UUID>()
    @State private var liveListTitle: MacLiveListTitle?

    private var appearance: WiskAppearance {
        WiskAppearance(rawValue: appearanceRawValue) ?? .light
    }

    private var selectedNote: Note? {
        selectedNoteCache.note(selectedNoteID, in: modelContext)
    }

    var body: some View {
        mainSplit
            .preferredColorScheme(appearance.colorScheme)
            .tint(.accent)
            .frame(minWidth: 1040, minHeight: 620)
            .overlay { simplenoteImportOverlay }
            .sheet(isPresented: $showingCommandPalette) {
                commandPalette
                    .presentationBackground(.clear)
                    .presentationSizing(.fitted)
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskFocusSearch)) { _ in
                isSearchPresented = true
            }
            .toolbar { libraryToolbar }
            .modifier(MacNoteCommandNotifications(
                createNote: createNote,
                createList: createList,
                createTracker: createTracker,
                createStructuredNote: createStructuredNote,
                deleteSelectedNote: {
                    if let selectedNote { deleteNote(selectedNote) }
                },
                insertChecklistInSelectedNote: {
                    if let selectedNote { insertChecklist(in: selectedNote) }
                },
                showCommandPalette: { showingCommandPalette = true },
                importSimplenote: beginSimplenoteImportFromLocalStore,
                importSimplenoteJSON: beginSimplenoteImportFromOpenPanel,
                undoSimplenoteImport: { undoLastSimplenoteImport() },
                restoreSimplenoteDates: restoreSimplenoteDates,
                removeDuplicateSimplenoteNotes: removeDuplicateSimplenoteNotes
            ))
            .task {
                if WiskDebugSyncHarness.isActive {
                    await WiskDebugSyncHarness.prepareIfNeeded(context: modelContext, syncService: syncService)
                    NoteLibraryIndex.backfillIfNeeded(in: modelContext)
                    selectDebugSeededNoteIfNeeded()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    selectDebugSeededNoteIfNeeded()
                    return
                }
                await proEntitlement.refreshEntitlements()
                NoteLibraryIndex.backfillIfNeeded(in: modelContext)
            }
            .onAppear {
                selectDebugSeededNoteIfNeeded()
                #if DEBUG
                if ProcessInfo.processInfo.environment["WISK_REIMPORT_SIMPLENOTE"] == "1" {
                    beginSimplenoteImportFromLocalStore()
                }
                #endif
            }
            .onChange(of: libraryRecords.count) { _, _ in
                selectDebugSeededNoteIfNeeded()
            }
            .onChange(of: selectedNoteID) { _, newID in
                if liveListTitle?.noteID != newID {
                    liveListTitle = nil
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await proEntitlement.refreshEntitlements()
                    // Foregrounding must pull immediately — the 45s poll can
                    // otherwise leave a phone-pushed edit invisible for up to
                    // a minute. Rate-limited full pull heals notes whose
                    // `updatedAt` was frozen in the past.
                    await syncService.syncNow(context: modelContext, fullPull: true)
                }
            }
    }

    @ViewBuilder
    private var mainSplit: some View {
        NavigationSplitView {
            MacNotesSidebarView(
                records: libraryRecords,
                selection: $sidebarSelection
            )
            .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
        } content: {
            if sidebarSelection == .adages {
                AdagesListView(selectedAdageID: $selectedAdageID, pushesDetail: false)
            } else if sidebarSelection == .buckets {
                MacBucketQueueView(
                    mode: $bucketMode,
                    selectedItemID: $selectedBucketItemID,
                    selectedBucketID: $selectedBucketID
                )
            } else {
                MacNoteListView(
                    records: libraryRecords,
                    pendingHiddenNoteIDs: $pendingHiddenNoteIDs,
                    selectedNoteID: $selectedNoteID,
                    selectedNoteIDs: $selectedNoteIDs,
                    searchText: $searchText,
                    isSearchPresented: $isSearchPresented,
                    sidebarSelection: sidebarSelection,
                    sortMode: $sortMode,
                    includeAIFields: proEntitlement.hasProAccess,
                    liveListTitle: liveListTitle,
                    createNote: createNote,
                    deleteNote: deleteNote,
                    restoreNote: restoreNote,
                    permanentlyDeleteNote: permanentlyDeleteNote,
                    togglePinned: togglePinned,
                    duplicateNote: duplicateNote,
                    addTagToNotes: addTag,
                    deleteNotes: deleteNotes,
                    restoreNotes: restoreNotes,
                    permanentlyDeleteNotes: permanentlyDeleteNotes,
                    emptyArchivedNotes: emptyArchivedNotes
                )
            }
        } detail: {
            if sidebarSelection == .adages {
                AdageSelectionDetail(selectedAdageID: selectedAdageID)
            } else if sidebarSelection == .buckets {
                MacBucketReviewView(
                    mode: $bucketMode,
                    selectedItemID: $selectedBucketItemID,
                    selectedBucketID: $selectedBucketID,
                    selectNote: selectNoteForEditing
                )
            } else if let selectedNote {
                MacNoteEditorView(
                    note: selectedNote,
                    libraryRecords: libraryRecords,
                    searchText: searchText,
                    titleSelectionRequestNoteID: $titleSelectionRequestNoteID,
                    liveListTitle: $liveListTitle,
                    deleteNote: { deleteNote(selectedNote) },
                    restoreNote: { restoreNote(selectedNote) },
                    permanentlyDeleteNote: { permanentlyDeleteNote(selectedNote) }
                )
                .environment(\.wiskOpenNote, { id in
                    selectedNoteID = id
                    selectedNoteIDs = [id]
                    sidebarSelection = .allNotes
                })
            } else {
                MacEmptyEditorView(
                    createNote: createNote,
                    createStructuredNote: { createStructuredNote(template: NoteStructuredSections.defaultTemplate) },
                    createList: createList,
                    createTracker: createTracker
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                showingCommandPalette = true
            } label: {
                Label("Command Palette", systemImage: "command")
            }
            .help("Command Palette")
            .accessibilityIdentifier("wisk.mac.sidebar.commandPaletteButton")

            Button {
                openSettings()
            } label: {
                WiskProfileAvatarView(photoURL: profileService.photoURL, size: 22)
            }
            .help("Open Wisk settings")
            .accessibilityLabel("Open Wisk settings")
            .accessibilityIdentifier("wisk.mac.sidebar.profileButton")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Note", action: createNote)
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Structured Note") {
                    createStructuredNote(template: NoteStructuredSections.defaultTemplate)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New List", action: createList)
                    .keyboardShortcut("l", modifiers: [.command, .option, .shift])
                Button("New Tracker", action: createTracker)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("Create")
            .accessibilityIdentifier("wisk.mac.noteList.newNoteButton")
        }
    }

    @ViewBuilder
    private var simplenoteImportOverlay: some View {
        if let simplenoteImportProgress {
            MacSimplenoteImportOverlay(
                progress: simplenoteImportProgress,
                onCancel: cancelSimplenoteImport
            )
        }
    }

    private var commandPalette: MacCommandPaletteView {
        MacCommandPaletteView(
            selectedNote: selectedNote,
            createNote: createNote,
            createStructuredNote: { createStructuredNote(template: NoteStructuredSections.defaultTemplate) },
            createList: createList,
            createTracker: createTracker,
            focusSearch: {
                showingCommandPalette = false
                NotificationCenter.default.post(name: .wiskFocusSearch, object: nil)
            },
            showBuckets: {
                sidebarSelection = .buckets
                showingCommandPalette = false
            },
            showAllNotes: {
                sidebarSelection = .allNotes
                showingCommandPalette = false
            },
            insertChecklist: {
                if let selectedNote {
                    insertChecklist(in: selectedNote)
                }
                showingCommandPalette = false
            },
            toggleMarkdownPreview: {
                NotificationCenter.default.post(name: .wiskToggleMarkdownPreview, object: nil)
                showingCommandPalette = false
            },
            showAI: {
                NotificationCenter.default.post(name: .wiskShowAI, object: nil)
                showingCommandPalette = false
            },
            cleanUpNote: {
                NotificationCenter.default.post(name: .wiskCleanUpNote, object: nil)
                showingCommandPalette = false
            },
            routeNote: {
                NotificationCenter.default.post(name: .wiskRouteNote, object: nil)
                showingCommandPalette = false
            },
            showShare: {
                NotificationCenter.default.post(name: .wiskShowShare, object: nil)
                showingCommandPalette = false
            },
            importSimplenote: {
                showingCommandPalette = false
                beginSimplenoteImportFromLocalStore()
            },
            undoSimplenoteImport: {
                showingCommandPalette = false
                undoLastSimplenoteImport()
            },
            restoreSimplenoteDates: {
                showingCommandPalette = false
                restoreSimplenoteDates()
            },
            removeDuplicateSimplenoteNotes: {
                showingCommandPalette = false
                removeDuplicateSimplenoteNotes()
            },
            emptyArchivedNotes: {
                showingCommandPalette = false
                emptyArchivedNotes()
            },
            canUndoSimplenoteImport: SimplenoteNoteImportService.lastImportBatch().isEmpty == false,
            canRestoreSimplenoteDates: SimplenoteNoteImportService.mappedImportBatch().isEmpty == false,
            canRemoveDuplicateSimplenoteNotes: SimplenoteNoteImportService.duplicateImportCopies(
                in: WiskNoteFetch.allNotes(in: modelContext)
            ).isEmpty == false,
            canEmptyArchivedNotes: libraryRecords.contains { $0.deletedAt != nil },
            dismiss: { showingCommandPalette = false }
        )
    }

    private func createNote() {
        let note = Note(title: "Untitled", body: "", kind: .general)
        note.markdownEnabled = true
        note.snapshotIfNeeded(reason: "created")
        modelContext.insert(note)
        NoteLibraryIndex.upsert(note, in: modelContext)
        saveAndQueue(note)
        selectNoteForEditing(note)
    }

    private func createList() {
        let note = Note(title: "Untitled List", body: "", kind: .list)
        note.snapshotIfNeeded(reason: "created")
        modelContext.insert(note)
        NoteLibraryIndex.upsert(note, in: modelContext)
        saveAndQueue(note)
        selectNoteForEditing(note)
    }

    private func createStructuredNote(template: StructuredNoteTemplate) {
        let note = Note(
            title: NoteStructuredSections.titleForNewNote(from: template),
            body: NoteStructuredSections.body(from: template),
            kind: .structured
        )
        note.markdownEnabled = true
        note.addTagIfNeeded(template.title)
        note.snapshotIfNeeded(reason: "created")
        modelContext.insert(note)
        NoteLibraryIndex.upsert(note, in: modelContext)
        saveAndQueue(note)
        selectNoteForEditing(note)
    }

    private func createTracker() {
        let note = Note(
            title: "Untitled Tracker",
            body: NoteTrackerStore.defaultBody(),
            kind: .tracker
        )
        note.snapshotIfNeeded(reason: "created")
        modelContext.insert(note)
        NoteLibraryIndex.upsert(note, in: modelContext)
        saveAndQueue(note)
        selectNoteForEditing(note)
    }

    private func duplicateNote(_ note: Note) {
        guard note.deletedAt == nil else { return }
        let duplicate = note.duplicated()
        duplicate.snapshotIfNeeded(reason: "duplicated")
        modelContext.insert(duplicate)
        NoteLibraryIndex.upsert(duplicate, in: modelContext)
        saveAndQueue(duplicate)
        selectNoteForEditing(duplicate)
    }

    private func deleteNote(_ note: Note) {
        pendingHiddenNoteIDs.insert(note.id)
        note.deletedAt = Date()
        note.updatedAt = Date()
        note.syncStatus = .queued
        saveAndQueue(note, operation: .noteDelete, flagsOnlyIndex: true, deferSyncUntilPainted: true)
        selectedNoteIDs.remove(note.id)
        selectNearbyNote(afterChanging: note)
    }

    private func restoreNote(_ note: Note) {
        pendingHiddenNoteIDs.remove(note.id)
        note.deletedAt = nil
        note.updatedAt = Date()
        note.syncStatus = .queued
        saveAndQueue(note, flagsOnlyIndex: true, deferSyncUntilPainted: true)
        selectNoteForEditing(note)
    }

    private func permanentlyDeleteNote(_ note: Note) {
        NoteLibraryIndex.purge([note], in: modelContext)
        selectedNoteIDs.remove(note.id)
        selectNearbyNote(afterChanging: note)
    }

    private func togglePinned(_ note: Note) {
        note.pinned.toggle()
        note.updatedAt = Date()
        note.syncStatus = .queued
        saveAndQueue(note)
    }

    private func insertChecklist(in note: Note) {
        let separator = note.body.isEmpty || note.body.hasSuffix("\n") ? "" : "\n"
        note.body += separator + "- [ ] "
        note.updatedAt = Date()
        note.syncStatus = .queued
        note.snapshotIfNeeded(reason: "checklist")
        saveAndQueue(note)
    }

    private func saveAndQueue(
        _ note: Note,
        operation: BackendMutationOperation = .noteUpsert,
        flagsOnlyIndex: Bool = false,
        deferSyncUntilPainted: Bool = false
    ) {
        if flagsOnlyIndex {
            NoteLibraryIndex.updateListFlags(note, in: modelContext)
        } else {
            NoteLibraryIndex.upsert(note, in: modelContext)
        }
        syncService.enqueue(note: note, operation: operation, context: modelContext)
        Task {
            if deferSyncUntilPainted {
                await Task.yield()
            }
            await syncService.syncNow(context: modelContext)
        }
    }

    private func save() {
        try? modelContext.save()
    }

    private func selectNoteForEditing(_ note: Note) {
        selectedNoteID = note.id
        selectedNoteIDs = [note.id]
        sidebarSelection = .allNotes
    }

    private func selectDebugSeededNoteIfNeeded() {
        guard WiskDebugSyncHarness.isActive,
              selectedNoteID == nil,
              let record = libraryRecords.first(where: { $0.deletedAt == nil }),
              let note = WiskNoteFetch.note(id: record.noteID, in: modelContext)
        else { return }
        selectNoteForEditing(note)
    }

    private func selectedNotes(for ids: Set<UUID>) -> [Note] {
        WiskNoteFetch.notes(ids: ids, in: modelContext)
    }

    private func addTag(_ name: String, to noteIDs: Set<UUID>) {
        for note in selectedNotes(for: noteIDs) where note.deletedAt == nil {
            if note.addTagIfNeeded(name) {
                note.updatedAt = Date()
                note.syncStatus = .queued
                saveAndQueue(note)
            }
        }
    }

    private func deleteNotes(_ noteIDs: Set<UUID>) {
        pendingHiddenNoteIDs.formUnion(noteIDs)
        for note in selectedNotes(for: noteIDs) where note.deletedAt == nil {
            note.deletedAt = Date()
            note.updatedAt = Date()
            note.syncStatus = .queued
            saveAndQueue(note, operation: .noteDelete, flagsOnlyIndex: true, deferSyncUntilPainted: true)
        }
        selectedNoteIDs.subtract(noteIDs)
        reconcileSelectionAfterBulkChange()
    }

    private func restoreNotes(_ noteIDs: Set<UUID>) {
        pendingHiddenNoteIDs.subtract(noteIDs)
        for note in selectedNotes(for: noteIDs) where note.deletedAt != nil {
            note.deletedAt = nil
            note.updatedAt = Date()
            note.syncStatus = .queued
            saveAndQueue(note, flagsOnlyIndex: true, deferSyncUntilPainted: true)
        }
        selectedNoteIDs = noteIDs
        selectedNoteID = selectedNotes(for: noteIDs).first?.id
        sidebarSelection = .allNotes
    }

    private func permanentlyDeleteNotes(_ noteIDs: Set<UUID>) {
        NoteLibraryIndex.purge(selectedNotes(for: noteIDs), in: modelContext)
        selectedNoteIDs.subtract(noteIDs)
        reconcileSelectionAfterBulkChange()
    }

    private func reconcileSelectionAfterBulkChange() {
        let activeSelectedIDs = Set(
            libraryRecords
                .filter { selectedNoteIDs.contains($0.noteID) && $0.deletedAt == nil }
                .map(\.noteID)
        )
        selectedNoteIDs = activeSelectedIDs
        if let selectedNoteID, activeSelectedIDs.contains(selectedNoteID) {
            return
        }
        selectedNoteID = libraryRecords.first { $0.deletedAt == nil && !selectedNoteIDs.contains($0.noteID) }?.noteID
        if let selectedNoteID {
            selectedNoteIDs = [selectedNoteID]
        }
    }

    private func selectNearbyNote(afterChanging changedNote: Note) {
        guard selectedNoteID == changedNote.id else { return }
        selectedNoteID = libraryRecords.first { $0.noteID != changedNote.id && $0.deletedAt == nil }?.noteID
        if let selectedNoteID {
            selectedNoteIDs = [selectedNoteID]
        } else {
            selectedNoteIDs = []
        }
    }

    private var isSimplenoteImporting: Bool {
        simplenoteImportProgress != nil
    }

    private func beginSimplenoteImportFromLocalStore() {
        guard isSimplenoteImporting == false else { return }
        if let storeURL = SimplenoteLocalStore.defaultStoreURL() {
            confirmAndImportSimplenoteNotes(from: storeURL, sourceName: "Simplenote")
            return
        }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Couldn't find Simplenote on this Mac"
        alert.informativeText = "Export from Simplenote (File → Export Everything) and choose the notes.json file."
        alert.addButton(withTitle: "Choose JSON or ZIP…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            beginSimplenoteImportFromOpenPanel()
        }
        #endif
    }

    private func beginSimplenoteImportFromOpenPanel() {
        guard isSimplenoteImporting == false else { return }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .zip, .directory]
        panel.message = "Choose a Simplenote notes.json, notes.zip, or export folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmAndImportSimplenoteNotes(from: url, sourceName: url.lastPathComponent)
        #endif
    }

    private func confirmAndImportSimplenoteNotes(from url: URL, sourceName: String) {
        guard isSimplenoteImporting == false else { return }
        simplenoteImportProgress = SimplenoteImportProgress(
            status: "Reading notes from \(sourceName)…",
            completed: 0,
            total: 0
        )
        simplenoteImportTask = Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let drafts = try await Task.detached {
                    try SimplenoteLocalStore.loadActiveNotes(from: url)
                }.value
                try Task.checkCancellation()
                let existingNotes = WiskNoteFetch.allNotes(in: modelContext)
                let classification = SimplenoteNoteImportService.classify(drafts, existingNotes: existingNotes)
                guard classification.hasWork else {
                    simplenoteImportProgress = nil
                    if drafts.isEmpty {
                        presentSimplenoteAlert(
                            title: "No active notes found",
                            message: "Simplenote did not contain any active notes to import. Trashed notes are skipped."
                        )
                    } else {
                        presentSimplenoteAlert(
                            title: "Already imported",
                            message: "All \(drafts.count.formatted()) active notes already match Wisk."
                        )
                    }
                    return
                }

                simplenoteImportProgress = nil
                guard confirmSimplenoteImport(
                    create: classification.createCount,
                    update: classification.updateCount,
                    unchanged: classification.unchangedCount
                ) else {
                    return
                }

                await importSimplenoteDrafts(classification)
            } catch is CancellationError {
                simplenoteImportProgress = nil
            } catch {
                simplenoteImportProgress = nil
                presentSimplenoteAlert(title: "Couldn't import Simplenote notes", message: error.localizedDescription)
            }
        }
    }

    private func confirmSimplenoteImport(create: Int, update: Int, unchanged: Int) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WISK_REIMPORT_SIMPLENOTE"] == "1" {
            return true
        }
        #endif
        #if os(macOS)
        let alert = NSAlert()
        switch (create > 0, update > 0) {
        case (true, true):
            alert.messageText = "Add \(create.formatted()) new notes and update \(update.formatted()) previously imported notes?"
        case (true, false):
            alert.messageText = "Import \(create.formatted()) active notes?"
        case (false, true):
            alert.messageText = "Update \(update.formatted()) previously imported notes?"
        case (false, false):
            return false
        }
        var info = "Trashed notes will be skipped."
        if unchanged > 0 {
            info += " \(unchanged.formatted()) notes already match and will be skipped."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return false
        #endif
    }

    private func importSimplenoteDrafts(_ classification: SimplenoteNoteImportService.Classification) async {
        let total = classification.createCount + classification.updateCount
        simplenoteImportProgress = SimplenoteImportProgress(
            status: "Importing notes from Simplenote…",
            completed: 0,
            total: total
        )

        var created: [SimplenoteNoteImportService.BatchItem] = []
        var updated: [SimplenoteNoteImportService.BatchItem] = []
        var queuedNotes: [Note] = []
        let existingNotes = WiskNoteFetch.allNotes(in: modelContext)
        let notesByID = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0) })
        var completed = 0

        func publishProgress() async {
            if completed == total || completed % 25 == 0 {
                simplenoteImportProgress = SimplenoteImportProgress(
                    status: "Importing notes from Simplenote…",
                    completed: completed,
                    total: total
                )
                await Task.yield()
            }
        }

        do {
            for draft in classification.toCreate {
                try Task.checkCancellation()
                let note = SimplenoteNoteImportService.makeNote(from: draft)
                modelContext.insert(note)
                queuedNotes.append(note)
                created.append(.init(sourceID: draft.sourceID, noteID: note.id))
                completed += 1
                await publishProgress()
            }

            for item in classification.toUpdate {
                try Task.checkCancellation()
                guard let note = notesByID[item.noteID] else {
                    completed += 1
                    await publishProgress()
                    continue
                }
                let split = SimplenoteNoteImportService.splitTitleAndBody(item.draft.content)
                if note.title != split.title || note.body != split.body {
                    note.snapshotIfNeeded(reason: "simplenote-import")
                }
                if SimplenoteNoteImportService.apply(item.draft, onto: note) {
                    queuedNotes.append(note)
                    updated.append(.init(sourceID: item.draft.sourceID, noteID: note.id))
                }
                completed += 1
                await publishProgress()
            }

            try modelContext.save()
            for note in queuedNotes {
                NoteLibraryIndex.upsert(note, in: modelContext)
            }
            try? modelContext.save()
            SimplenoteNoteImportService.recordImport(created: created, updated: updated)
            syncService.enqueue(notes: queuedNotes, context: modelContext)

            simplenoteImportProgress = SimplenoteImportProgress(
                status: "Syncing imported notes…",
                completed: total,
                total: total
            )
            await syncService.syncNow(context: modelContext)

            sidebarSelection = .allNotes
            sortMode = .modifiedNewest
            if let newest = queuedNotes.max(by: { $0.updatedAt < $1.updatedAt }) {
                selectNoteForEditing(newest)
            }
            simplenoteImportProgress = nil
            presentSimplenoteImportSuccess(
                created: created.count,
                updated: updated.count,
                unchanged: classification.unchangedCount
            )
        } catch is CancellationError {
            persistPartialSimplenoteImport(created: created, updated: updated, notes: queuedNotes)
            simplenoteImportProgress = nil
        } catch {
            persistPartialSimplenoteImport(created: created, updated: updated, notes: queuedNotes)
            simplenoteImportProgress = nil
            presentSimplenoteAlert(title: "Couldn't import Simplenote notes", message: error.localizedDescription)
        }
    }

    private func persistPartialSimplenoteImport(
        created: [SimplenoteNoteImportService.BatchItem],
        updated: [SimplenoteNoteImportService.BatchItem],
        notes: [Note]
    ) {
        guard created.isEmpty == false || notes.isEmpty == false else { return }
        try? modelContext.save()
        if created.isEmpty == false {
            SimplenoteNoteImportService.recordImport(created: created, updated: updated)
        } else if updated.isEmpty == false {
            SimplenoteNoteImportService.mergeImportedMappings(updated)
        }
        guard notes.isEmpty == false else { return }
        for note in notes {
            NoteLibraryIndex.upsert(note, in: modelContext)
        }
        try? modelContext.save()
        syncService.enqueue(notes: notes, context: modelContext)
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }

    private func cancelSimplenoteImport() {
        simplenoteImportTask?.cancel()
    }

    private func undoLastSimplenoteImport(skipConfirmation: Bool = false) {
        guard isSimplenoteImporting == false else { return }
        let batch = SimplenoteNoteImportService.lastImportBatch()
        guard batch.isEmpty == false else {
            presentSimplenoteAlert(
                title: "Nothing to undo",
                message: "There is no Simplenote import batch to move to Archived."
            )
            return
        }

        #if os(macOS)
        if skipConfirmation == false {
            let alert = NSAlert()
            alert.messageText = "Undo last Simplenote import?"
            alert.informativeText = "\(batch.count.formatted()) imported notes will move to Archived. You can restore them later."
            alert.addButton(withTitle: "Undo Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        #endif

        let ids = Set(batch.map(\.noteID))
        let importedNotes = WiskNoteFetch.notes(ids: ids, in: modelContext)
        let now = Date()
        for note in importedNotes where note.deletedAt == nil {
            note.deletedAt = now
            note.updatedAt = now
            NoteLibraryIndex.upsert(note, in: modelContext)
        }
        SimplenoteNoteImportService.forgetLastImport()
        syncService.enqueue(notes: importedNotes, operation: .noteDelete, context: modelContext)
        selectedNoteIDs.subtract(ids)
        reconcileSelectionAfterBulkChange()
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }

    private func restoreSimplenoteDates() {
        guard isSimplenoteImporting == false else { return }
        let batch = SimplenoteNoteImportService.mappedImportBatch()
        guard batch.isEmpty == false else {
            presentSimplenoteAlert(
                title: "Nothing to restore",
                message: "There are no imported Simplenote notes to restore last-edited dates from."
            )
            return
        }

        guard let storeURL = SimplenoteLocalStore.defaultStoreURL() else {
            presentSimplenoteAlert(
                title: "Couldn't find Simplenote on this Mac",
                message: "Keep Simplenote installed so Wisk can read the original last-edited dates."
            )
            return
        }

        do {
            let drafts = try SimplenoteLocalStore.loadActiveNotes(from: storeURL)
            let existingNotes = WiskNoteFetch.allNotes(in: modelContext)
            let result = SimplenoteNoteImportService.reapplyDates(from: drafts, onto: existingNotes, batch: batch)
            let updatedIDs = Set(result.updatedNoteIDs)
            let updatedNotes = existingNotes.filter { updatedIDs.contains($0.id) }
            if updatedNotes.isEmpty == false {
                for note in updatedNotes {
                    NoteLibraryIndex.upsert(note, in: modelContext)
                }
                try? modelContext.save()
                syncService.enqueue(notes: updatedNotes, context: modelContext)
                sidebarSelection = .allNotes
                sortMode = .modifiedNewest
                if let newest = updatedNotes.max(by: { $0.updatedAt < $1.updatedAt }) {
                    selectNoteForEditing(newest)
                }
                Task {
                    await syncService.syncNow(context: modelContext)
                }
            }

            var message = result.updatedCount == 0
                ? "Imported notes already use their Simplenote last-edited dates."
                : "All Notes is sorted by Simplenote last-edited time."
            if result.missingNoteCount > 0 || result.missingDraftCount > 0 {
                message += " Skipped \(result.missingNoteCount.formatted()) missing notes and \(result.missingDraftCount.formatted()) notes no longer in Simplenote."
            }
            presentSimplenoteAlert(
                title: result.updatedCount == 0
                    ? "Dates already match"
                    : "Restored dates on \(result.updatedCount.formatted()) notes",
                message: message
            )
        } catch {
            presentSimplenoteAlert(title: "Couldn't restore Simplenote dates", message: error.localizedDescription)
        }
    }

    private func removeDuplicateSimplenoteNotes() {
        guard isSimplenoteImporting == false else { return }
        let extras = SimplenoteNoteImportService.duplicateImportCopies(
            in: WiskNoteFetch.allNotes(in: modelContext)
        )
        guard extras.isEmpty == false else {
            presentSimplenoteAlert(
                title: "No duplicate notes",
                message: "Wisk did not find extra Simplenote copies to move to Trash."
            )
            return
        }

        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Move \(extras.count.formatted()) duplicate notes to Trash?"
        alert.informativeText = "Each extra copy matches a note from the last Simplenote import. The imported copy stays in All Notes. You can restore the extras from Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        #endif

        simplenoteImportTask = Task { @MainActor in
            await trashDuplicateSimplenoteNotes(extras)
        }
    }

    private func trashDuplicateSimplenoteNotes(_ extras: [Note]) async {
        let total = extras.count
        simplenoteImportProgress = SimplenoteImportProgress(
            status: "Moving duplicate notes to Trash…",
            completed: 0,
            total: total,
            canCancel: false
        )

        let now = Date()
        var trashed: [Note] = []
        var completed = 0
        for note in extras where note.deletedAt == nil {
            note.deletedAt = now
            note.updatedAt = now
            NoteLibraryIndex.upsert(note, in: modelContext)
            trashed.append(note)
            completed += 1
            if completed == total || completed % 25 == 0 {
                simplenoteImportProgress = SimplenoteImportProgress(
                    status: "Moving duplicate notes to Trash…",
                    completed: completed,
                    total: total,
                    canCancel: false
                )
                await Task.yield()
            }
        }

        try? modelContext.save()
        let ids = Set(trashed.map(\.id))
        pendingHiddenNoteIDs.formUnion(ids)
        selectedNoteIDs.subtract(ids)
        reconcileSelectionAfterBulkChange()

        simplenoteImportProgress = SimplenoteImportProgress(
            status: "Syncing deleted copies…",
            completed: total,
            total: total,
            canCancel: false
        )
        syncService.enqueue(notes: trashed, operation: .noteDelete, context: modelContext)
        await syncService.syncNow(context: modelContext)
        simplenoteImportProgress = nil
        presentSimplenoteAlert(
            title: "Moved \(trashed.count.formatted()) duplicates to Trash",
            message: "Imported Simplenote copies stayed in All Notes. Restore from Trash if you still need an extra copy."
        )
    }

    private func emptyArchivedNotes() {
        guard isSimplenoteImporting == false else { return }
        let trashed = NoteLibraryIndex.trashedNotes(in: WiskNoteFetch.allNotes(in: modelContext))
        guard trashed.isEmpty == false else {
            presentSimplenoteAlert(
                title: "No archived notes",
                message: "There are no archived notes to delete permanently."
            )
            return
        }

        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Delete \(trashed.count.formatted()) archived notes permanently?"
        alert.informativeText = "This cannot be undone. Other devices keep their copies until you empty Archived there too."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        #endif

        simplenoteImportTask = Task { @MainActor in
            await purgeArchivedNotes(trashed)
        }
    }

    private func purgeArchivedNotes(_ notes: [Note]) async {
        let total = notes.count
        simplenoteImportProgress = SimplenoteImportProgress(
            status: "Deleting archived notes…",
            completed: 0,
            total: total,
            canCancel: false
        )

        var completed = 0
        for note in notes {
            NoteLibraryIndex.purgeNote(note, in: modelContext)
            completed += 1
            if completed == total || completed % 25 == 0 {
                simplenoteImportProgress = SimplenoteImportProgress(
                    status: "Deleting archived notes…",
                    completed: completed,
                    total: total,
                    canCancel: false
                )
                await Task.yield()
            }
        }

        try? modelContext.save()
        let ids = Set(notes.map(\.id))
        pendingHiddenNoteIDs.subtract(ids)
        selectedNoteIDs.subtract(ids)
        selectedNoteCache.note(nil, in: modelContext)
        reconcileSelectionAfterBulkChange()
        simplenoteImportProgress = nil
        presentSimplenoteAlert(
            title: "Deleted \(total.formatted()) archived notes",
            message: "Those notes are gone from this Mac. Empty Archived on iPhone to remove them there too."
        )
    }

    private func presentSimplenoteImportSuccess(created: Int, updated: Int, unchanged: Int) {
        #if os(macOS)
        let alert = NSAlert()
        if created > 0 && updated > 0 {
            alert.messageText = "Imported \(created.formatted()) notes"
            var info = "Updated \(updated.formatted()) previously imported notes."
            if unchanged > 0 {
                info += " \(unchanged.formatted()) already matched."
            }
            info += " Undo moves the new notes to Archived; updated notes stay. Keep Simplenote installed until you confirm a few notes look right."
            alert.informativeText = info
        } else if created > 0 {
            alert.messageText = "Imported \(created.formatted()) notes"
            if unchanged > 0 {
                alert.informativeText = "\(unchanged.formatted()) notes already matched and were skipped. Keep Simplenote installed until you confirm a few notes look right."
            } else {
                alert.informativeText = "Keep Simplenote installed until you confirm a few notes look right."
            }
        } else {
            alert.messageText = "Updated \(updated.formatted()) notes"
            if unchanged > 0 {
                alert.informativeText = "\(unchanged.formatted()) notes already matched and were skipped. Keep Simplenote installed until you confirm a few notes look right."
            } else {
                alert.informativeText = "Keep Simplenote installed until you confirm a few notes look right."
            }
        }
        alert.addButton(withTitle: "OK")
        if created > 0 {
            alert.addButton(withTitle: "Undo Import")
            if alert.runModal() == .alertSecondButtonReturn {
                undoLastSimplenoteImport(skipConfirmation: true)
            }
        } else {
            alert.runModal()
        }
        #endif
    }

    private func presentSimplenoteAlert(title: String, message: String) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }
}

private struct MacNoteCommandNotifications: ViewModifier {
    let createNote: () -> Void
    let createList: () -> Void
    let createTracker: () -> Void
    let createStructuredNote: (StructuredNoteTemplate) -> Void
    let deleteSelectedNote: () -> Void
    let insertChecklistInSelectedNote: () -> Void
    let showCommandPalette: () -> Void
    let importSimplenote: () -> Void
    let importSimplenoteJSON: () -> Void
    let undoSimplenoteImport: () -> Void
    let restoreSimplenoteDates: () -> Void
    let removeDuplicateSimplenoteNotes: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .wiskNewNote)) { _ in
                createNote()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskNewList)) { _ in
                createList()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskNewTracker)) { _ in
                createTracker()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskNewStructuredNote)) { notification in
                let template = notification.object as? StructuredNoteTemplate ?? NoteStructuredSections.defaultTemplate
                createStructuredNote(template)
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskDeleteNote)) { _ in
                deleteSelectedNote()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskInsertChecklist)) { _ in
                insertChecklistInSelectedNote()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskShowCommandPalette)) { _ in
                showCommandPalette()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskImportSimplenote)) { _ in
                importSimplenote()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskImportSimplenoteJSON)) { _ in
                importSimplenoteJSON()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskUndoSimplenoteImport)) { _ in
                undoSimplenoteImport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskRestoreSimplenoteDates)) { _ in
                restoreSimplenoteDates()
            }
            .onReceive(NotificationCenter.default.publisher(for: .wiskRemoveDuplicateSimplenoteNotes)) { _ in
                removeDuplicateSimplenoteNotes()
            }
    }
}

private struct SimplenoteImportProgress: Equatable {
    var status: String
    var completed: Int
    var total: Int
    var canCancel: Bool = true
}

private final class MacSelectedNoteCache {
    private var id: UUID?
    private var note: Note?

    func note(_ id: UUID?, in context: ModelContext) -> Note? {
        guard let id else {
            self.id = nil
            self.note = nil
            return nil
        }
        if id == self.id, let note, note.isDeleted == false {
            return note
        }
        self.id = id
        self.note = WiskNoteFetch.note(id: id, in: context)
        return self.note
    }
}

#if os(macOS)
private struct MacSimplenoteImportOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let progress: SimplenoteImportProgress
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(reduceTransparency ? 0.4 : (reduceMotion ? 0.22 : 0.32))
                .ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(.accent)
                        .frame(width: 220)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.accent)
                }
                Text(progress.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.wiskPrimaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
                if progress.total > 0 {
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                }
                if progress.canCancel {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
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
