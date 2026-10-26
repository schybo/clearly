import SwiftData
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import PDFKit
#if os(iOS)
import PencilKit
import PhotosUI
import UIKit
import VisionKit
#elseif os(macOS)
import AppKit
#endif

struct NoteEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.wiskOpenNote) private var openNote
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Environment(NoteParsingService.self) private var parsingService
    @Environment(BackgroundNoteOrganizer.self) private var organizer
    @Environment(SyncService.self) private var syncService
    @Environment(WiskAttachmentService.self) private var attachmentService
    @Environment(WiskFontManager.self) private var fontManager
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.dismiss) private var dismissEditor
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var activeBuckets: [NoteBucket]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]

    @Bindable var note: Note
    @State private var showingPreview = false
    @State private var statusMessage: String?
    @State private var isRouting = false
    @State private var routeSettings = NoteRouteSettings.shared
    @State private var shareEmail = ""
    @State private var publishSlug = ""
    @State private var showingProUpgrade = false
    @State private var showingNoteInfo = false
    @State private var showingNoteExtras = false
    @State private var showingListExtras = false
    @State private var showingFormattingOverlay = false
    @State private var showingListStatusEditor = false
    @State private var listItemDraft = ""
    @State private var trackerCounterDraft = ""
    @State private var trackerMemoDraft = ""
    @State private var trackerUnitDraft = ""
    @State private var trackerQuickAddsDraft = ""
    @State private var structuredSectionDraft = ""
    @State private var structuredTemplateTitle = ""
    @State private var structuredQuickAddDrafts: [String: String] = [:]
    @State private var structuredTemplates = NoteStructuredSections.allTemplates()
    @State private var pendingStructuredTemplate: StructuredNoteTemplate?
    @State private var showingStructuredTemplateConfirmation = false
    @State private var showingSaveStructuredTemplateAlert = false
    @State private var suppressedBodyAutosaveValue: String?
    @State private var suppressNextMarkdownAutosave = false
    @State private var editorAutosave = WiskEditorAutosave()
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftNoteID: UUID?
    @State private var needsCommit = false
    @State private var autosaveTarget: Note?
    @State private var bodySelection: TextSelection?
    @State private var richBodySelection: Range<String.Index>?
    @State private var jumpToSourceRange: NSRange?
    @State private var wikiQuery: String?
    @State private var foldedSourceLocations: Set<Int> = []
    @State private var foldSessionNoteID: UUID?
    @State private var attachmentDetails: NoteAttachment?
    @AppStorage(WiskEditorDefaults.showMarkdownSyntaxKey) private var showMarkdownSyntax = false
    #if os(iOS)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var showingSketchSheet = false
    @State private var showingDocumentScanner = false
    @State private var showingInterchangeImporter = false
    @State private var exportedURLs: [URL] = []
    @State private var pendingInterchangeImport: PendingInterchangeImport?
    @State private var showingPhotoPicker = false
    @State private var showingTypographySheet = false
    @State private var showingReviewLayerSheet = false
    @State private var showingSharingSheet = false
    @State private var showingExportOptionsSheet = false
    #endif
    @State private var isBodyEditorFocused = false
    @State private var bodyFocusRequestID: UUID?
    @FocusState private var titleFocused: Bool
    @FocusState private var listItemFocused: Bool
    @State private var autoFocusedTitleNoteID: UUID?

    #if os(iOS)
    private struct PendingInterchangeImport {
        let result: WiskNoteInterchange.ImportResult
        let suggestedTitle: String
    }
    #endif

    var body: some View {
        applyEditorPresentation(
            to: applyEditorDraftAutosave(
                to: applyEditorNavigation(to: editorSurfaceWithImportConfirmation)
            )
        )
    }

    private func applyEditorNavigation<Content: View>(to view: Content) -> some View {
        applyNoteInfoPresentation(
            to: view
                .navigationTitle(displayedTitle.isEmpty ? defaultNavigationTitle : displayedTitle)
                .wiskInlineNavigationTitle()
                .modifier(WiskEditorToolbarRole())
                .modifier(WiskNoteEditorToolbarButtons(
                    showsPreviewToggle: note.kind != .list && note.kind != .tracker && note.kind != .structured,
                    isPreviewing: showingPreview,
                    onTogglePreview: {
                        showingFormattingOverlay = false
                        showingPreview.toggle()
                    },
                    onShowInfo: { showingNoteInfo.toggle() }
                ))
        )
    }

    @ViewBuilder
    private func applyNoteInfoPresentation<Content: View>(to view: Content) -> some View {
        #if os(iOS)
        view.sheet(isPresented: $showingNoteInfo) {
            NavigationStack {
                noteInfoInspector
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingNoteInfo = false }
                        }
                    }
            }
            .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
        }
        #else
        view
        #endif
    }

    #if os(iOS)
    private var noteInfoInspector: some View {
        WiskIOSNoteInfoInspector(
            note: note,
            notes: notes,
            foldedSourceLocations: $foldedSourceLocations,
            onJumpToSourceRange: { range in
                jumpToSourceRange = range
                showingNoteInfo = false
            }
        )
    }
    #endif

    private func applyEditorDraftAutosave<Content: View>(to view: Content) -> some View {
        view
            .onChange(of: draftTitle) { _, newTitle in
                guard WiskEditorLifecycle.shouldScheduleIdlePersist(
                    draftNoteID: draftNoteID,
                    boundNoteID: note.id,
                    draftValue: newTitle,
                    noteValue: note.title
                ) else { return }
                editorAutosave.schedule { persistIdleDraft() }
            }
            .onChange(of: draftBody) { _, newBody in
                if suppressedBodyAutosaveValue == newBody {
                    suppressedBodyAutosaveValue = nil
                    return
                }
                guard WiskEditorLifecycle.shouldScheduleIdlePersist(
                    draftNoteID: draftNoteID,
                    boundNoteID: note.id,
                    draftValue: newBody,
                    noteValue: note.body
                ) else { return }
                editorAutosave.schedule { persistIdleDraft() }
            }
            .onChange(of: WiskEditorNoteIdentity(id: note.id, markdownEnabled: note.markdownEnabled)) { old, new in
                if old.id != new.id {
                    let leavingNote = autosaveTarget
                    let captured = leavingDraft(from: leavingNote)
                    persistLeavingNote(leavingNote, captured: captured)
                    foldedSourceLocations = []
                    autosaveTarget = note
                    richBodySelection = nil
                    bodySelection = nil
                    loadEditorDraftFromNote()
                    return
                }
                if suppressNextMarkdownAutosave {
                    suppressNextMarkdownAutosave = false
                    return
                }
                saveAndQueueNote()
            }
            .onChange(of: note.body) { _, newBody in
                guard editorAutosave.hasPending == false, newBody != draftBody else { return }
                draftBody = newBody
            }
            .onChange(of: note.title) { _, newTitle in
                guard editorAutosave.hasPending == false, newTitle != draftTitle else { return }
                draftTitle = newTitle
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background || newPhase == .inactive {
                    commitEditorDraft(to: autosaveTarget ?? note)
                }
            }
    }

    private func applyEditorPresentation<Content: View>(to view: Content) -> some View {
        applyEditorSheets(to: applyEditorLifecycle(to: applyEditorImportSurfaces(to: applyEditorActionSheets(to: view))))
    }

    /// Sheets opened from the Bear ⋯ action menu on iOS.
    @ViewBuilder
    private func applyEditorActionSheets<Content: View>(to view: Content) -> some View {
        #if os(iOS)
        view
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 20,
                matching: .images
            )
            .sheet(isPresented: $showingTypographySheet) {
                NavigationStack {
                    WiskBuiltInFontChooser(
                        selected: fontManager.selection.builtInFont,
                        accessibilityIdentifier: "wisk.note.typographyChooser"
                    ) { family in
                        fontManager.selectBuiltIn(family)
                    }
                    .navigationTitle("Typography")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingTypographySheet = false }
                        }
                    }
                }
                .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
            }
            .sheet(isPresented: $showingReviewLayerSheet) {
                NavigationStack {
                    ScrollView {
                        parsedItemsCard
                            .padding(Spacing.lg)
                    }
                    .background(Color.wiskCanvasBackground)
                    .navigationTitle("Review Layer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingReviewLayerSheet = false }
                        }
                    }
                }
                .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
            }
            .sheet(isPresented: $showingSharingSheet) {
                NavigationStack {
                    ScrollView {
                        sharingCard
                            .padding(Spacing.lg)
                    }
                    .background(Color.wiskCanvasBackground)
                    .navigationTitle("Sharing")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSharingSheet = false }
                        }
                    }
                }
                .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
            }
            .sheet(isPresented: $showingExportOptionsSheet) {
                NavigationStack {
                    WiskNoteExportOptionsList(
                        onImport: {
                            showingExportOptionsSheet = false
                            showingInterchangeImporter = true
                        },
                        onExport: { format in
                            showingExportOptionsSheet = false
                            exportNote(format)
                        }
                    )
                    .navigationTitle("Export")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingExportOptionsSheet = false }
                        }
                    }
                }
                .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
            }
        #else
        view
        #endif
    }

    @ViewBuilder
    private func applyEditorImportSurfaces<Content: View>(to view: Content) -> some View {
        #if os(iOS)
        view
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                showingFormattingOverlay = false
                Task {
                    statusMessage = items.count == 1 ? "Adding image..." : "Adding \(items.count) images..."
                    for item in items {
                        await insertPhotoAttachment(from: item)
                    }
                    selectedPhotoItems = []
                    if attachmentService.lastErrorMessage == nil {
                        statusMessage = nil
                    }
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: WiskAttachmentImportTypes.fileTypes) { result in
                handleFileImport(result)
            }
            .fileImporter(
                isPresented: $showingInterchangeImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "md") ?? .plainText,
                    .plainText,
                    UTType(filenameExtension: "textbundle") ?? .package,
                ]
            ) { result in
                handleInterchangeImport(result)
            }
            .sheet(isPresented: $showingSketchSheet) {
                WiskSketchSheet { data in
                    insertAttachment(from: data, altText: "Sketch")
                }
            }
            .sheet(isPresented: $showingDocumentScanner) {
                WiskDocumentScanner { pages in
                    insertScannedDocument(pages)
                }
            }
            .sheet(isPresented: exportActivityPresented) {
                WiskActivityView(items: exportedURLs)
            }
        #else
        view
        #endif
    }

    private func applyEditorLifecycle<Content: View>(to view: Content) -> some View {
        view
            .onAppear {
                autosaveTarget = note
                loadEditorDraftFromNote()
                if foldSessionNoteID != note.id {
                    foldedSourceLocations = []
                    foldSessionNoteID = note.id
                }
                consumePendingJump()
                syncTrackerDrafts()
                refreshStructuredTemplates()
                focusTitleForBlankNote()
            }
            .onDisappear {
                commitEditorDraft(to: autosaveTarget ?? note)
            }
            .task(id: attachmentHydrationKey) {
                for attachment in note.attachments
                where attachment.deletedAt == nil
                    && attachment.localCachePath == nil
                    && attachment.storagePath != nil {
                    _ = await attachmentService.data(for: attachment)
                }
            }
    }

    private func applyEditorSheets<Content: View>(to view: Content) -> some View {
        view
            .confirmationDialog(
                "Replace sections with this template?",
                isPresented: $showingStructuredTemplateConfirmation,
                titleVisibility: .visible,
                presenting: pendingStructuredTemplate
            ) { template in
                Button("Replace with \(template.title)", role: .destructive) {
                    applyStructuredTemplate(template, replacingContent: true)
                }
                Button("Cancel", role: .cancel) {
                    pendingStructuredTemplate = nil
                }
            } message: { _ in
                Text("This keeps the note title and replaces the current structured sections.")
            }
            .alert("Save Structure as Template", isPresented: $showingSaveStructuredTemplateAlert) {
                TextField("Template name", text: $structuredTemplateTitle)
                Button("Save") {
                    saveStructuredTemplate()
                }
                .disabled(structuredTemplateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Wisk will save the section names, order, and default collapse state for future notes.")
            }
            .sheet(isPresented: $showingProUpgrade) {
                ProUpgradeView(
                    title: "Unlock Wisk AI",
                    message: "Wisk Pro organizes notes, extracts tasks and reminders, builds your review layer, and keeps AI-created structure in sync."
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingListStatusEditor) {
                ChecklistStatusEditorSheet(list: NoteChecklist.list(from: note.body)) { updatedList in
                    note.body = NoteChecklist.body(from: updatedList)
                    saveAndSchedule(fromDraft: false)
                }
            }
    }

    private var editorSurface: some View {
        #if os(iOS)
        editorSurfaceCore
            .modifier(WiskIOSNoteEditorChromeModifier(
                title: displayedTitle,
                isShowingInfo: $showingNoteInfo,
                isBodyEditorFocused: isBodyEditorFocused,
                showsPreviewToggle: note.kind != .list && note.kind != .tracker && note.kind != .structured,
                isPreviewing: showingPreview,
                hasProAccess: proEntitlement.hasProAccess,
                canCleanUp: NoteCleanup.supports(note.kind) && note.deletedAt == nil,
                canRoute: canRoute,
                isRouting: isRouting,
                routeHelp: routeHelp,
                statusMessage: bearStatusMessage,
                applyFormatting: applyFormatting,
                onTogglePreview: { showingPreview.toggle() },
                onOrganize: { organizeNow() },
                onUnlockAI: { showingProUpgrade = true },
                onCleanUp: { cleanUpNow() },
                onRoute: { routeNow() },
                onFind: { NotificationCenter.default.post(name: .wiskFindInNote, object: nil) },
                onTypography: { showingTypographySheet = true },
                onAddPhoto: { showingPhotoPicker = true },
                onAddFiles: { showingFileImporter = true },
                onScan: { showingDocumentScanner = true },
                onSketch: { showingSketchSheet = true },
                onExport: { showingExportOptionsSheet = true },
                onCopyAs: { copyAs($0) },
                onShowReviewLayer: { showingReviewLayerSheet = true },
                onShowSharing: { showingSharingSheet = true },
                onDelete: { deleteNoteFromEditor() }
            ))
        #else
        editorSurfaceCore
        #endif
    }

    private var editorSurfaceCore: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: note.kind == .list ? Spacing.md : Spacing.lg) {
                    if note.kind == .list {
                        noteDateSummary
                        listEditorCard
                        if showingListExtras {
                            sharingCard
                        }
                    } else if note.kind == .structured {
                        titleField
                        noteDateSummary
                        structuredEditorCard
                        organizationStatus
                        parsingStatus
                        noteSecondaryAffordance
                        if showingNoteExtras {
                            parsedItemsCard
                            sharingCard
                        }
                    } else if note.kind == .tracker {
                        titleField
                        noteDateSummary
                        trackerEditorCard
                        sharingCard
                    } else {
                        titleField
                        noteDateSummary
                        editorCard
                        organizationStatus
                        parsingStatus
                        noteSecondaryAffordance
                        if showingNoteExtras {
                            parsedItemsCard
                            sharingCard
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, note.kind == .list ? Spacing.sm : Spacing.lg)
                .wiskContentBottomPadding()
                .readableWidth()
            }
            .wiskIgnoresKeyboardSafeArea()

            if showsFormattingOverlay {
                GlassEffectContainer {
                    formattingOverlay
                }
                .zIndex(10)
            }
        }
        .wiskEditorCanvas()
    }

    @ViewBuilder
    private var editorSurfaceWithImportConfirmation: some View {
        #if os(iOS)
        editorSurface
            .confirmationDialog(
                "Replace this note with the import?",
                isPresented: Binding(
                    get: { pendingInterchangeImport != nil },
                    set: { if !$0 { pendingInterchangeImport = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingInterchangeImport
            ) { pending in
                Button("Replace and Import", role: .destructive) {
                    pendingInterchangeImport = nil
                    applyInterchangeImport(pending.result, suggestedTitle: pending.suggestedTitle)
                }
                Button("Cancel", role: .cancel) {
                    pendingInterchangeImport = nil
                }
            } message: { _ in
                Text("The current note body will be replaced. Its existing attachments remain available until you remove them.")
            }
            .modifier(WiskNoteEditorChrome(
                noteID: note.id,
                attachmentDetails: $attachmentDetails,
                onJump: consumePendingJump,
                onSaveAttachment: { saveAndQueueNote() }
            ))
        #else
        editorSurface
            .modifier(WiskNoteEditorChrome(
                noteID: note.id,
                attachmentDetails: $attachmentDetails,
                onJump: consumePendingJump,
                onSaveAttachment: { saveAndQueueNote() }
            ))
        #endif
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

    private var displayedTitle: String {
        WiskEditorLifecycle.displayedTitle(
            draftNoteID: draftNoteID,
            draftTitle: draftTitle,
            noteID: note.id,
            noteTitle: note.title
        )
    }

    private var displayedBody: String {
        WiskEditorLifecycle.displayedBody(
            draftNoteID: draftNoteID,
            draftBody: draftBody,
            noteID: note.id,
            noteBody: note.body
        )
    }

    private var draftTitleBinding: Binding<String> {
        Binding(
            get: { displayedTitle },
            set: { newValue in
                guard draftNoteID == note.id else { return }
                draftTitle = newValue
            }
        )
    }

    private var draftBodyBinding: Binding<String> {
        Binding(
            get: { displayedBody },
            set: { newValue in
                guard draftNoteID == note.id else { return }
                draftBody = newValue
            }
        )
    }

    private var selectedRangeBinding: Binding<Range<String.Index>?> {
        Binding(
            get: {
                WiskEditorLifecycle.displayedSelection(
                    draftNoteID: draftNoteID,
                    draftSelection: richBodySelection,
                    noteID: note.id
                )
            },
            set: { newValue in
                guard draftNoteID == note.id else { return }
                richBodySelection = newValue
            }
        )
    }

    private var titleField: some View {
        #if os(iOS)
        TextField("Title", text: draftTitleBinding)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(Color.wiskPrimaryText)
            .focused($titleFocused)
            .submitLabel(.next)
            .onSubmit {
                // Bear behavior: Return in the title moves the caret to the
                // body editor instead of dropping the keyboard.
                bodyFocusRequestID = UUID()
            }
            .accessibilityIdentifier("wisk.note.titleField")
        #else
        TextField("Title", text: draftTitleBinding)
            .font(.title.bold())
            .foregroundStyle(Color.wiskPrimaryText)
            .padding(Spacing.lg)
            .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.card))
            .focused($titleFocused)
            .accessibilityIdentifier("wisk.note.titleField")
        #endif
    }

    #if os(iOS)
    private var exportActivityPresented: Binding<Bool> {
        Binding(
            get: { !exportedURLs.isEmpty },
            set: { isPresented in
                if !isPresented {
                    exportedURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                    exportedURLs = []
                }
            }
        )
    }
    #endif

    private var defaultNavigationTitle: String {
        switch note.kind {
        case .list: return "List"
        case .structured: return "Structured Note"
        case .tracker: return "Tracker"
        default: return "Note"
        }
    }

    @ViewBuilder
    private var noteDateSummary: some View {
        #if os(iOS)
        // Date metadata lives in the Note Info sheet on the Bear-style
        // canvas; the canvas stays full-bleed.
        EmptyView()
        #else
        NoteDateSummary(
            note: note,
            notes: notes,
            foldedSourceLocations: $foldedSourceLocations
        ) { range in
            jumpToSourceRange = range
        }
        #endif
    }

    private var editorCard: some View {
        #if os(iOS)
        bearEditorBody
        #else
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Label(showingPreview ? "Markdown preview" : "Editor", systemImage: showingPreview ? "doc.richtext" : "text.alignleft")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(Color.wiskPrimaryText)
                Spacer()
                Toggle("Markdown", isOn: $note.markdownEnabled)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("wisk.note.markdownToggle")
                if !showingPreview {
                    WiskFormattingToggleButton(isExpanded: $showingFormattingOverlay)
                }
                Button(proEntitlement.hasProAccess ? "Organize now" : "Unlock AI") {
                    if proEntitlement.hasProAccess {
                        organizeNow()
                    } else {
                        showingProUpgrade = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wisk.note.organizeButton")
                Button("Clean Up") {
                    cleanUpNow()
                }
                .buttonStyle(.bordered)
                .disabled(!NoteCleanup.supports(note.kind) || note.deletedAt != nil)
                .accessibilityIdentifier("wisk.note.cleanUpButton")
                Button(isRouting ? "Routing…" : "Route") {
                    routeNow()
                }
                .buttonStyle(.bordered)
                .disabled(isRouting || note.deletedAt != nil || canRoute == false)
                .help(routeHelp)
                .accessibilityIdentifier("wisk.note.routeButton")
                .accessibilityHint(routeHelp)
            }

            if showingPreview && note.markdownEnabled {
                MarkdownPreview(text: displayedBody, attachments: note.attachments)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
            } else if showingPreview {
                Text("Turn on Markdown for this note to render a preview. Edit mode always keeps the rich editor.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                    .foregroundStyle(Color.wiskSecondaryText)
            } else {
                WiskNextComposer(
                    markdownText: draftBodyBinding,
                    selectedMarkdownRange: selectedRangeBinding,
                    attachments: note.attachments,
                    fontSelection: fontManager.selection,
                    baseFontSize: CGFloat(WiskEditorDefaults.defaultFontSize),
                    minHeight: 320,
                    showSourceMarkers: showMarkdownSyntax,
                    wikiLinkTitles: wikiLinkTitles,
                    jumpToSourceRange: jumpToSourceRange,
                    foldedSourceLocations: $foldedSourceLocations,
                    documentIdentity: note.id,
                    accessibilityIdentifier: "wisk.note.bodyEditor",
                    onOpenWikiLink: openWikiLink,
                    onJumpHandled: { jumpToSourceRange = nil },
                    onWikiQueryChanged: { wikiQuery = $0 },
                    onEditAttachmentDetails: { attachmentDetails = $0 }
                )
                    .frame(minHeight: 320)
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
            }
        }
        .padding(Spacing.lg)
        .cardStyle()
        #endif
    }

    /// Full-bleed Bear canvas body: the editor or preview with no card
    /// chrome, no header row, and editor focus tracking for the keyboard bar.
    @ViewBuilder
    private var bearEditorBody: some View {
        if showingPreview && note.markdownEnabled {
            MarkdownPreview(text: displayedBody, attachments: note.attachments)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if showingPreview {
            Text("Turn on Markdown for this note to render a preview. Edit mode always keeps the rich editor.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color.wiskSecondaryText)
        } else {
            // minHeight keeps the UITextView from collapsing to zero height
            // inside the outer ScrollView (the Bear canvas has no card chrome
            // to give it a frame).
            WiskNextComposer(
                markdownText: draftBodyBinding,
                selectedMarkdownRange: selectedRangeBinding,
                attachments: note.attachments,
                fontSelection: fontManager.selection,
                baseFontSize: CGFloat(WiskEditorDefaults.defaultFontSize),
                minHeight: 320,
                showSourceMarkers: showMarkdownSyntax,
                wikiLinkTitles: wikiLinkTitles,
                jumpToSourceRange: jumpToSourceRange,
                foldedSourceLocations: $foldedSourceLocations,
                documentIdentity: note.id,
                accessibilityIdentifier: "wisk.note.bodyEditor",
                onFocusChange: { isBodyEditorFocused = $0 },
                onOpenWikiLink: openWikiLink,
                onJumpHandled: { jumpToSourceRange = nil },
                onWikiQueryChanged: { wikiQuery = $0 },
                onEditAttachmentDetails: { attachmentDetails = $0 },
                bodyFocusRequestID: bodyFocusRequestID,
                onBodyFocusHandled: { bodyFocusRequestID = nil }
            )
                .frame(minHeight: 320)
        }
    }

    private var showsFormattingOverlay: Bool {
        #if os(iOS)
        // Formatting lives in the persistent keyboard bar on iOS.
        false
        #else
        showingFormattingOverlay
            && !showingPreview
            && (note.kind == .general || note.kind == .daily)
        #endif
    }

    private var formattingOverlay: some View {
        WiskFormattingBar(applyFormatting: applyFormatting, accessoryPlacement: .leading) {
            #if os(iOS)
            Button {
                NotificationCenter.default.post(name: .wiskUndoMarkdownEditor, object: nil)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.formatting.undo")

            Button {
                NotificationCenter.default.post(name: .wiskRedoMarkdownEditor, object: nil)
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.formatting.redo")

            Button {
                NotificationCenter.default.post(name: .wiskFindInNote, object: nil)
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.formatting.find")

            if UIDevice.current.userInterfaceIdiom == .pad {
                Button {
                    showingFormattingOverlay = false
                    showingSketchSheet = true
                } label: {
                    Label("Sketch", systemImage: "scribble")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("wisk.note.sketchButton")
            }

            Button {
                pasteImageFromClipboard()
            } label: {
                Label("Paste image", systemImage: "doc.on.clipboard")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.note.pasteImageButton")

            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 20, matching: .images) {
                Label("Insert photo", systemImage: "photo")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.note.insertPhotoButton")

            Button {
                showingFormattingOverlay = false
                showingFileImporter = true
            } label: {
                Label("Insert file", systemImage: "paperclip")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.note.insertFileButton")

            if VNDocumentCameraViewController.isSupported {
                Button {
                    showingFormattingOverlay = false
                    showingDocumentScanner = true
                } label: {
                    Label("Scan document", systemImage: "doc.viewfinder")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("wisk.note.scanDocumentButton")
            }

            Menu {
                ForEach(WiskCopyAsFormat.allCases) { format in
                    Button(format.title) {
                        copyAs(format)
                    }
                }
            } label: {
                Label("Copy As", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.note.copyAsMenu")

            Menu {
                Button("Import Markdown or TextBundle") {
                    showingFormattingOverlay = false
                    showingInterchangeImporter = true
                }
                Divider()
                ForEach(WiskExportFormat.allCases) { format in
                    Button("Export \(format.title)") {
                        exportNote(format)
                    }
                }
            } label: {
                Label("Import or Export", systemImage: "square.and.arrow.up.on.square")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("wisk.note.interchangeMenu")
            #endif
        }
        .padding(Spacing.sm)
        .wiskGlassEffect(.regular.interactive(), in: Capsule())
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var structuredEditorCard: some View {
        let structuredNote = NoteStructuredSections.structuredNote(from: note.body)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Label("Structured note", systemImage: "rectangle.stack")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(Color.wiskPrimaryText)
                Spacer()
                Text(NoteStructuredSections.summary(for: note.body))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.wiskSecondaryText)
                structuredOptionsMenu
            }

            Text("Capture into sections without losing the markdown body underneath.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            if structuredNote.sections.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.accent)
                    Text("No sections yet")
                        .font(.headline)
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text("Apply a template or add your first section.")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                    Button("Apply Daily Workflow") {
                        applyStructuredTemplate(NoteStructuredSections.defaultTemplate, replacingContent: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("wisk.structured.emptyApplyDailyButton")
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
            } else {
                VStack(spacing: Spacing.md) {
                    ForEach(structuredNote.sections) { section in
                        StructuredSectionCard(
                            section: section,
                            attachments: note.attachments,
                            title: Binding(
                                get: { sectionTitle(for: section.id) },
                                set: { updateStructuredSectionTitle(section.id, title: $0) }
                            ),
                            bodyText: Binding(
                                get: { sectionBody(for: section.id) },
                                set: { updateStructuredSectionBody(section.id, body: $0) }
                            ),
                            quickAddDraft: Binding(
                                get: { structuredQuickAddDrafts[section.id, default: ""] },
                                set: { structuredQuickAddDrafts[section.id] = $0 }
                            ),
                            toggleCollapsed: { toggleStructuredSection(section.id) },
                            addQuickItem: { addStructuredQuickItem(to: section.id) },
                            setMode: { mode in setStructuredSectionMode(mode, sectionID: section.id) },
                            moveUp: { moveStructuredSection(section.id, direction: .up) },
                            moveDown: { moveStructuredSection(section.id, direction: .down) },
                            delete: { deleteStructuredSection(section.id) },
                            toggleChecklistItem: { index in toggleStructuredChecklistItem(at: index, sectionID: section.id) },
                            deleteChecklistItem: { index in deleteStructuredChecklistItem(at: index, sectionID: section.id) },
                            canMoveUp: structuredNote.sections.first?.id != section.id,
                            canMoveDown: structuredNote.sections.last?.id != section.id,
                            canDelete: structuredNote.sections.count > 1
                        )
                    }
                }
            }

            HStack(spacing: Spacing.sm) {
                TextField("Add section", text: $structuredSectionDraft)
                    .wiskPlainTextInput()
                    .onSubmit(addStructuredSection)
                    .accessibilityIdentifier("wisk.structured.addSectionField")
                Button {
                    addStructuredSection()
                } label: {
                    Label("Add Section", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(structuredSectionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("wisk.structured.addSectionButton")
            }
            .padding(Spacing.md)
            .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
        }
        .padding(Spacing.lg)
        .cardStyle()
    }

    private var structuredOptionsMenu: some View {
        Menu {
            Menu("Apply template") {
                ForEach(structuredTemplates) { template in
                    Button {
                        requestStructuredTemplate(template)
                    } label: {
                        Label(template.title, systemImage: template.isUserDefined ? "person.crop.square" : "rectangle.stack.badge.plus")
                    }
                }
            }
            Button("Save current structure as template") {
                structuredTemplateTitle = note.title.nilIfEmpty ?? "Custom Template"
                showingSaveStructuredTemplateAlert = true
            }
            if !NoteStructuredSections.loadUserTemplates().isEmpty {
                Menu("Delete saved template") {
                    ForEach(NoteStructuredSections.loadUserTemplates()) { template in
                        Button(template.title, role: .destructive) {
                            NoteStructuredSections.deleteUserTemplate(id: template.id)
                            refreshStructuredTemplates()
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.wiskSecondaryText)
        .accessibilityIdentifier("wisk.structured.optionsButton")
        .accessibilityLabel("Structured note options")
    }

    private var listEditorCard: some View {
        let checklist = NoteChecklist.list(from: note.body)
        let hasCompletedItems = checklist.items.contains(where: \.isCompleted)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Label("List", systemImage: "checklist")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(Color.wiskPrimaryText)
                Spacer()
                Text(NoteChecklist.progressSummary(for: note.body))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.wiskSecondaryText)
                if hasCompletedItems {
                    Button("Clear completed", action: clearCompletedListItems)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.accent)
                        .accessibilityIdentifier("wisk.list.clearCompletedButton")
                }
                listOptionsMenu(checklist: checklist)
            }

            listSecondaryAffordance

            if checklist.items.isEmpty {
                Text("Add the first item to start this list.")
                    .foregroundStyle(Color.wiskSecondaryText)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(Array(checklist.items.enumerated()), id: \.offset) { index, item in
                        ChecklistItemRow(
                            item: item,
                            checklist: checklist,
                            toggle: { toggleListItem(at: index) },
                            setStatus: { statusID in setListItemStatus(statusID, at: index) },
                            editStatuses: { showingListStatusEditor = true },
                            delete: { deleteListItem(at: index) }
                        )
                    }
                }
            }

            HStack(spacing: Spacing.sm) {
                TextField("Add item", text: $listItemDraft)
                    .wiskPlainTextInput()
                    .focused($listItemFocused)
                    .onSubmit(addListItem)
                    .accessibilityIdentifier("wisk.list.addItemField")
                Button(action: addListItem) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(listItemDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("wisk.list.addItemButton")
            }
            .padding(Spacing.md)
            .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
        }
        .padding(Spacing.lg)
        .cardStyle()
    }

    private func listOptionsMenu(checklist: NoteChecklistList) -> some View {
        Menu {
            Button("Customize statuses") {
                customizeListStatuses()
            }

            Menu("Apply template") {
                ForEach(NoteChecklist.templates) { template in
                    Button(template.title) {
                        applyListStatusTemplate(template)
                    }
                }
            }

            if checklist.mode == .customStatus {
                Button("Edit statuses") {
                    showingListStatusEditor = true
                }
                Button("Convert to checklist") {
                    convertListToChecklist()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.wiskSecondaryText)
        .accessibilityIdentifier("wisk.list.optionsButton")
    }

    private var listSecondaryAffordance: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Image(systemName: proEntitlement.hasProAccess ? "square.and.arrow.up" : "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(proEntitlement.hasProAccess ? "Share and publish" : "Review, share, and publish with Pro")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text(proEntitlement.hasProAccess ? "Keep these tools tucked away until this list is ready." : "Wisk Pro can organize lists and help publish or share them when you are ready.")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.sm)

                Button(showingListExtras ? "Hide" : "Show") {
                    withAnimation(.snappy) {
                        showingListExtras.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("wisk.list.extrasToggle")
            }

            if !proEntitlement.hasProAccess {
                Button("Learn about Wisk Pro") {
                    showingProUpgrade = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.accent)
                .accessibilityIdentifier("wisk.list.proLearnMoreButton")
            }
        }
        .padding(Spacing.md)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
    }

    @ViewBuilder
    private var noteSecondaryAffordance: some View {
        #if os(iOS)
        // Pro upsell removed from the Bear canvas entirely; the ⋯ menu and
        // Buckets/Settings hold the paywall entry points.
        EmptyView()
        #else
        noteSecondaryAffordanceCard
        #endif
    }

    private var noteSecondaryAffordanceCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Image(systemName: proEntitlement.hasProAccess ? "sparkles.rectangle.stack" : "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(proEntitlement.hasProAccess ? "AI review and sharing" : "AI review and sharing with Pro")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text(proEntitlement.hasProAccess ? "Keep extra tools tucked away until you need them." : "Wisk Pro can organize this note and unlock sharing when you are ready.")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.sm)

                Button(showingNoteExtras ? "Hide" : "Show") {
                    withAnimation(.snappy) {
                        showingNoteExtras.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("wisk.note.extrasToggle")
            }

            if !proEntitlement.hasProAccess {
                Button("Learn about Wisk Pro") {
                    showingProUpgrade = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.accent)
                .accessibilityIdentifier("wisk.note.proLearnMoreButton")
            }
        }
        .padding(Spacing.md)
        .cardStyle(cornerRadius: Radius.button)
    }

    private var trackerEditorCard: some View {
        let tracker = NoteTrackerStore.tracker(from: note.body)
        let counters = NoteTrackerStore.activeCounters(in: tracker)

        return VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tracker", systemImage: "plus.forwardslash.minus")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(Color.wiskPrimaryText)
                Spacer()
                Text(NoteTrackerStore.summary(for: note.body))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.wiskSecondaryText)
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.sm) {
                ForEach(NoteTrackerPeriod.allCases, id: \.title) { period in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(period.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.wiskTertiaryText)
                        Text("\(NoteTrackerStore.formatted(NoteTrackerStore.total(in: tracker, period: period))) \(tracker.unitLabel)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.wiskPrimaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                }
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Setup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wiskTertiaryText)

                TextField("Unit, e.g. hours", text: $trackerUnitDraft)
                    .wiskPlainTextInput()
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                    .accessibilityIdentifier("wisk.tracker.unitField")

                TextField("Quick adds, e.g. 0.25, 0.5, 1, 2", text: $trackerQuickAddsDraft)
                    .wiskPlainTextInput()
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                    .accessibilityIdentifier("wisk.tracker.quickAddsField")

                Button("Save setup", action: saveTrackerSettings)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wisk.tracker.saveSettingsButton")
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Counters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wiskTertiaryText)

                HStack(spacing: Spacing.sm) {
                    TextField("Add counter", text: $trackerCounterDraft)
                        .wiskPlainTextInput()
                        .onSubmit(addTrackerCounter)
                        .accessibilityIdentifier("wisk.tracker.addCounterField")
                    Button(action: addTrackerCounter) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trackerCounterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("wisk.tracker.addCounterButton")
                }
                .padding(Spacing.md)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))

                if counters.isEmpty {
                    Text("Add counters like Engineering, Meetings, or Admin.")
                        .foregroundStyle(Color.wiskSecondaryText)
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                } else {
                    TextField("Optional memo for next entry", text: $trackerMemoDraft)
                        .wiskPlainTextInput()
                        .padding(Spacing.md)
                        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                        .accessibilityIdentifier("wisk.tracker.memoField")

                    ForEach(counters) { counter in
                        TrackerCounterRow(
                            counter: counter,
                            tracker: tracker,
                            record: { amount in recordTrackerEvent(counterID: counter.id, amount: amount) },
                            archive: { archiveTrackerCounter(counter.id) }
                        )
                    }
                }
            }

            if let lastEvent = NoteTrackerStore.lastEventDescription(in: tracker) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.accent)
                    Text("Last entry: \(lastEvent)")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                    Spacer()
                    Button("Undo", action: undoLastTrackerEvent)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.accent)
                }
                .padding(Spacing.md)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
            }
        }
        .padding(Spacing.lg)
        .cardStyle()
    }

    @ViewBuilder
    private var organizationStatus: some View {
        #if os(iOS)
        // Organizer progress surfaces as the transient keyboard toast.
        EmptyView()
        #else
        switch organizer.state {
        case .idle:
            switch parsingService.state {
            case .parsing:
                StatusPill(text: "Organizing with Wisk Pro AI...", icon: "sparkles")
            default:
                EmptyView()
            }
        case .scheduled:
            StatusPill(text: "Wisk Pro will organize this note in a moment.", icon: "clock")
        case .organizing:
            StatusPill(text: "Organizing with Wisk Pro AI...", icon: "sparkles")
        case .failed(let message):
            StatusPill(text: message, icon: "exclamationmark.triangle")
        }
        #endif
    }

    @ViewBuilder
    private var parsingStatus: some View {
        #if os(iOS)
        // Status surfaces as the transient keyboard toast.
        EmptyView()
        #else
        if let statusMessage {
            StatusPill(text: statusMessage, icon: "info.circle")
        }
        #endif
    }

    private var parsedItemsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Review layer")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)

            if !proEntitlement.hasProAccess {
                ProUpgradeCard(
                    title: "AI review is a Pro feature",
                    message: "Upgrade to turn note text into tasks, reminders, learnings, tags, and follow-ups."
                )
            } else if note.parsedItems.isEmpty {
                Text("Actions, learnings, reminders, projects, and references will appear here.")
                    .foregroundStyle(Color.wiskSecondaryText)
            } else {
                let bucketChoices = BucketChoice.choices(from: activeBuckets, fallbackItems: note.parsedItems)
                ForEach(note.parsedItems.sorted { $0.sortOrder < $1.sortOrder }) { item in
                    ParsedItemRow(
                        item: item,
                        bucketChoices: bucketChoices,
                        showBucketMenu: item.acceptedAt == nil,
                        showSourceLink: false
                    ) {
                        toggleAccepted(item)
                    } assignBucket: { bucketID in
                        assignBucket(item, bucketID: bucketID)
                    } reject: {
                        reject(item)
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .cardStyle()
    }

    private var sharingCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Sharing & publishing")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)

            if !proEntitlement.hasProAccess {
                ProUpgradeCard(
                    title: "Share and publish with Pro",
                    message: "Wisk Pro backs collaboration and published notes with your Wisk account."
                )
            } else {
                TextField("Invite by email", text: $shareEmail)
                    .wiskPlainTextInput()
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                    .foregroundStyle(Color.wiskPrimaryText)

                Button("Add viewer") {
                    addShare()
                }
                .buttonStyle(.bordered)

                ForEach(note.shares) { share in
                    HStack {
                        Text(share.email)
                        Spacer()
                        Text(share.role.rawValue)
                            .foregroundStyle(Color.wiskSecondaryText)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.wiskPrimaryText)
                }

                Divider().overlay(Color.cardBorder)

                TextField("public-slug", text: $publishSlug)
                    .wiskPlainTextInput()
                    .padding(Spacing.md)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                    .foregroundStyle(Color.wiskPrimaryText)

                Button(note.publications.contains(where: \.isPublic) ? "Update publication" : "Publish note") {
                    publish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.lg)
        .cardStyle()
    }

    private func persistIdleDraft() {
        guard draftNoteID == note.id else { return }
        let shouldMarkCommit = WiskEditorLifecycle.shouldMarkNeedsCommit(
            draftNoteID: draftNoteID,
            boundNoteID: note.id,
            draftTitle: draftTitle,
            draftBody: draftBody,
            noteTitle: note.title,
            noteBody: note.body
        )
        // No `applyDraftToNote()` here: `WiskEditorPersist.apply` stamps the
        // draft itself, and its `.idle` change detection must see the
        // pre-stamp note to tell a real edit from a no-op lifecycle persist.
        WiskEditorPersist.apply(
            title: draftTitle,
            body: draftBody,
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

    private func leavingDraft(from target: Note?) -> WiskEditorLeavingDraft? {
        guard let target else { return nil }
        return WiskEditorLeavingDraft(
            draftNoteID: draftNoteID,
            draftTitle: draftTitle,
            draftBody: draftBody,
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

    private func commitEditorDraft(to target: Note?, captured: WiskEditorLeavingDraft? = nil) {
        let hadPending: Bool
        let draftNoteIDValue: UUID?
        let draftTitleValue: String
        let draftBodyValue: String
        let needsCommitFlag: Bool
        let targetTitle: String
        let targetBody: String
        if let captured {
            hadPending = captured.hadPendingAutosave
            draftNoteIDValue = captured.draftNoteID
            draftTitleValue = captured.draftTitle
            draftBodyValue = captured.draftBody
            needsCommitFlag = captured.needsCommit
            targetTitle = captured.targetTitle
            targetBody = captured.targetBody
        } else {
            hadPending = editorAutosave.hasPending
            editorAutosave.cancel()
            draftNoteIDValue = draftNoteID
            draftTitleValue = draftTitle
            draftBodyValue = draftBody
            needsCommitFlag = needsCommit
            targetTitle = target?.title ?? ""
            targetBody = target?.body ?? ""
        }
        guard let target else { return }
        let shouldCommit = WiskEditorLifecycle.shouldCommitLeavingEditor(
            draftNoteID: draftNoteIDValue,
            targetID: target.id,
            needsCommit: needsCommitFlag,
            hadPendingAutosave: hadPending,
            draftTitle: draftTitleValue,
            draftBody: draftBodyValue,
            targetTitle: targetTitle,
            targetBody: targetBody
        )
        guard shouldCommit else { return }
        WiskEditorPersist.apply(
            title: draftTitleValue,
            body: draftBodyValue,
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

    private func loadEditorDraftFromNote() {
        editorAutosave.cancel()
        needsCommit = false
        draftNoteID = note.id
        draftTitle = note.title
        draftBody = note.body
    }

    private func applyDraftToNote() {
        if note.title != draftTitle {
            note.title = draftTitle
        }
        if note.body != draftBody {
            note.body = draftBody
        }
    }

    private func adoptNoteContentIntoDraft() {
        draftNoteID = note.id
        draftTitle = note.title
        draftBody = note.body
    }

    private func saveAndSchedule(snapshotReason: String = "edit", fromDraft: Bool = true) {
        saveAndQueueNote(snapshotReason: snapshotReason, fromDraft: fromDraft)
        scheduleOrganizerIfNeeded()
    }

    private func scheduleOrganizerIfNeeded() {
        guard note.kind != .list && note.kind != .tracker else {
            organizer.cancel()
            return
        }
        guard proEntitlement.hasProAccess else {
            organizer.cancel()
            return
        }
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

    private func organizeNow() {
        organizer.cancel()
        applyDraftToNote()
        guard proEntitlement.hasProAccess else {
            showingProUpgrade = true
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

        statusMessage = "Organizing with Wisk Pro AI..."

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
        let source = draftBody
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Add note text before cleaning up."
            return
        }
        let cleaned = NoteCleanup.cleanedBody(source)
        guard cleaned != source else {
            statusMessage = "Already grouped."
            return
        }
        draftBody = cleaned
        saveAndQueueNote(snapshotReason: "cleanup")
        statusMessage = "Grouped similar items."
    }

    #if os(iOS)
    /// Combined transient status for the Bear keyboard toast: explicit status
    /// messages win, then background organizer state.
    private var bearStatusMessage: String? {
        if let statusMessage { return statusMessage }
        switch organizer.state {
        case .idle:
            if case .parsing = parsingService.state {
                return "Organizing with Wisk Pro AI..."
            }
            return nil
        case .scheduled:
            return "Wisk Pro will organize this note in a moment."
        case .organizing:
            return "Organizing with Wisk Pro AI..."
        case .failed(let message):
            return message
        }
    }

    private func deleteNoteFromEditor() {
        guard note.deletedAt == nil else { return }
        note.deletedAt = Date()
        saveAndQueueNote()
        dismissEditor()
    }
    #endif

    private var canRoute: Bool {
        NoteLineRouter.unavailableReason(
            mappings: routeSettings.mappings,
            todoistConnected: routeSettings.isTodoistConnected,
            schyboConnected: routeSettings.isSchyboConnected
        ) == nil
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
        let source = draftBody
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
                draftBody = result.body
                saveAndQueueNote(snapshotReason: "route")
            }
            statusMessage = result.message
            isRouting = false
            if result.savedAdageCount > 0 {
                await syncService.syncNow(context: modelContext)
            }
        }
    }

    private func apply(_ draft: ParsedDailyNoteDraft, _ modelName: String) {
        let defaultTasksBucketID = activeBuckets.first(where: \.isDefault)?.id.uuidString
        note.lastOrganizedAt = Date()
        note.parsedItems.forEach { modelContext.delete($0) }
        note.parsedItems = draft.items.enumerated().map { index, item in
            var normalized = item
            if normalized.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                normalized.bucketId = nil
            }
            if normalized.bucketId == nil,
               (normalized.itemType == .action || normalized.itemType == .reminder) {
                normalized.bucketId = defaultTasksBucketID
            }
            return ParsedNoteItem(draft: normalized, sortOrder: index, note: note)
        }
        note.replaceSuggestedTags(
            with: suggestedTags(from: draft),
            suggestedByAI: modelName != LocalNoteParser.modelIdentifier
        )
        note.projects = suggestedProjects(from: draft).map { NoteProject(name: $0, suggestedByAI: modelName != LocalNoteParser.modelIdentifier, note: note) }
        note.updatedAt = Date()
        saveAndQueueNote()
    }

    private func suggestedTags(from draft: ParsedDailyNoteDraft) -> [String] {
        Array(Set(draft.items.map { $0.itemType.rawValue })).sorted()
    }

    private func suggestedProjects(from draft: ParsedDailyNoteDraft) -> [String] {
        Array(Set(draft.items.compactMap(\.project))).sorted()
    }

    private func toggleAccepted(_ item: ParsedNoteItem) {
        item.reviewStatus = item.reviewStatus == .accepted ? .pending : .accepted
        item.userEdited = true
        item.updatedAt = Date()
        saveAndQueueNote()
    }

    private func reject(_ item: ParsedNoteItem) {
        item.reviewStatus = .rejected
        item.userEdited = true
        item.updatedAt = Date()
        saveAndQueueNote()
    }

    private func assignBucket(_ item: ParsedNoteItem, bucketID: String?) {
        item.bucketId = bucketID
        item.userEdited = true
        item.updatedAt = Date()
        saveAndQueueNote()
    }

    private func addShare() {
        let email = shareEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        note.shares.append(NoteShare(email: email, role: .viewer, note: note))
        shareEmail = ""
        saveAndQueueNote()
    }

    private func publish() {
        let slug = publishSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        let publication = note.publications.first ?? PublishedNote(note: note)
        publication.slug = slug
        publication.isPublic = true
        publication.publishedAt = Date()
        if note.publications.isEmpty {
            note.publications.append(publication)
        }
        saveAndQueueNote()
    }

    private func applyFormatting(_ action: WiskMarkdownFormattingAction) {
        if WiskActiveMarkdownEditor.apply(action) {
            if note.markdownEnabled == false {
                note.markdownEnabled = true
            }
            bodySelection = nil
            saveAndSchedule()
            return
        }
        note.markdownEnabled = true
        let sourceRange = WiskRichMarkdownDocument.replacingCollapsedDocumentEnd(
            formattingSourceRange,
            textLength: (draftBody as NSString).length
        )
        if let mutation = WiskMarkdownDocumentEngine.apply(
            action,
            to: draftBody,
            sourceRange: sourceRange
        ) {
            draftBody = mutation.source
            richBodySelection = Range(mutation.selectedSourceRange, in: draftBody)
        } else {
            draftBody = WiskMarkdownFormatter.apply(action, to: draftBody, selectedRange: formattingTargetRange)
            richBodySelection = nil
        }
        bodySelection = nil
        saveAndSchedule()
    }

    #if os(iOS)
    private func pasteImageFromClipboard() {
        guard let image = UIPasteboard.general.image,
              let data = image.pngData() ?? image.jpegData(compressionQuality: 0.95) else {
            statusMessage = "Copy a screenshot or image first."
            return
        }
        insertAttachment(from: data, altText: "Screenshot")
    }

    private func copyAs(_ format: WiskCopyAsFormat) {
        let source = selectedBodyRange.map { String(draftBody[$0]) } ?? draftBody
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
                title: draftTitle,
                body: source,
                attachments: attachmentSnapshots
            )

            switch format {
            case .plainText:
                let document = WiskNoteInterchange.exportPlainText(snapshot)
                UIPasteboard.general.string = String(data: document.data, encoding: .utf8)
            case .markdown:
                UIPasteboard.general.string = source
            case .richText:
                guard let document = WiskNoteInterchange.exportRTF(snapshot) else {
                    statusMessage = "Rich text could not be created."
                    return
                }
                UIPasteboard.general.setData(document.data, forPasteboardType: UTType.rtf.identifier)
            case .html:
                let document = WiskNoteInterchange.exportHTML(snapshot)
                UIPasteboard.general.setData(document.data, forPasteboardType: UTType.html.identifier)
            }
            statusMessage = "Copied as \(format.title)."
        }
    }

    private func exportNote(_ format: WiskExportFormat) {
        showingFormattingOverlay = false
        statusMessage = "Preparing \(format.title) export..."
        Task {
            let snapshot = await interchangeSnapshot(body: draftBody)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WiskExport-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let exportedURL: URL
                switch format {
                case .markdown:
                    let document = WiskNoteInterchange.exportMarkdown(snapshot)
                    exportedURL = root.appendingPathComponent(document.fileName)
                    try document.data.write(to: exportedURL, options: .atomic)
                case .textBundle:
                    let bundle = WiskNoteInterchange.exportTextBundle(snapshot)
                    exportedURL = root.appendingPathComponent(bundle.packageName, isDirectory: true)
                    for file in bundle.files {
                        let url = exportedURL.appendingPathComponent(file.relativePath)
                        try FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try file.data.write(to: url, options: .atomic)
                    }
                case .richText:
                    guard let document = WiskNoteInterchange.exportRTF(snapshot) else {
                        statusMessage = "Rich text could not be created."
                        return
                    }
                    exportedURL = root.appendingPathComponent(document.fileName)
                    try document.data.write(to: exportedURL, options: .atomic)
                case .html:
                    let document = WiskNoteInterchange.exportHTML(snapshot)
                    exportedURL = root.appendingPathComponent(document.fileName)
                    try document.data.write(to: exportedURL, options: .atomic)
                case .pdf:
                    let payload = WiskNoteInterchange.printablePayload(snapshot)
                    exportedURL = root.appendingPathComponent("\(safeExportBaseName(note.title)).pdf")
                    try renderPDF(fromHTML: payload.html).write(to: exportedURL, options: .atomic)
                }
                exportedURLs = [exportedURL]
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func handleInterchangeImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            statusMessage = "Importing \(url.lastPathComponent)..."
            Task {
                do {
                    let imported = try await Task.detached {
                        try WiskNoteInterchange.importDocument(at: url)
                    }.value
                    let suggestedTitle = url.deletingPathExtension().lastPathComponent
                    if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       note.attachments.allSatisfy({ $0.deletedAt != nil }) {
                        applyInterchangeImport(imported, suggestedTitle: suggestedTitle)
                    } else {
                        pendingInterchangeImport = .init(
                            result: imported,
                            suggestedTitle: suggestedTitle
                        )
                        statusMessage = nil
                    }
                } catch {
                    statusMessage = error.localizedDescription
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyInterchangeImport(
        _ imported: WiskNoteInterchange.ImportResult,
        suggestedTitle: String
    ) {
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
            saveAndSchedule(fromDraft: false)
            statusMessage = pendingUploads.isEmpty
                ? "Imported Markdown."
                : "Imported Markdown and \(pendingUploads.count) attachments."
            for (attachment, data) in pendingUploads {
                Task {
                    await attachmentService.upload(attachment, data: data, noteID: note.id)
                    saveAndQueueNote(fromDraft: false)
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

    private func renderPDF(fromHTML html: String) -> Data {
        let renderer = WiskPrintPageRenderer()
        renderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        let output = NSMutableData()
        UIGraphicsBeginPDFContextToData(output, renderer.paperRect, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return output as Data
    }

    private func insertPhotoAttachment(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                statusMessage = "Wisk could not read that image."
                return
            }
            insertAttachment(from: data, altText: "Image")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func insertScannedDocument(_ pages: [UIImage]) {
        guard !pages.isEmpty else { return }
        let pageBounds = CGRect(origin: .zero, size: pages[0].size)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let data = renderer.pdfData { context in
            for page in pages {
                context.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                page.draw(in: CGRect(origin: .zero, size: page.size))
            }
        }
        insertFileAttachment(
            from: data,
            fileName: "Scanned Document.pdf",
            contentType: UTType.pdf.preferredMIMEType ?? "application/pdf"
        )
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
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
    #endif

    private func insertAttachment(from imageData: Data, altText: String) {
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
            insertAttachmentMarkdown(id: result.attachment.id, title: result.attachment.altText, isImage: true)
            note.updatedAt = Date()
            note.snapshotIfNeeded(reason: "attachment")
            try? modelContext.save()

            Task {
                await attachmentService.upload(result.attachment, imageData: result.normalizedImage.data, noteID: note.id)
                if result.attachment.uploadStatus == .uploaded {
                    saveAndQueueNote()
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
                    saveAndQueueNote()
                } else {
                    try? modelContext.save()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func insertAttachmentMarkdown(id: UUID, title: String, isImage: Bool) {
        applyDraftToNote()
        let reference = WiskAttachmentMarkdown.reference(title: title, id: id, isImage: isImage)
        let utf16Range = formattingTargetRange.map { NSRange($0, in: draftBody) }
        note.body = WiskAttachmentMarkdown.inserting(reference, into: note.body, utf16Range: utf16Range)
        adoptNoteContentIntoDraft()
        suppressedBodyAutosaveValue = note.body
        bodySelection = nil
        richBodySelection = nil
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
            return NSRange(formattingTargetRange, in: draftBody)
        }
        return NSRange(location: 0, length: 0)
    }

    private var wikiLinkTitles: [String] {
        guard let wikiQuery else { return [] }
        return WiskNoteLinkService.autocompleteTitles(query: wikiQuery, in: notes, excluding: note.id)
    }

    private func openWikiLink(_ rawTarget: String) {
        guard let resolved = WiskNoteLinkService.resolveOrCreate(
            rawTarget: rawTarget,
            in: notes,
            context: modelContext
        ) else { return }
        if resolved.didCreate {
            syncService.enqueue(note: resolved.note, context: modelContext)
        }
        if resolved.note.id == note.id {
            if let heading = resolved.heading,
               let range = WiskMarkdownDocumentEngine.headingSourceRange(heading, in: draftBody) {
            jumpToSourceRange = range
            }
            return
        }
        WiskNoteLinkService.PendingJump.set(noteID: resolved.note.id, heading: resolved.heading)
        openNote(resolved.note.id)
    }

    private func consumePendingJump() {
        guard let heading = WiskNoteLinkService.PendingJump.consume(for: note.id),
              let range = WiskMarkdownDocumentEngine.headingSourceRange(heading, in: draftBody) else {
            return
        }
        jumpToSourceRange = range
    }

    private func saveAndQueueNote(snapshotReason: String? = nil, fromDraft: Bool = true) {
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
            snapshotReason: snapshotReason ?? "edit",
            snapshot: snapshotReason != nil,
            syncService: syncService,
            context: modelContext
        )
        needsCommit = false
    }

    private func addListItem() {
        let trimmed = listItemDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        note.body = NoteChecklist.addingItem(trimmed, to: note.body)
        listItemDraft = ""
        saveAndSchedule(fromDraft: false)
        listItemFocused = true
    }

    private func toggleListItem(at index: Int) {
        note.body = NoteChecklist.togglingItem(at: index, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func setListItemStatus(_ statusID: String, at index: Int) {
        note.body = NoteChecklist.settingStatus(statusID, forItemAt: index, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func deleteListItem(at index: Int) {
        note.body = NoteChecklist.deletingItem(at: index, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func clearCompletedListItems() {
        note.body = NoteChecklist.removingCompletedItems(from: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func customizeListStatuses() {
        note.body = NoteChecklist.customizingStatuses(in: note.body)
        saveAndSchedule(fromDraft: false)
        showingListStatusEditor = true
    }

    private func applyListStatusTemplate(_ template: NoteChecklistTemplate) {
        note.body = NoteChecklist.customizingStatuses(in: note.body, template: template)
        saveAndSchedule(fromDraft: false)
        showingListStatusEditor = true
    }

    private func convertListToChecklist() {
        note.body = NoteChecklist.convertingToCheckbox(note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func refreshStructuredTemplates() {
        structuredTemplates = NoteStructuredSections.allTemplates()
    }

    private func sectionTitle(for sectionID: String) -> String {
        NoteStructuredSections.structuredNote(from: note.body).sections.first { $0.id == sectionID }?.title ?? ""
    }

    private func sectionBody(for sectionID: String) -> String {
        NoteStructuredSections.structuredNote(from: note.body).sections.first { $0.id == sectionID }?.body ?? ""
    }

    private func requestStructuredTemplate(_ template: StructuredNoteTemplate) {
        if NoteStructuredSections.isEmptyStructuredBody(note.body) {
            applyStructuredTemplate(template)
        } else {
            pendingStructuredTemplate = template
            showingStructuredTemplateConfirmation = true
        }
    }

    private func applyStructuredTemplate(_ template: StructuredNoteTemplate, replacingContent: Bool = true) {
        guard replacingContent else { return }
        note.body = NoteStructuredSections.body(from: template)
        note.markdownEnabled = true
        note.addTagIfNeeded(template.title)
        pendingStructuredTemplate = nil
        saveAndSchedule(fromDraft: false)
    }

    private func saveStructuredTemplate() {
        guard let template = NoteStructuredSections.templateFromCurrentStructure(
            title: structuredTemplateTitle,
            body: note.body
        ) else { return }
        NoteStructuredSections.saveUserTemplate(template)
        refreshStructuredTemplates()
        statusMessage = "Saved \"\(template.title)\" as a structured note template."
    }

    private func addStructuredSection() {
        let previousBody = note.body
        note.body = NoteStructuredSections.addingSection(title: structuredSectionDraft, to: note.body)
        guard note.body != previousBody else { return }
        structuredSectionDraft = ""
        saveAndSchedule(fromDraft: false)
    }

    private func updateStructuredSectionTitle(_ sectionID: String, title: String) {
        note.body = NoteStructuredSections.updatingSectionTitle(id: sectionID, title: title, in: note.body)
        adoptNoteContentIntoDraft()
        needsCommit = true
        editorAutosave.schedule { persistIdleDraft() }
    }

    private func updateStructuredSectionBody(_ sectionID: String, body: String) {
        note.body = NoteStructuredSections.updatingSectionBody(id: sectionID, sectionBody: body, in: note.body)
        adoptNoteContentIntoDraft()
        needsCommit = true
        editorAutosave.schedule { persistIdleDraft() }
    }

    private func toggleStructuredSection(_ sectionID: String) {
        note.body = NoteStructuredSections.togglingSection(id: sectionID, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func addStructuredQuickItem(to sectionID: String) {
        let draft = structuredQuickAddDrafts[sectionID, default: ""]
        let previousBody = note.body
        note.body = NoteStructuredSections.appendingItem(draft, toSection: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        structuredQuickAddDrafts[sectionID] = ""
        saveAndSchedule(fromDraft: false)
    }

    private func setStructuredSectionMode(_ mode: StructuredNoteSectionMode, sectionID: String) {
        let previousBody = note.body
        note.body = NoteStructuredSections.settingSectionMode(mode, id: sectionID, in: note.body)
        guard note.body != previousBody else { return }
        saveAndSchedule(fromDraft: false)
    }

    private func toggleStructuredChecklistItem(at index: Int, sectionID: String) {
        note.body = NoteStructuredSections.togglingChecklistItem(at: index, sectionID: sectionID, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func deleteStructuredChecklistItem(at index: Int, sectionID: String) {
        note.body = NoteStructuredSections.deletingChecklistItem(at: index, sectionID: sectionID, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func moveStructuredSection(_ sectionID: String, direction: NoteStructuredSections.MoveDirection) {
        note.body = NoteStructuredSections.movingSection(id: sectionID, direction: direction, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func deleteStructuredSection(_ sectionID: String) {
        note.body = NoteStructuredSections.deletingSection(id: sectionID, in: note.body)
        structuredQuickAddDrafts[sectionID] = nil
        saveAndSchedule(fromDraft: false)
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
        saveAndSchedule(fromDraft: false)
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
        saveAndSchedule(fromDraft: false)
    }

    private func archiveTrackerCounter(_ counterID: UUID) {
        note.body = NoteTrackerStore.archivingCounter(id: counterID, in: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func undoLastTrackerEvent() {
        note.body = NoteTrackerStore.removingLastEvent(from: note.body)
        saveAndSchedule(fromDraft: false)
    }

    private func saveTrackerSettings() {
        let quickAdds = trackerQuickAddsDraft
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        note.body = NoteTrackerStore.updatingSettings(unitLabel: trackerUnitDraft, quickAdds: quickAdds, in: note.body)
        syncTrackerDrafts()
        saveAndSchedule(fromDraft: false)
    }

    private func focusTitleForBlankNote() {
        guard note.title.isEmpty, note.body.isEmpty || note.kind == .tracker else { return }
        guard autoFocusedTitleNoteID != note.id else { return }
        autoFocusedTitleNoteID = note.id
        if note.kind == .list {
            listItemFocused = true
        } else {
            titleFocused = true
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct ReviewQueueView: View {
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Query(sort: \ParsedNoteItem.createdAt, order: .reverse) private var items: [ParsedNoteItem]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var activeBuckets: [NoteBucket]
    @State private var mode: ReviewMode = .pending
    @State private var showingProUpgrade = false

    private enum ReviewMode: String, CaseIterable, Identifiable {
        case pending
        case accepted

        var id: String { rawValue }
    }

    private var bucketChoices: [BucketChoice] {
        BucketChoice.choices(from: activeBuckets, fallbackItems: items)
    }

    private var pendingSuggestions: [ParsedNoteItem] {
        items.filter { $0.acceptedAt == nil && $0.rejectedAt == nil && $0.archivedAt == nil && $0.completedAt == nil }
    }

    private var acceptedSuggestions: [ParsedNoteItem] {
        items.filter { $0.acceptedAt != nil && $0.rejectedAt == nil && $0.archivedAt == nil }
    }

    private var acceptedGroups: [AcceptedBucketGroup] {
        let grouped = Dictionary(grouping: acceptedSuggestions) { item in
            item.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        return grouped.map { bucketID, groupedItems in
            AcceptedBucketGroup(
                bucketID: bucketID,
                title: BucketChoice.title(for: bucketID, buckets: activeBuckets),
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
        Group {
            if proEntitlement.hasProAccess {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            Picker("Review mode", selection: $mode) {
                                Text("Pending (\(pendingSuggestions.count))").tag(ReviewMode.pending)
                                Text("Accepted (\(acceptedSuggestions.count))").tag(ReviewMode.accepted)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, Spacing.lg)

                            if proxy.size.width >= 900 {
                                HStack(alignment: .top, spacing: Spacing.lg) {
                                    pendingColumn
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                    acceptedColumn
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .padding(.horizontal, Spacing.lg)
                            } else if mode == .pending {
                                pendingColumn
                                    .padding(.horizontal, Spacing.lg)
                            } else {
                                acceptedColumn
                                    .padding(.horizontal, Spacing.lg)
                            }
                        }
                        .padding(.vertical, Spacing.md)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Wisk Review", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text("Upgrade to triage AI suggestions, assign buckets, and build a review digest from accepted items.")
                } actions: {
                    Button("View Plans") {
                        showingProUpgrade = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(Color.wiskCanvasBackground)
        .navigationTitle("Buckets")
        .wiskInlineNavigationTitle()
        .sheet(isPresented: $showingProUpgrade) {
            ProUpgradeView(
                title: "Unlock Wisk Review",
                message: "Wisk Pro extracts suggestions from notes and sorts them into your bucket definitions."
            )
        }
        .navigationDestination(for: UUID.self) { id in
            if let note = notes.first(where: { $0.id == id }) {
                NoteEditorView(note: note)
            } else {
                ContentUnavailableView("Note not found", systemImage: "questionmark.folder")
            }
        }
    }

    @ViewBuilder
    private var pendingColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("Pending triage", systemImage: "tray.and.arrow.down")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
            Text("Review suggestions before they enter your accepted buckets.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            if pendingSuggestions.isEmpty {
                emptyReviewState("No pending suggestions.")
            } else {
                ForEach(pendingSuggestions) { item in
                    ParsedItemRow(
                        item: item,
                        bucketChoices: bucketChoices,
                        showBucketMenu: true,
                        showSourceLink: false
                    ) {
                        accept(item)
                    } assignBucket: { bucketID in
                        assignBucket(item, bucketID: bucketID)
                    } reject: {
                        reject(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var acceptedColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("Accepted by bucket", systemImage: "square.stack.3d.up.fill")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
            Text("Accepted items keep source-note context so you can jump back and edit the raw note.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            if acceptedSuggestions.isEmpty {
                emptyReviewState("Nothing accepted yet.")
            } else {
                ForEach(acceptedGroups) { group in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.wiskSecondaryText)
                            .padding(.horizontal, Spacing.sm)
                        ForEach(group.items) { item in
                            ParsedItemRow(
                                item: item,
                                bucketChoices: bucketChoices,
                                showBucketMenu: false,
                                showSourceLink: true
                            ) {
                                accept(item)
                            } assignBucket: { bucketID in
                                assignBucket(item, bucketID: bucketID)
                            } reject: {
                                reject(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func emptyReviewState(_ text: String) -> some View {
        ContentUnavailableView(text, systemImage: "tray")
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
    }

    private func accept(_ item: ParsedNoteItem) {
        item.acceptedAt = Date()
        item.rejectedAt = nil
        persistReviewChange(for: item)
    }

    private func reject(_ item: ParsedNoteItem) {
        item.rejectedAt = Date()
        item.acceptedAt = nil
        persistReviewChange(for: item)
    }

    private func assignBucket(_ item: ParsedNoteItem, bucketID: String?) {
        item.bucketId = bucketID
        persistReviewChange(for: item)
    }

    private func persistReviewChange(for item: ParsedNoteItem) {
        item.userEdited = true
        item.updatedAt = Date()
        if let note = item.note {
            note.updatedAt = Date()
            note.syncStatus = .queued
            syncService.enqueue(note: note, context: modelContext)
            Task {
                await syncService.syncNow(context: modelContext)
            }
        } else {
            try? modelContext.save()
        }
    }
}

struct SyncAndShareView: View {
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Query(sort: \SyncMutation.createdAt, order: .reverse) private var mutations: [SyncMutation]
    @Query(sort: \NoteShare.createdAt, order: .reverse) private var shares: [NoteShare]
    @Query private var published: [PublishedNote]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !proEntitlement.hasProAccess {
                    ProUpgradeCard(
                        title: "AI sync is a Pro feature",
                        message: "Upgrade to keep AI-created tasks, tags, review items, and publishing state available across devices."
                    )
                }

                InfoCard(title: "Queued sync", value: "\(mutations.filter { $0.syncedAt == nil }.count)", detail: "Local changes are queued for the custom backend.")
                InfoCard(title: "Shared notes", value: "\(shares.count)", detail: "Owner, editor, and viewer roles are modeled locally.")
                InfoCard(title: "Published notes", value: "\(published.filter(\.isPublic).count)", detail: "Publishing metadata is ready for backend routes.")
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Sync")
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(WiskAuthService.self) private var authService
    @Environment(SyncService.self) private var syncService
    @Environment(WiskProfileService.self) private var profileService
    @Environment(WiskFontManager.self) private var fontManager
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @AppStorage(WiskBetaFeatures.plaudEnabledKey) private var plaudEnabled = false
    @State private var welcomeNotesMessage: String?
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var activeBuckets: [NoteBucket]
    @AppStorage(WiskEditorDefaults.formattingControlsKey) private var formattingControlsEnabled = false
    @AppStorage(WiskEditorDefaults.showMarkdownSyntaxKey) private var showMarkdownSyntax = false
    @AppStorage("wisk.ios.appearance") private var appearanceRawValue = WiskAppearance.system.rawValue
    @State private var bucketNameDraft = ""
    @State private var bucketDescriptionDraft = ""
    @State private var bucketExamplesDraft = ""
    @State private var importingFont = false
    @State private var showingGoogleFonts = false
    @State private var showCopiedFeedbackEmail = false
    #if os(iOS)
    @State private var simplenoteImport = WiskIOSSimplenoteImportController()
    @State private var importingSimplenote = false
    #endif

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            accountCard
            #if DEBUG
            developerSettingsSection
            #endif
            #if os(iOS)
            Section("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(WiskAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wisk.settings.appearancePicker")

                NavigationLink {
                    WiskBuiltInFontChooser(
                        selected: selectedBuiltInFont,
                        accessibilityIdentifier: "wisk.settings.editorFontPicker",
                        onSelect: selectBuiltInFont
                    )
                    .navigationTitle("Font")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Font")
                        Spacer()
                        Text(fontManager.selection.title)
                            .font(fontManager.resolvedFont(size: 17))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            #endif
            editorSettingsCard
            NoteRouteSettingsForm()
            #if os(iOS)
            simplenoteImportCard
            #endif
            bucketSettingsCard
            welcomeNotesSection
            Section("Wisk Pro") {
                ProUpgradeCard(
                    title: "Wisk Pro",
                    message: "Writing is free. AI organization, task extraction, smart review, sharing, and publishing are included with Pro."
                )
            }
            aboutCard
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(
            isPresented: $importingFont,
            allowedContentTypes: WiskFontImportTypes.allowed,
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            Task {
                await fontManager.importLocalFont(from: url)
                await profileService.syncGoogleFontSelection(nil)
            }
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $importingSimplenote,
            allowedContentTypes: [.json, .zip, .folder],
            allowsMultipleSelection: false
        ) { result in
            guard let url = try? result.get().first else { return }
            simplenoteImport.beginImport(from: url, context: modelContext, syncService: syncService)
        }
        .overlay {
            if let progress = simplenoteImport.progress {
                WiskIOSSimplenoteImportOverlay(progress: progress) {
                    simplenoteImport.cancel()
                }
            }
        }
        .alert(item: Binding(
            get: { simplenoteImport.alert },
            set: { simplenoteImport.alert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Import Simplenote notes?",
            isPresented: Binding(
                get: { simplenoteImport.confirmation != nil },
                set: { if !$0 { simplenoteImport.confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Import") {
                simplenoteImport.confirmImport(context: modelContext, syncService: syncService)
            }
            Button("Cancel", role: .cancel) {
                simplenoteImport.confirmation = nil
            }
        } message: {
            if let confirmation = simplenoteImport.confirmation {
                Text(
                    "Add \(confirmation.createCount.formatted()) notes and update \(confirmation.updateCount.formatted()). \(confirmation.unchangedCount.formatted()) already match."
                )
            }
        }
        #endif
        .sheet(isPresented: $showingGoogleFonts) {
            WiskGoogleFontPickerView { font in
                Task {
                    await fontManager.installGoogleFont(font)
                    await profileService.syncGoogleFontSelection(fontManager.selection)
                }
            }
        }
    }

    private var aboutCard: some View {
        Section("About") {
            VStack(spacing: 0) {
                aboutRow(title: "Version", systemImage: "info.circle", value: appVersion)

                Divider().overlay(Color.cardBorder)

                Button {
                    sendSettingsFeedback(intent: .featureRequest)
                } label: {
                    aboutRow(title: "Feature Request", systemImage: "lightbulb", showsExternalIndicator: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings_feature_request_button")

                Divider().overlay(Color.cardBorder)

                Button {
                    sendSettingsFeedback(intent: .bugReport)
                } label: {
                    aboutRow(title: "Submit a Bug Report", systemImage: "exclamationmark.bubble", showsExternalIndicator: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings_bug_report_button")

                Divider().overlay(Color.cardBorder)

                Link(destination: URL(string: "mailto:support@clarved.com?subject=Wisk%20Support")!) {
                    aboutRow(title: "Support", systemImage: "questionmark.circle", showsExternalIndicator: true)
                }
                .accessibilityIdentifier("settings_support_link")

                Divider().overlay(Color.cardBorder)

                Link(destination: URL(string: "https://clarved.com/privacy")!) {
                    aboutRow(title: "Privacy Policy", systemImage: "hand.raised", showsExternalIndicator: true)
                }
                .accessibilityIdentifier("settings_privacy_link")

                Divider().overlay(Color.cardBorder)

                Link(destination: URL(string: "https://clarved.com/apps")!) {
                    aboutRow(title: "More Clarved Apps", systemImage: "square.grid.2x2", showsExternalIndicator: true)
                }
                .accessibilityIdentifier("settings_clarved_apps_link")

                if AppConstants.appStoreID != "0000000000",
                   let reviewURL = URL(string: "https://apps.apple.com/app/id\(AppConstants.appStoreID)?action=write-review"),
                   let appURL = URL(string: "https://apps.apple.com/app/id\(AppConstants.appStoreID)") {
                    Divider().overlay(Color.cardBorder)

                    Link(destination: reviewURL) {
                        aboutRow(title: "Rate on App Store", systemImage: "star", showsExternalIndicator: true)
                    }
                    .accessibilityIdentifier("settings_rate_button")

                    Divider().overlay(Color.cardBorder)

                    ShareLink(
                        item: appURL,
                        message: Text("Capture and organize daily notes with Wisk.")
                    ) {
                        aboutRow(title: "Share Wisk", systemImage: "square.and.arrow.up", showsExternalIndicator: true)
                    }
                    .accessibilityIdentifier("settings_share_button")
                }
            }

            if showCopiedFeedbackEmail {
                Text("Email copied — support@clarved.com")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func aboutRow(
        title: String,
        systemImage: String,
        value: String? = nil,
        showsExternalIndicator: Bool = false
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Color.wiskPrimaryText)
            Spacer()
            if let value {
                Text(value)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.wiskSecondaryText)
            } else if showsExternalIndicator {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    private var accountCard: some View {
        Section("Account") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(authService.displayName)
                    .font(.headline)
                Text(authService.accountSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Sign Out", role: .destructive) {
                try? authService.signOut()
            }
        }
    }

    #if DEBUG
    private var developerSettingsSection: some View {
        Section {
            Toggle("Unlock Wisk Pro", isOn: Bindable(proEntitlement).debugForceProAccess)
                .accessibilityIdentifier("wisk.settings.debugUnlockPro")
            Toggle("Plaud import (beta)", isOn: $plaudEnabled)
                .accessibilityIdentifier("wisk.settings.betaPlaudToggle")
            LabeledContent("AI API", value: WiskAPIConfiguration.resolvedBaseURL().absoluteString)
                .textSelection(.enabled)
        } header: {
            Text("Developer")
        } footer: {
            Text("Unlock Pro bypasses StoreKit in Debug. Plaud is an internal beta and stays hidden unless enabled here.")
        }
    }
    #endif

    private var welcomeNotesSection: some View {
        Section("Welcome Notes") {
            Text("New accounts start with short helper notes. Restore any you deleted.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)
            Button("Restore welcome notes") {
                let restored = WiskHelperNoteSeedService.restoreMissingHelpers(
                    context: modelContext,
                    syncService: syncService,
                    uid: authService.firebaseUID
                )
                welcomeNotesMessage = restored > 0
                    ? "Restored \(restored) welcome note\(restored == 1 ? "" : "s")."
                    : "Welcome notes are already in your library."
            }
            .accessibilityIdentifier("wisk.settings.restoreWelcomeNotesButton")
            if let welcomeNotesMessage {
                Text(welcomeNotesMessage)
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
            }
        }
    }

    private var editorSettingsCard: some View {
        Section("Editor") {
            Text("Markdown tools stay tucked away until you want them.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            Text(fontManager.selection.description)
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            Text(WiskBuiltInFontChooser.sample)
                .font(fontManager.resolvedFont(size: CGFloat(WiskEditorDefaults.defaultFontSize)))
                .foregroundStyle(Color.wiskPrimaryText)
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Custom Fonts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wiskPrimaryText)
                Text("Current: \(fontManager.selection.title)")
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                if let message = fontManager.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                }
                HStack {
                    Button("Import Font") {
                        importingFont = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(fontManager.isWorking)
                    .accessibilityIdentifier("wisk.settings.importFontButton")

                    Button("Google Fonts") {
                        showingGoogleFonts = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(fontManager.isWorking)
                    .accessibilityIdentifier("wisk.settings.googleFontsButton")
                }

                Button("Remove custom font") {
                    fontManager.removeCustomFontSelection()
                    Task {
                        await profileService.syncGoogleFontSelection(nil)
                    }
                }
                .font(.caption)
                .disabled(fontManager.selection.source == .builtIn || fontManager.isWorking)

                if fontManager.isWorking {
                    ProgressView("Updating font...")
                }
            }
            .padding(Spacing.md)
            .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))

            Toggle(isOn: $formattingControlsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Markdown formatting menu")
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text("Adds hidden power-user controls for bold, italic, headings, lists, code, and links.")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                }
            }
            .accessibilityIdentifier("wisk.settings.formattingControlsToggle")

            Toggle(isOn: $showMarkdownSyntax) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Markdown characters")
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text("Keep writing in the same editor while showing heading markers, list prefixes, and other Markdown syntax.")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                }
            }
            .accessibilityIdentifier("wisk.settings.showMarkdownSyntaxToggle")
        }
    }

    #if os(iOS)
    private var simplenoteImportCard: some View {
        Section("Import") {
            Text("Bring notes from a Simplenote export. Choose notes.json, a zip, or an exported folder.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            Button("Import Simplenote Notes") {
                importingSimplenote = true
            }
            .disabled(simplenoteImport.isImporting)
            .accessibilityIdentifier("wisk.settings.importSimplenoteButton")

            Button("Undo Last Simplenote Import") {
                simplenoteImport.undoLastImport(context: modelContext, syncService: syncService)
            }
            .disabled(simplenoteImport.isImporting || SimplenoteNoteImportService.lastImportBatch().isEmpty)
            .accessibilityIdentifier("wisk.settings.undoSimplenoteImportButton")
        }
    }
    #endif

    private var bucketSettingsCard: some View {
        Section("Buckets") {
            Text("Define how Wisk groups suggestions. Buckets include a name, description, and examples.")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)

            if activeBuckets.isEmpty {
                Text("No active buckets yet.")
                    .foregroundStyle(Color.wiskSecondaryText)
            } else {
                ForEach(activeBuckets) { bucket in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(bucket.name.nilIfEmpty ?? "Untitled bucket")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.wiskPrimaryText)
                            if bucket.isDefault {
                                Text("Default")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.accent)
                                    .padding(.horizontal, Spacing.xs)
                                    .padding(.vertical, 2)
                                    .background(Color.accent.opacity(0.12), in: Capsule())
                            }
                            Spacer()
                            if !bucket.isDefault {
                                Button("Archive") {
                                    archive(bucket)
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.wiskSecondaryText)
                            }
                        }

                        if let description = bucket.descriptionText.nilIfEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(Color.wiskSecondaryText)
                        }

                        if !bucket.examples.isEmpty {
                            Text("Examples: \(bucket.examples.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(Color.wiskSecondaryText)
                        }
                    }
                    .padding(Spacing.sm)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                }
            }

            Divider().overlay(Color.cardBorder)

            TextField("Bucket name (e.g. Learnings)", text: $bucketNameDraft)
                .wiskPlainTextInput()
                .padding(Spacing.md)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                .foregroundStyle(Color.wiskPrimaryText)

            TextField("Description (how Wisk should classify into this bucket)", text: $bucketDescriptionDraft, axis: .vertical)
                .lineLimit(2...4)
                .wiskPlainTextInput()
                .padding(Spacing.md)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                .foregroundStyle(Color.wiskPrimaryText)

            TextField("Examples (comma separated)", text: $bucketExamplesDraft)
                .wiskPlainTextInput()
                .padding(Spacing.md)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                .foregroundStyle(Color.wiskPrimaryText)

            Button("Add bucket") {
                addBucket()
            }
            .buttonStyle(.borderedProminent)
            .disabled(bucketNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private enum SettingsFeedbackIntent {
        case featureRequest
        case bugReport

        var subjectSuffix: String {
            switch self {
            case .featureRequest: "Feature Request"
            case .bugReport: "Bug Report"
            }
        }

        var openingLine: String {
            switch self {
            case .featureRequest:
                ""
            case .bugReport:
                """
                Describe the bug:
                Steps to reproduce:
                Expected behavior:
                Actual behavior:
                """
            }
        }
    }

    private func sendSettingsFeedback(intent: SettingsFeedbackIntent) {
        guard let url = settingsFeedbackURL(intent: intent) else {
            copyFeedbackEmail()
            return
        }
        openURL(url) { accepted in
            if !accepted {
                copyFeedbackEmail()
            }
        }
    }

    private func settingsFeedbackURL(intent: SettingsFeedbackIntent) -> URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = "support@clarved.com"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "[Wisk] \(intent.subjectSuffix)"),
            URLQueryItem(name: "body", value: settingsFeedbackBody(intent: intent)),
        ]
        return comps.url
    }

    private func settingsFeedbackBody(intent: SettingsFeedbackIntent) -> String {
        """
        \(intent.openingLine)


        —
        Wisk \(appVersion)
        """
    }

    private func copyFeedbackEmail() {
        #if os(iOS)
        UIPasteboard.general.string = "support@clarved.com"
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("support@clarved.com", forType: .string)
        #endif
        showCopiedFeedbackEmail = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { showCopiedFeedbackEmail = false }
        }
    }

    private func addBucket() {
        let name = bucketNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let examples = bucketExamplesDraft
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let bucket = NoteBucket(
            name: name,
            descriptionText: bucketDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            examples: examples,
            sortOrder: (activeBuckets.map(\.sortOrder).max() ?? -1) + 1,
            isDefault: false
        )
        modelContext.insert(bucket)
        try? modelContext.save()
        Task {
            await syncService.syncNow(context: modelContext)
        }

        bucketNameDraft = ""
        bucketDescriptionDraft = ""
        bucketExamplesDraft = ""
    }

    private func archive(_ bucket: NoteBucket) {
        bucket.archivedAt = Date()
        bucket.updatedAt = Date()
        try? modelContext.save()
        Task {
            await syncService.syncNow(context: modelContext)
        }
    }

    private var appearanceBinding: Binding<WiskAppearance> {
        Binding(
            get: { WiskAppearance(rawValue: appearanceRawValue) ?? .system },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    #if os(iOS)
    private var selectedBuiltInFont: WiskEditorFontFamily? {
        fontManager.selection.source == .builtIn ? fontManager.selection.builtInFont : nil
    }

    private func selectBuiltInFont(_ family: WiskEditorFontFamily) {
        fontManager.selectBuiltIn(family)
        Task {
            await profileService.syncGoogleFontSelection(nil)
        }
    }
    #endif
}

private enum NoteDateDisplay {
    static func created(_ date: Date) -> String {
        "Created \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func edited(_ date: Date) -> String {
        "Edited \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct NoteDateSummary: View {
    let note: Note
    var notes: [Note] = []
    var foldedSourceLocations: Binding<Set<Int>> = .constant([])
    var onJumpToSourceRange: ((NSRange) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Label(NoteDateDisplay.edited(note.updatedAt), systemImage: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wiskSecondaryText)
                    .lineLimit(1)

                Label(NoteDateDisplay.created(note.createdAt), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Color.wiskTertiaryText)
                    .lineLimit(1)
            }

            WiskNoteLinkExtrasView(
                note: note,
                notes: notes,
                foldedSourceLocations: foldedSourceLocations,
                onJumpToSourceRange: onJumpToSourceRange
            )
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
        .accessibilityElement(children: .contain)
    }
}

private struct StructuredSectionCard: View {
    let section: StructuredNoteSection
    let attachments: [NoteAttachment]
    @Binding var title: String
    @Binding var bodyText: String
    @Binding var quickAddDraft: String
    let toggleCollapsed: () -> Void
    let addQuickItem: () -> Void
    let setMode: (StructuredNoteSectionMode) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
    let toggleChecklistItem: (Int) -> Void
    let deleteChecklistItem: (Int) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canDelete: Bool

    @State private var confirmingDelete = false
    @State private var richSelection: Range<String.Index>?
    @FocusState private var quickAddFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Button(action: toggleCollapsed) {
                    Image(systemName: section.isCollapsed ? "chevron.right.circle.fill" : "chevron.down.circle.fill")
                        .foregroundStyle(.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wisk.structured.section.\(section.id).toggle")
                .accessibilityLabel("\(title.nilIfEmpty ?? "Untitled Section") section")
                .accessibilityHint(section.isCollapsed ? "Expands this section" : "Collapses this section")
                .accessibilityValue(section.isCollapsed ? "Collapsed" : "Expanded")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.nilIfEmpty ?? "Untitled Section")
                        .font(.headline)
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text(section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty" : firstLine)
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleCollapsed)

                sectionMenu
            }

            if !section.isCollapsed {
                TextField("Section title", text: $title)
                    .wiskPlainTextInput()
                    .padding(Spacing.md)
                    .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button))
                    .accessibilityIdentifier("wisk.structured.section.\(section.id).titleField")

                if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add the first item to \(title.nilIfEmpty ?? "this section").")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                        .padding(.horizontal, Spacing.xs)
                }

                if section.mode == .checklist {
                    checklistBody
                } else {
                    WiskNextComposer(
                        markdownText: $bodyText,
                        selectedMarkdownRange: $richSelection,
                        attachments: attachments,
                        minHeight: 120,
                        accessibilityIdentifier: "wisk.structured.section.\(section.id).bodyEditor"
                    )
                    .frame(minHeight: 120)
                    .padding(Spacing.sm)
                    .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button))
                }

                HStack(spacing: Spacing.sm) {
                    TextField("Add to \(title.nilIfEmpty ?? "section")", text: $quickAddDraft)
                        .wiskPlainTextInput()
                        .focused($quickAddFocused)
                        .onSubmit(addQuickItem)
                        .accessibilityIdentifier("wisk.structured.section.\(section.id).quickAddField")
                    Button {
                        addQuickItem()
                        quickAddFocused = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(quickAddDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("wisk.structured.section.\(section.id).quickAddButton")
                }
                .padding(Spacing.md)
                .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button))
            }
        }
        .padding(Spacing.md)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .animation(.snappy, value: section.isCollapsed)
        .confirmationDialog(
            "Delete \(title.nilIfEmpty ?? "this section")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Section", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The section title and its notes will be removed from this structured note.")
        }
    }

    private var firstLine: String {
        if section.mode == .checklist {
            return NoteStructuredSections.checklistProgressSummary(for: section)
        }
        return section.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Has notes"
    }

    private var checklistBody: some View {
        let items = NoteStructuredSections.checklistItems(in: section)

        return VStack(spacing: Spacing.xs) {
            if items.isEmpty {
                Text("Add the first checklist item to \(title.nilIfEmpty ?? "this section").")
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button))
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Button {
                            toggleChecklistItem(index)
                        } label: {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCompleted ? Color.accent : Color.wiskSecondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wisk.structured.section.\(section.id).checklistToggle.\(index)")
                        .accessibilityLabel(item.isCompleted ? "Mark item not done" : "Mark item done")

                        Text(item.text)
                            .foregroundStyle(item.isCompleted ? Color.wiskSecondaryText : Color.wiskPrimaryText)
                            .strikethrough(item.isCompleted)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            deleteChecklistItem(index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.wiskSecondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wisk.structured.section.\(section.id).checklistDelete.\(index)")
                        .accessibilityLabel("Delete checklist item")
                    }
                    .padding(Spacing.md)
                    .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button))
                }
            }
        }
    }

    private var sectionMenu: some View {
        Menu {
            Button(section.mode == .checklist ? "Convert to Text Section" : "Convert to To-do List") {
                setMode(section.mode == .checklist ? .text : .checklist)
            }
            Divider()
            Button("Move Up", action: moveUp)
                .disabled(!canMoveUp)
            Button("Move Down", action: moveDown)
                .disabled(!canMoveDown)
            Divider()
            Button(section.isCollapsed ? "Expand" : "Collapse", action: toggleCollapsed)
            Button("Delete Section", role: .destructive) {
                confirmingDelete = true
            }
                .disabled(!canDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Color.wiskSecondaryText)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("wisk.structured.section.\(section.id).menu")
        .accessibilityLabel("Section actions")
    }
}

struct WiskFormattingBar<Accessory: View>: View {
    enum AccessoryPlacement {
        case leading
        case trailing
    }

    let applyFormatting: (WiskMarkdownFormattingAction) -> Void
    let accessoryPlacement: AccessoryPlacement
    let accessory: Accessory

    init(
        applyFormatting: @escaping (WiskMarkdownFormattingAction) -> Void,
        accessoryPlacement: AccessoryPlacement = .trailing,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.applyFormatting = applyFormatting
        self.accessoryPlacement = accessoryPlacement
        self.accessory = accessory()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            formattingRow(inlineActions: WiskMarkdownFormattingAction.allCases, overflowActions: [])
            formattingRow(inlineActions: Self.coreInlineActions, overflowActions: overflowActions(excluding: Self.coreInlineActions))
            formattingRow(inlineActions: Self.essentialInlineActions, overflowActions: overflowActions(excluding: Self.essentialInlineActions))
            ScrollView(.horizontal, showsIndicators: false) {
                formattingRow(inlineActions: Self.essentialInlineActions, overflowActions: overflowActions(excluding: Self.essentialInlineActions))
            }
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("wisk.formattingBar")
    }

    private static var essentialInlineActions: [WiskMarkdownFormattingAction] {
        [.bold, .italic, .underline, .bullet, .numberedList, .checklist]
    }

    private static var coreInlineActions: [WiskMarkdownFormattingAction] {
        [.bold, .italic, .underline, .strikethrough, .highlight, .heading, .bullet, .numberedList, .checklist, .quote]
    }

    private func overflowActions(excluding inlineActions: [WiskMarkdownFormattingAction]) -> [WiskMarkdownFormattingAction] {
        WiskMarkdownFormattingAction.allCases.filter { inlineActions.contains($0) == false }
    }

    private func formattingRow(
        inlineActions: [WiskMarkdownFormattingAction],
        overflowActions: [WiskMarkdownFormattingAction]
    ) -> some View {
        HStack(spacing: 6) {
            if accessoryPlacement == .leading {
                accessory
                Divider()
                    .frame(height: 20)
            }

            ForEach(inlineActions) { action in
                formattingButton(for: action)
            }

            if !overflowActions.isEmpty {
                overflowMenu(actions: overflowActions)
            }

            if accessoryPlacement == .trailing {
                accessory
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private func formattingButton(for action: WiskMarkdownFormattingAction) -> some View {
        #if os(macOS)
        WiskMacNonActivatingFormattingButton(action: action, apply: applyFormatting)
            .frame(minWidth: 28, minHeight: 22)
            .help(action.title)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("wisk.formatting.\(action.rawValue)")
        #else
        Button {
            applyFormatting(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("wisk.formatting.\(action.rawValue)")
        #endif
    }

    private func overflowMenu(actions: [WiskMarkdownFormattingAction]) -> some View {
        Menu {
            ForEach(actions) { action in
                Button {
                    applyFormatting(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .accessibilityIdentifier("wisk.formatting.\(action.rawValue)")
            }
        } label: {
            WiskFormattingOverflowLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help("More formatting")
        .accessibilityLabel("More formatting")
        .accessibilityIdentifier("wisk.formatting.more")
        #if os(macOS)
        .focusable(false)
        #endif
    }
}

#if os(macOS)
private final class WiskNonActivatingButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
}

private struct WiskMacNonActivatingFormattingButton: NSViewRepresentable {
    let action: WiskMarkdownFormattingAction
    let apply: (WiskMarkdownFormattingAction) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = WiskNonActivatingButton()
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.isBordered = true
        button.refusesFirstResponder = true
        button.focusRingType = .none
        button.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: action.title)
        button.toolTip = action.title
        button.setAccessibilityLabel(action.title)
        button.setAccessibilityIdentifier("wisk.formatting.\(action.rawValue)")
        button.target = context.coordinator
        button.action = #selector(Coordinator.tap)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.apply = apply
        nsView.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: action.title)
        nsView.toolTip = action.title
        nsView.setAccessibilityLabel(action.title)
        nsView.setAccessibilityIdentifier("wisk.formatting.\(action.rawValue)")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, apply: apply)
    }

    final class Coordinator: NSObject {
        var action: WiskMarkdownFormattingAction
        var apply: (WiskMarkdownFormattingAction) -> Void

        init(action: WiskMarkdownFormattingAction, apply: @escaping (WiskMarkdownFormattingAction) -> Void) {
            self.action = action
            self.apply = apply
        }

        @objc func tap() {
            apply(action)
        }
    }
}
#endif

private struct WiskFormattingOverflowLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}

struct WiskFormattingToggleButton: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 2) {
                Text("B")
                    .bold()
                Text("I")
                    .italic()
                Text("U")
                    .underline()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isExpanded ? Color.accent : Color.wiskSecondaryText)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                (isExpanded ? Color.accent.opacity(0.12) : Color.wiskInputBackground),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(isExpanded ? Color.accent.opacity(0.18) : Color.cardBorder, lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(isExpanded ? "Hide formatting controls" : "Show formatting controls")
        .accessibilityIdentifier("wisk.formattingToggle")
    }
}

private struct NoteRow: View {
    let note: Note

    private var displayTitle: String {
        NoteLibraryIndex.displayTitle(for: note)
    }

    private var excerpt: String {
        let value = NoteLibraryIndex.displayExcerpt(for: note)
        if note.kind == .list, value.isEmpty {
            return "No items yet"
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Spacing.sm) {
                if note.kind == .list {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                } else if note.kind == .structured {
                    Image(systemName: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                } else if note.kind == .tracker {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                }

                Text(displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.wiskPrimaryText)
                    .lineLimit(1)

                Spacer()

                if note.syncStatus == .queued {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.accent)
                }
            }

            Text(excerpt.isEmpty ? "No additional text" : excerpt)
                .font(.system(size: 15))
                .foregroundStyle(Color.wiskSecondaryText)
                .lineLimit(2)

            Text(NoteDateDisplay.edited(note.updatedAt))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wiskTertiaryText)
                .lineLimit(1)

            if note.kind == .list {
                Text(NoteChecklist.progressSummary(for: note.body))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.wiskTertiaryText)
                    .lineLimit(1)
            } else if note.kind == .structured {
                Text(NoteStructuredSections.summary(for: note.body))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.wiskTertiaryText)
                    .lineLimit(1)
            } else if note.kind == .tracker {
                Text(NoteTrackerStore.searchableText(for: note.body))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.wiskTertiaryText)
                    .lineLimit(1)
            }

            if !note.tags.isEmpty {
                HStack(spacing: Spacing.sm) {
                    ForEach(note.tags.prefix(3)) { tag in
                        Text(tag.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.wiskTertiaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChecklistItemRow: View {
    let item: NoteChecklistItem
    let checklist: NoteChecklistList
    let toggle: () -> Void
    let setStatus: (String) -> Void
    let editStatuses: () -> Void
    let delete: () -> Void

    private var status: NoteChecklistStatus {
        NoteChecklist.status(for: item, in: checklist)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            if checklist.mode == .customStatus {
                statusPicker
            } else {
                Button(action: toggle) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(item.isCompleted ? Color.accent : Color.wiskSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isCompleted ? "Mark item not done" : "Mark item done")
            }

            Text(item.text)
                .font(.body)
                .foregroundStyle(item.isCompleted ? Color.wiskSecondaryText : Color.wiskPrimaryText)
                .strikethrough(item.isCompleted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: delete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(Color.wiskTertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete item")
        }
        .padding(Spacing.md)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
    }

    private var statusPicker: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                ChecklistStatusChip(status: status)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cycle status")
            .accessibilityValue(status.title)

            Menu {
                ForEach(checklist.statuses.sorted { $0.sortOrder < $1.sortOrder }) { status in
                    Button {
                        setStatus(status.id)
                    } label: {
                        Label(status.title, systemImage: status.systemImage)
                    }
                }
                Divider()
                Button("Edit statuses...", action: editStatuses)
            } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wiskTertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose status")
        }
    }
}

private struct ChecklistStatusChip: View {
    let status: NoteChecklistStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(status.isCompleted ? Color.accent : Color.wiskSecondaryText)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background((status.isCompleted ? Color.accent : Color.wiskSecondaryText).opacity(0.12), in: Capsule())
    }
}

struct ChecklistStatusEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var list: NoteChecklistList
    @State private var statusDraft = ""
    let save: (NoteChecklistList) -> Void

    init(list: NoteChecklistList, save: @escaping (NoteChecklistList) -> Void) {
        _list = State(initialValue: NoteChecklistList(
            version: list.version,
            mode: .customStatus,
            statuses: list.statuses,
            items: list.items
        ))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($list.statuses) { $status in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: status.systemImage)
                                .foregroundStyle(status.isCompleted ? Color.accent : Color.wiskSecondaryText)
                                .frame(width: 24)

                            TextField("Status", text: $status.title)
                                .wiskPlainTextInput()

                            Toggle("Done", isOn: $status.isCompleted)
                                .labelsHidden()
                        }
                    }
                    .onDelete(perform: deleteStatuses)
                    .onMove(perform: moveStatuses)
                } header: {
                    Text("Statuses")
                } footer: {
                    Text("Statuses marked done count toward progress and are cleared by Clear completed.")
                }

                Section("Add status") {
                    HStack {
                        TextField("New status", text: $statusDraft)
                            .wiskPlainTextInput()
                            .onSubmit(addStatus)
                        Button("Add", action: addStatus)
                            .disabled(statusDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Templates") {
                    ForEach(NoteChecklist.templates) { template in
                        Button(template.title) {
                            apply(template)
                        }
                    }
                }
            }
            .navigationTitle("List Statuses")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(normalizedList())
                        dismiss()
                    }
                }
            }
        }
    }

    private func addStatus() {
        let title = statusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        list.statuses.append(NoteChecklistStatus(
            title: title,
            systemImage: "tag",
            isCompleted: false,
            sortOrder: list.statuses.count
        ))
        list.statuses = NoteChecklist.normalizedStatuses(list.statuses)
        list.items = NoteChecklist.normalizedItems(list.items, statuses: list.statuses, mode: .customStatus)
        statusDraft = ""
    }

    private func deleteStatuses(at offsets: IndexSet) {
        guard list.statuses.count > offsets.count else { return }
        list.statuses.remove(atOffsets: offsets)
        list.statuses = NoteChecklist.normalizedStatuses(list.statuses)
        list.items = NoteChecklist.normalizedItems(list.items, statuses: list.statuses, mode: .customStatus)
    }

    private func moveStatuses(from source: IndexSet, to destination: Int) {
        list.statuses.move(fromOffsets: source, toOffset: destination)
        list.statuses = NoteChecklist.normalizedStatuses(list.statuses)
        list.items = NoteChecklist.normalizedItems(list.items, statuses: list.statuses, mode: .customStatus)
    }

    private func apply(_ template: NoteChecklistTemplate) {
        list.statuses = NoteChecklist.normalizedStatuses(template.statuses)
        list.items = NoteChecklist.normalizedItems(list.items, statuses: list.statuses, mode: .customStatus)
    }

    private func normalizedList() -> NoteChecklistList {
        NoteChecklistList(
            version: list.version,
            mode: .customStatus,
            statuses: list.statuses,
            items: list.items
        )
    }
}

private struct TrackerCounterRow: View {
    let counter: NoteTracker.Counter
    let tracker: NoteTracker
    let record: (Double) -> Void
    let archive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(counter.name)
                        .font(.headline)
                        .foregroundStyle(Color.wiskPrimaryText)
                    Text("\(NoteTrackerStore.formatted(NoteTrackerStore.total(in: tracker, counterID: counter.id))) \(tracker.unitLabel) all time")
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                }

                Spacer()

                Button("Archive", action: archive)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.wiskTertiaryText)
            }

            HStack(spacing: Spacing.sm) {
                ForEach(tracker.quickAdds, id: \.self) { amount in
                    Button("+\(NoteTrackerStore.formatted(amount))") {
                        record(amount)
                    }
                    .buttonStyle(.bordered)
                    .wiskRoundedButtonBorder()
                    .accessibilityIdentifier("wisk.tracker.increment.\(counter.id.uuidString).\(NoteTrackerStore.formatted(amount))")
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
    }
}

private struct TagChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accent.opacity(0.12) : Color.wiskGroupedBackground, in: Capsule())
                .foregroundStyle(isSelected ? Color.accent : Color.wiskSecondaryText)
        }
        .buttonStyle(.plain)
    }
}

struct MarkdownPreview: View {
    @Environment(WiskFontManager.self) private var fontManager

    let text: String
    var attachments: [NoteAttachment] = []
    var baseFontSize: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(renderedLines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let level, let content):
                    markdownText(content)
                        .font(headingFont(for: level))
                        .foregroundStyle(Color.wiskPrimaryText)
                        .padding(.top, level == 1 ? Spacing.sm : Spacing.xs)
                case .checklist(let isChecked, let content):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isChecked ? Color.accent : Color.wiskSecondaryText)
                        markdownText(content)
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskPrimaryText)
                    }
                case .bullet(let content):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("•")
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskSecondaryText)
                        markdownText(content)
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskPrimaryText)
                    }
                case .numbered(let number, let content):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("\(number).")
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskSecondaryText)
                            .monospacedDigit()
                        markdownText(content)
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskPrimaryText)
                    }
                case .quote(let content):
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accent.opacity(0.55))
                            .frame(width: 3)
                        markdownText(content)
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskSecondaryText)
                    }
                    .padding(.vertical, 2)
                case .callout(let kind, let content):
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.capitalized)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.accent)
                            markdownText(content)
                                .font(bodyFont)
                                .foregroundStyle(Color.wiskPrimaryText)
                        }
                    }
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.button))
                case .separator:
                    Divider()
                        .overlay(Color.wiskTertiaryText.opacity(0.35))
                        .padding(.vertical, Spacing.xs)
                case .codeBlock(let language, let content):
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            if let language, !language.isEmpty {
                                Text(language)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.wiskSecondaryText)
                            }
                            Text(content)
                                .font(.system(size: baseFontSize ?? CGFloat(WiskEditorDefaults.defaultFontSize), design: .monospaced))
                                .foregroundStyle(Color.wiskPrimaryText)
                                .textSelection(.enabled)
                        }
                        .padding(Spacing.sm)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
                case .footnote(let label, let content):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text("[\(label)]")
                            .font(.caption.monospaced())
                            .foregroundStyle(.accent)
                        markdownText(content)
                            .font(bodyFont)
                            .foregroundStyle(Color.wiskSecondaryText)
                    }
                case .tableRow(let cells, let isDivider):
                    if !isDivider {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                markdownText(cell)
                                    .font(bodyFont)
                                    .foregroundStyle(Color.wiskPrimaryText)
                                    .padding(Spacing.xs)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.wiskInputBackground.opacity(0.7))
                                    .overlay {
                                        Rectangle()
                                            .stroke(Color.wiskTertiaryText.opacity(0.18), lineWidth: 0.5)
                                    }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    }
                case .paragraph(let content):
                    markdownText(content)
                        .font(bodyFont)
                        .foregroundStyle(Color.wiskPrimaryText)
                case .attachmentImage(let id, let altText):
                    if let attachment = attachments.first(where: { $0.id == id }) {
                        if attachment.isImage {
                            WiskAttachmentImageView(attachment: attachment, altText: altText)
                        } else {
                            WiskAttachmentFileRow(attachment: attachment, title: altText)
                        }
                    } else {
                        MissingAttachmentView(altText: altText)
                    }
                case .attachmentFile(let id, let title):
                    if let attachment = attachments.first(where: { $0.id == id }) {
                        WiskAttachmentFileRow(attachment: attachment, title: title)
                    } else {
                        MissingAttachmentView(altText: title)
                    }
                case .empty:
                    Spacer()
                        .frame(height: Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wisk.note.markdownPreview")
    }

    private var bodyFont: Font {
        fontManager.resolvedFont(size: baseFontSize ?? CGFloat(WiskEditorDefaults.defaultFontSize))
    }

    private var renderedLines: [MarkdownPreviewLine] {
        MarkdownPreviewLine.parse(text.components(separatedBy: .newlines))
    }

    private func headingFont(for level: Int) -> Font {
        let base = baseFontSize ?? CGFloat(WiskEditorDefaults.defaultFontSize)
        return fontManager.resolvedFont(
            size: WiskRichMarkdownDocument.fontSize(forHeadingLevel: level, baseFontSize: base),
            weight: WiskRichMarkdownDocument.swiftUIFontWeight(forHeadingLevel: level)
        )
    }

    private func markdownText(_ content: String) -> Text {
        styledMarkdownText(content)
    }

    private func styledMarkdownText(_ content: String) -> Text {
        var output = Text("")
        var cursor = content.startIndex

        while cursor < content.endIndex {
            if content[cursor...].hasPrefix("[["),
               let close = content[content.index(cursor, offsetBy: 2)...].range(of: "]]") {
                let segmentStart = content.index(cursor, offsetBy: 2)
                output = output
                    + Text(String(content[segmentStart..<close.lowerBound]))
                        .foregroundColor(.accentColor)
                        .underline()
                cursor = close.upperBound
            } else if content[cursor...].hasPrefix("[^"),
                      let close = content[content.index(cursor, offsetBy: 2)...].firstIndex(of: "]") {
                let segmentStart = content.index(cursor, offsetBy: 2)
                output = output
                    + Text(String(content[segmentStart..<close]))
                        .font(.caption)
                        .foregroundColor(.accentColor)
                cursor = content.index(after: close)
            } else if content[cursor...].hasPrefix("~~"),
               let close = content[content.index(cursor, offsetBy: 2)...].range(of: "~~") {
                let segmentStart = content.index(cursor, offsetBy: 2)
                output = output + plainMarkdownText(String(content[segmentStart..<close.lowerBound])).strikethrough()
                cursor = close.upperBound
            } else if content[cursor...].hasPrefix("=="),
                      let close = content[content.index(cursor, offsetBy: 2)...].range(of: "==") {
                let segmentStart = content.index(cursor, offsetBy: 2)
                output = output + plainMarkdownText(String(content[segmentStart..<close.lowerBound])).foregroundColor(.yellow)
                cursor = close.upperBound
            } else if content[cursor...].hasPrefix("<u>"),
                      let close = content[content.index(cursor, offsetBy: 3)...].range(of: "</u>") {
                let segmentStart = content.index(cursor, offsetBy: 3)
                output = output + plainMarkdownText(String(content[segmentStart..<close.lowerBound])).underline()
                cursor = close.upperBound
            } else {
                let nextToken = [
                    content[cursor...].range(of: "[[")?.lowerBound,
                    content[cursor...].range(of: "[^")?.lowerBound,
                    content[cursor...].range(of: "~~")?.lowerBound,
                    content[cursor...].range(of: "==")?.lowerBound,
                    content[cursor...].range(of: "<u>")?.lowerBound,
                ].compactMap { $0 }.min() ?? content.endIndex
                output = output + plainMarkdownText(String(content[cursor..<nextToken]))
                cursor = nextToken
            }
        }

        return output
    }

    private func plainMarkdownText(_ content: String) -> Text {
        Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
    }
}

enum MarkdownPreviewLine {
    case heading(level: Int, content: String)
    case checklist(isChecked: Bool, content: String)
    case bullet(String)
    case numbered(number: Int, content: String)
    case quote(String)
    case callout(kind: String, content: String)
    case separator
    case codeBlock(language: String?, content: String)
    case footnote(label: String, content: String)
    case tableRow(cells: [String], isDivider: Bool)
    case paragraph(String)
    case attachmentImage(id: UUID, altText: String)
    case attachmentFile(id: UUID, title: String)
    case empty

    static func parse(_ rawLines: [String]) -> [MarkdownPreviewLine] {
        var result: [MarkdownPreviewLine] = []
        var codeLanguage: String?
        var codeLines: [String] = []

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if codeLanguage == nil {
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? "" : language
                    codeLines = []
                } else {
                    result.append(.codeBlock(
                        language: codeLanguage?.isEmpty == true ? nil : codeLanguage,
                        content: codeLines.joined(separator: "\n")
                    ))
                    codeLanguage = nil
                    codeLines = []
                }
                continue
            }
            if codeLanguage != nil {
                codeLines.append(rawLine)
            } else {
                result.append(MarkdownPreviewLine(rawLine: rawLine))
            }
        }

        if codeLanguage != nil {
            result.append(.codeBlock(
                language: codeLanguage?.isEmpty == true ? nil : codeLanguage,
                content: codeLines.joined(separator: "\n")
            ))
        }
        return result
    }

    init(rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else {
            self = .empty
            return
        }

        if line == "---" {
            self = .separator
        } else if let callout = Self.callout(from: line) {
            self = callout
        } else if let footnote = Self.footnote(from: line) {
            self = footnote
        } else if let heading = Self.heading(from: line) {
            self = heading
        } else if let image = Self.attachmentImage(from: line) {
            self = image
        } else if let file = Self.attachmentFile(from: line) {
            self = file
        } else if line.hasPrefix("- [ ] ") {
            self = .checklist(isChecked: false, content: String(line.dropFirst(6)))
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            self = .checklist(isChecked: true, content: String(line.dropFirst(6)))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            self = .bullet(String(line.dropFirst(2)))
        } else if let numbered = Self.numbered(from: line) {
            self = numbered
        } else if line.hasPrefix("> ") {
            self = .quote(String(line.dropFirst(2)))
        } else if let tableRow = Self.tableRow(from: line) {
            self = tableRow
        } else {
            self = .paragraph(rawLine)
        }
    }

    private static func callout(from line: String) -> MarkdownPreviewLine? {
        guard line.hasPrefix("> [!"),
              let markerEnd = line.firstIndex(of: "]") else { return nil }
        let kindStart = line.index(line.startIndex, offsetBy: 4)
        let kind = String(line[kindStart..<markerEnd])
        let contentStart = line.index(after: markerEnd)
        let content = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
        return .callout(kind: kind.isEmpty ? "Note" : kind, content: content)
    }

    private static func footnote(from line: String) -> MarkdownPreviewLine? {
        guard line.hasPrefix("[^"),
              let markerEnd = line.range(of: "]:") else { return nil }
        let label = String(line[line.index(line.startIndex, offsetBy: 2)..<markerEnd.lowerBound])
        let content = String(line[markerEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return .footnote(label: label, content: content)
    }

    private static func heading(from line: String) -> MarkdownPreviewLine? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount),
              line.dropFirst(markerCount).first == " "
        else { return nil }

        let content = line.dropFirst(markerCount + 1).trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : .heading(level: markerCount, content: content)
    }

    private static func attachmentImage(from line: String) -> MarkdownPreviewLine? {
        guard line.hasPrefix("!["),
              let altEnd = line.firstIndex(of: "]"),
              line[line.index(after: altEnd)...].hasPrefix("(wisk-attachment://"),
              line.hasSuffix(")") else {
            return nil
        }

        let altText = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd])
        let urlStart = line.index(altEnd, offsetBy: 2)
        let urlEnd = line.index(before: line.endIndex)
        let rawURL = String(line[urlStart..<urlEnd])
        let prefix = "wisk-attachment://"
        guard rawURL.hasPrefix(prefix),
              let id = UUID(uuidString: String(rawURL.dropFirst(prefix.count))) else {
            return nil
        }
        return .attachmentImage(id: id, altText: altText.isEmpty ? "Image" : altText)
    }

    private static func attachmentFile(from line: String) -> MarkdownPreviewLine? {
        guard line.hasPrefix("["),
              let titleEnd = line.firstIndex(of: "]"),
              line[line.index(after: titleEnd)...].hasPrefix("(wisk-attachment://"),
              line.hasSuffix(")") else {
            return nil
        }

        let title = String(line[line.index(after: line.startIndex)..<titleEnd])
        let urlStart = line.index(titleEnd, offsetBy: 2)
        let urlEnd = line.index(before: line.endIndex)
        let rawURL = String(line[urlStart..<urlEnd])
        let prefix = "wisk-attachment://"
        guard rawURL.hasPrefix(prefix),
              let id = UUID(uuidString: String(rawURL.dropFirst(prefix.count))) else {
            return nil
        }
        return .attachmentFile(id: id, title: title.isEmpty ? "Attachment" : title)
    }

    private static func numbered(from line: String) -> MarkdownPreviewLine? {
        let components = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let number = Int(components[0].trimmingCharacters(in: .whitespaces)),
              components[1].hasPrefix(" ") else {
            return nil
        }
        return .numbered(number: number, content: String(components[1].dropFirst()))
    }

    private static func tableRow(from line: String) -> MarkdownPreviewLine? {
        guard line.contains("|") else { return nil }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "|").union(.whitespaces))
        let cells = trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count > 1 else { return nil }
        let isDivider = cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
        return .tableRow(cells: cells, isDivider: isDivider)
    }
}

private struct WiskAttachmentImageView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAttachmentService.self) private var attachmentService
    @Environment(SyncService.self) private var syncService

    let attachment: NoteAttachment
    let altText: String

    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var showingDetails = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            attachmentContent
            statusBadge
                .padding(8)
        }
        .task(id: attachment.id) {
            await loadImageIfNeeded()
        }
        .contextMenu {
            Menu("Image Size") {
                ForEach(WiskAttachmentImageSizeOption.allCases) { option in
                    Button {
                        updateDisplayWidth(option.displayWidth(for: attachment))
                    } label: {
                        if option.isSelected(for: attachment) {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
            Menu("Alignment") {
                Button("Leading") { updateAlignment(.leading) }
                Button("Center") { updateAlignment(.center) }
                Button("Trailing") { updateAlignment(.trailing) }
            }
            Button("Edit Name and Alt Text") {
                showingDetails = true
            }
            Button(attachment.isPreviewVisible ? "Hide Preview" : "Show Preview") {
                attachment.isPreviewVisible.toggle()
                persistMetadata()
            }
        }
        .sheet(isPresented: $showingDetails) {
            WiskAttachmentDetailsSheet(attachment: attachment) {
                persistMetadata()
            }
        }
        .accessibilityLabel(altText)
    }

    @ViewBuilder
    private var attachmentContent: some View {
        if let imageData,
           let image = platformImage(from: imageData) {
            sizedImage(image)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .strokeBorder(Color.wiskTertiaryText.opacity(0.25))
                }
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
        } else {
            MissingAttachmentView(altText: altText)
        }
    }

    @ViewBuilder
    private func sizedImage(_ image: Image) -> some View {
        if let displayWidth = attachment.displayWidth {
            image
                .resizable()
                .scaledToFit()
                .frame(width: CGFloat(displayWidth))
                .frame(maxWidth: .infinity, alignment: swiftUIAlignment)
        } else {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: swiftUIAlignment)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch attachment.uploadStatus {
        case .pending:
            Label("Uploading", systemImage: "icloud.and.arrow.up")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        case .failed:
            Button {
                Task {
                    if let noteID = attachment.note?.id {
                        await attachmentService.retryUpload(attachment, noteID: noteID)
                        imageData = await attachmentService.data(for: attachment)
                    }
                }
            } label: {
                Label("Retry", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
        case .uploaded:
            EmptyView()
        }
    }

    private func loadImageIfNeeded() async {
        guard imageData == nil, isLoading == false else { return }
        isLoading = true
        imageData = await attachmentService.data(for: attachment)
        isLoading = false
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }

    private var swiftUIAlignment: Alignment {
        switch attachment.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func updateDisplayWidth(_ width: Double?) {
        attachment.displayWidth = width
        persistMetadata()
    }

    private func updateAlignment(_ alignment: NoteAttachmentAlignment) {
        attachment.alignment = alignment
        persistMetadata()
    }

    private func persistMetadata() {
        attachment.updatedAt = Date()
        guard let note = attachment.note else { return }
        note.updatedAt = Date()
        note.syncStatus = .queued
        do {
            try modelContext.save()
            syncService.enqueue(note: note, context: modelContext)
        } catch {
            attachment.lastError = error.localizedDescription
        }
    }
}

struct WiskNoteEditorChrome: ViewModifier {
    let noteID: UUID
    @Binding var attachmentDetails: NoteAttachment?
    let onJump: () -> Void
    let onSaveAttachment: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: noteID) { _, _ in onJump() }
            .sheet(isPresented: Binding(
                get: { attachmentDetails != nil },
                set: { if !$0 { attachmentDetails = nil } }
            )) {
                if let attachment = attachmentDetails {
                    WiskAttachmentDetailsSheet(attachment: attachment, save: onSaveAttachment)
                }
            }
    }
}

struct WiskAttachmentDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: NoteAttachment
    let save: () -> Void

    @State private var fileName = ""
    @State private var altText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("File name", text: $fileName)
                TextField("Alt text", text: $altText, axis: .vertical)
                    .lineLimit(2...5)
                Text("Alt text should describe the useful content of the image for VoiceOver.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Attachment Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        attachment.fileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        attachment.altText = altText.trimmingCharacters(in: .whitespacesAndNewlines)
                        attachment.isFileNameUserProvided = true
                        attachment.isAltTextUserProvided = true
                        save()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 240)
        .onAppear {
            fileName = attachment.fileName
            altText = attachment.altText
        }
    }
}

private struct WiskAttachmentFileRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAttachmentService.self) private var attachmentService
    @Environment(SyncService.self) private var syncService

    let attachment: NoteAttachment
    let title: String

    @State private var isLoading = false
    @State private var fileData: Data?
    @State private var showingDetails = false

    var body: some View {
        Button {
            Task {
                await loadAttachment()
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if attachment.contentType == "application/pdf",
                   attachment.isPreviewVisible,
                   let thumbnail = pdfThumbnail {
                    thumbnail
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                        .accessibilityHidden(true)
                }

                HStack(spacing: Spacing.md) {
                    Image(systemName: fileIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accent)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.displayName.nilIfEmpty ?? title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.wiskPrimaryText)
                        Text(fileDetail)
                            .font(.caption)
                            .foregroundStyle(Color.wiskSecondaryText)
                    }

                    Spacer()

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: fileData == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                            .foregroundStyle(fileData == nil ? Color.wiskSecondaryText : Color.accent)
                    }
                }
            }
            .padding(Spacing.md)
            .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) {
            if attachment.contentType == "application/pdf", attachment.isPreviewVisible {
                await loadAttachment()
            }
        }
        .contextMenu {
            Button("Edit Name and Alt Text") {
                showingDetails = true
            }
            if attachment.contentType == "application/pdf" {
                Button(attachment.isPreviewVisible ? "Hide PDF Preview" : "Show PDF Preview") {
                    attachment.isPreviewVisible.toggle()
                    persistMetadata()
                    if attachment.isPreviewVisible {
                        Task { await loadAttachment() }
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            WiskAttachmentDetailsSheet(attachment: attachment) {
                persistMetadata()
            }
        }
        .accessibilityLabel("Attachment \(attachment.displayName.nilIfEmpty ?? title)")
    }

    private var fileIcon: String {
        switch attachment.contentType {
        case "application/pdf":
            return "doc.richtext"
        case let type where type.hasPrefix("text/"):
            return "doc.text"
        default:
            return "paperclip"
        }
    }

    private var fileDetail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file)
        if attachment.uploadStatus == .failed {
            return attachment.lastError ?? "Upload failed"
        }
        return [attachment.contentType, size].filter { !$0.isEmpty && $0 != "0 bytes" }.joined(separator: " • ")
    }

    private func loadAttachment() async {
        guard isLoading == false else { return }
        isLoading = true
        fileData = await attachmentService.data(for: attachment)
        isLoading = false
    }

    private var pdfThumbnail: Image? {
        guard let fileData,
              let document = PDFDocument(data: fileData),
              let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 640, height: 480), for: .mediaBox)
        #if os(iOS)
        return Image(uiImage: image)
        #elseif os(macOS)
        return Image(nsImage: image)
        #endif
    }

    private func persistMetadata() {
        attachment.updatedAt = Date()
        guard let note = attachment.note else { return }
        note.updatedAt = Date()
        note.syncStatus = .queued
        do {
            try modelContext.save()
            syncService.enqueue(note: note, context: modelContext)
        } catch {
            attachment.lastError = error.localizedDescription
        }
    }
}

private struct MissingAttachmentView: View {
    let altText: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "photo")
            Text(altText)
            Spacer()
            Text("Image unavailable")
                .font(.caption)
                .foregroundStyle(Color.wiskSecondaryText)
        }
        .padding(Spacing.md)
        .foregroundStyle(Color.wiskPrimaryText)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
    }
}

#if os(iOS)
private final class WiskPrintPageRenderer: UIPrintPageRenderer {
    private let page = CGRect(x: 0, y: 0, width: 612, height: 792)

    override var paperRect: CGRect { page }
    override var printableRect: CGRect { page.insetBy(dx: 36, dy: 36) }
}

private struct WiskActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct WiskDocumentScanner: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let completion: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: ([UIImage]) -> Void
        let dismiss: DismissAction

        init(completion: @escaping ([UIImage]) -> Void, dismiss: DismissAction) {
            self.completion = completion
            self.dismiss = dismiss
        }

        nonisolated func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pageData = (0..<scan.pageCount).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.95)
            }
            Task { @MainActor [weak self] in
                self?.completion(pageData.compactMap { UIImage(data: $0) })
                self?.dismiss()
            }
        }

        nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }

        nonisolated func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }
    }
}

private struct WiskSketchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var canvasView = PKCanvasView()

    let save: (Data) -> Void

    var body: some View {
        NavigationStack {
            PencilCanvasView(canvasView: canvasView)
                .background(Color.white)
                .navigationTitle("Sketch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Insert") {
                            insertSketch()
                        }
                        .accessibilityIdentifier("wisk.sketch.insertButton")
                    }
                }
        }
        .accessibilityIdentifier("wisk.sketch.sheet")
    }

    private func insertSketch() {
        let bounds = canvasView.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 1024, height: 768)
            : canvasView.bounds
        let image = canvasView.drawing.image(from: bounds, scale: UIScreen.main.scale)
        guard let data = image.pngData() else { return }
        save(data)
        dismiss()
    }
}

private struct PencilCanvasView: UIViewRepresentable {
    let canvasView: PKCanvasView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .white
        canvasView.tool = PKInkingTool(.pen, color: .label, width: 4)
        canvasView.accessibilityIdentifier = "wisk.sketch.canvas"
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        guard uiView.window != nil else { return }
        context.coordinator.showToolPicker(for: uiView)
    }

    @MainActor
    final class Coordinator {
        private var toolPicker: PKToolPicker?

        func showToolPicker(for canvasView: PKCanvasView) {
            if toolPicker == nil {
                let picker = PKToolPicker()
                picker.addObserver(canvasView)
                toolPicker = picker
            }
            toolPicker?.setVisible(true, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        }
    }
}
#endif

enum WiskProUpgradeContext: String, Codable, Hashable, Identifiable {
    case ai
    case buckets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai:
            return "Unlock Wisk AI"
        case .buckets:
            return "Unlock Wisk Buckets"
        }
    }

    var message: String {
        switch self {
        case .ai:
            return "Wisk Pro organizes notes, extracts tasks and reminders, and keeps review buckets in sync."
        case .buckets:
            return "Wisk Pro extracts suggestions from notes and sorts them into your bucket definitions."
        }
    }
}

struct ProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    let title: String
    let message: String

    var body: some View {
        NavigationStack {
            Form {
                ProUpgradeCard(title: title, message: message)
            }
            .formStyle(.grouped)
            .navigationTitle("Wisk Pro")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: proEntitlement.hasProAccess) { _, hasProAccess in
            if hasProAccess {
                dismiss()
            }
        }
    }
}

#if os(macOS)
struct WiskMacProUpgradeWindowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    let context: WiskProUpgradeContext

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: proEntitlement.hasProAccess ? "checkmark.seal.fill" : "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.accent)
                        .frame(width: 32, height: 32)
                        .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(proEntitlement.hasProAccess ? "Wisk Pro is active on this account." : context.message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                MacProUpgradeFeatureRow(
                    icon: "checklist.checked",
                    title: "Extract tasks",
                    detail: "Turn notes into tasks, reminders, learnings, and references."
                )
                MacProUpgradeFeatureRow(
                    icon: "tray.full",
                    title: "Review buckets",
                    detail: "Triage AI suggestions into the buckets you care about."
                )
                MacProUpgradeFeatureRow(
                    icon: "icloud.and.arrow.up",
                    title: "Sync intelligence",
                    detail: "Keep AI-created structure available across your devices."
                )
            }

            if proEntitlement.hasProAccess {
                Section {
                    Label("You already have Wisk Pro.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.accent)
                }
            } else {
                Section {
                    ForEach(WiskProPlan.allCases) { plan in
                        MacProUpgradePlanRow(
                            plan: plan,
                            product: product(for: plan),
                            isLoading: proEntitlement.isLoadingProducts
                        ) { product in
                            Task { await proEntitlement.purchase(product) }
                        }
                    }
                } header: {
                    Text("Choose a plan")
                } footer: {
                    if proEntitlement.sortedProducts.isEmpty {
                        Text("Prices shown are from the local StoreKit configuration. Purchases become available as soon as StoreKit finishes loading plans.")
                    }
                }

                Section {
                    Button {
                        Task { await proEntitlement.loadProducts() }
                    } label: {
                        Label(proEntitlement.sortedProducts.isEmpty ? "Load Plans" : "Refresh Plans", systemImage: "arrow.clockwise")
                    }
                    .disabled(proEntitlement.isLoadingProducts)

                    Button("Restore Purchases") {
                        Task { await proEntitlement.restorePurchases() }
                    }
                    .disabled(proEntitlement.isLoadingProducts)
                } footer: {
                    if let purchaseError = proEntitlement.purchaseError {
                        Label(purchaseError, systemImage: "exclamationmark.triangle")
                    }
                }
            }

            #if DEBUG
            Section {
                Toggle("Unlock Wisk Pro", isOn: Bindable(proEntitlement).debugForceProAccess)
                    .accessibilityIdentifier("wisk.mac.pro.debugUnlockPro")
                LabeledContent("AI API", value: WiskAPIConfiguration.resolvedBaseURL().absoluteString)
                    .textSelection(.enabled)
            } header: {
                Text("Developer")
            } footer: {
                Text("Unlock Pro bypasses StoreKit in Debug. AI parse defaults to hosted wisk-api; override with WISK_API_BASE_URL.")
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Wisk Pro")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 560, idealHeight: 560)
        .task {
            if proEntitlement.sortedProducts.isEmpty {
                await proEntitlement.loadProducts()
            }
        }
        .onChange(of: proEntitlement.hasProAccess) { _, hasProAccess in
            if hasProAccess {
                dismiss()
            }
        }
    }

    private func product(for plan: WiskProPlan) -> Product? {
        proEntitlement.sortedProducts.first { $0.id == plan.productID }
    }
}

private struct MacProUpgradeFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MacProUpgradePlanRow: View {
    let plan: WiskProPlan
    let product: Product?
    let isLoading: Bool
    let purchase: (Product) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(plan.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge = plan.badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.accent)
                    }
                }
                Text(plan.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(product?.displayPrice ?? plan.fallbackPrice)
                    .font(.system(size: 13, weight: .semibold))
                Text(plan.billingPeriod)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Choose") {
                if let product {
                    purchase(product)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(product == nil || isLoading)
            .help(product == nil ? "StoreKit is still loading this plan." : "Purchase \(plan.title)")
        }
        .padding(.vertical, 4)
    }
}
#endif

struct ProUpgradeCard: View {
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            header
            featureGrid

            if proEntitlement.hasProAccess {
                activeState
            } else {
                planSection
                footerActions
            }
        }
        .padding(.vertical, 4)
        .task {
            if proEntitlement.sortedProducts.isEmpty {
                await proEntitlement.loadProducts()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: proEntitlement.hasProAccess ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.accent)
                .frame(width: 28, height: 28)
                .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(proEntitlement.hasProAccess ? "Wisk Pro is active on this account." : message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var featureGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ProFeatureRow(icon: "checklist.checked", title: "Extract tasks", detail: "Turn notes into tasks, reminders, learnings, and references.")
            ProFeatureRow(icon: "tray.full", title: "Review buckets", detail: "Triage AI suggestions into the buckets you care about.")
            ProFeatureRow(icon: "icloud.and.arrow.up", title: "Sync intelligence", detail: "Keep AI-created structure available across your devices.")
        }
    }

    private var activeState: some View {
        Label("You already have Wisk Pro.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.accent)
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose a plan")
                    .font(.headline)
                    .foregroundStyle(Color.wiskPrimaryText)
                Spacer()
                if proEntitlement.isLoadingProducts {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ForEach(WiskProPlan.allCases) { plan in
                ProPlanRow(
                    plan: plan,
                    product: product(for: plan),
                    isLoading: proEntitlement.isLoadingProducts
                ) { product in
                    Task { await proEntitlement.purchase(product) }
                }
            }

            if proEntitlement.sortedProducts.isEmpty {
                Text("Prices shown are from the local StoreKit configuration. Purchases become available as soon as StoreKit finishes loading plans.")
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Button {
                    Task { await proEntitlement.loadProducts() }
                } label: {
                    Label(proEntitlement.sortedProducts.isEmpty ? "Load Plans" : "Refresh Plans", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(proEntitlement.isLoadingProducts)

                Button("Restore Purchases") {
                    Task { await proEntitlement.restorePurchases() }
                }
                .buttonStyle(.bordered)
                .disabled(proEntitlement.isLoadingProducts)
            }

            if let purchaseError = proEntitlement.purchaseError {
                Label(purchaseError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func product(for plan: WiskProPlan) -> Product? {
        proEntitlement.sortedProducts.first { $0.id == plan.productID }
    }
}

private struct ProFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wiskPrimaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProPlanRow: View {
    let plan: WiskProPlan
    let product: Product?
    let isLoading: Bool
    let purchase: (Product) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.sm) {
                    Text(plan.title)
                        .font(.headline)
                        .foregroundStyle(Color.wiskPrimaryText)
                    if let badge = plan.badge {
                        Text(badge)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text(plan.subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(product?.displayPrice ?? plan.fallbackPrice)
                    .font(.headline)
                    .foregroundStyle(Color.wiskPrimaryText)
                Text(plan.billingPeriod)
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
            }

            Button("Choose") {
                if let product {
                    purchase(product)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(product == nil || isLoading)
            .help(product == nil ? "StoreKit is still loading this plan." : "Purchase \(plan.title)")
        }
        .padding(Spacing.md)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .strokeBorder(plan.isHighlighted ? Color.accent.opacity(0.35) : Color.cardBorder, lineWidth: 0.8)
        )
    }
}

private enum WiskProPlan: CaseIterable, Identifiable {
    case yearly
    case monthly

    var id: String { productID }

    var productID: String {
        switch self {
        case .yearly: return WiskProEntitlementService.yearlyProductID
        case .monthly: return WiskProEntitlementService.monthlyProductID
        }
    }

    var title: String {
        switch self {
        case .yearly: return "Yearly"
        case .monthly: return "Monthly"
        }
    }

    var subtitle: String {
        switch self {
        case .yearly: return "Best for using Wisk AI every day."
        case .monthly: return "Flexible access while you try Pro."
        }
    }

    var fallbackPrice: String {
        switch self {
        case .yearly: return "$39.99"
        case .monthly: return "$4.99"
        }
    }

    var billingPeriod: String {
        switch self {
        case .yearly: return "per year"
        case .monthly: return "per month"
        }
    }

    var badge: String? {
        switch self {
        case .yearly: return "Save 33%"
        case .monthly: return nil
        }
    }

    var isHighlighted: Bool {
        self == .yearly
    }
}

private struct ParsedItemRow: View {
    let item: ParsedNoteItem
    let bucketChoices: [BucketChoice]
    let showBucketMenu: Bool
    let showSourceLink: Bool
    let accept: () -> Void
    let assignBucket: (String?) -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: item.itemType.iconName)
                    .foregroundStyle(item.itemType.tint)
                    .frame(width: 30, height: 30)
                    .background(item.itemType.tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.wiskPrimaryText)

                    Text(item.rawText)
                        .font(.caption)
                        .foregroundStyle(Color.wiskSecondaryText)
                        .lineLimit(3)

                    HStack(spacing: Spacing.sm) {
                        Text(item.itemType.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.itemType.tint)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(item.itemType.tint.opacity(0.12), in: Capsule())

                        Text(bucketChoices.first(where: { $0.bucketID == item.bucketId })?.name ?? "Unbucketed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.accent)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(Color.accent.opacity(0.12), in: Capsule())

                        if showBucketMenu {
                            Menu("Change") {
                                Button("No bucket") { assignBucket(nil) }
                                ForEach(bucketChoices) { choice in
                                    Button(choice.name) { assignBucket(choice.bucketID) }
                                }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }

                Spacer()

                VStack(spacing: Spacing.sm) {
                    Button(action: accept) {
                        Image(systemName: item.acceptedAt == nil ? "checkmark.circle" : "checkmark.circle.fill")
                    }
                    Button(action: reject) {
                        Image(systemName: "xmark.circle")
                    }
                }
                .foregroundStyle(.accent)
            }

            if showSourceLink, let note = item.note {
                NavigationLink(value: note.id) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.turn.down.right")
                        Text("Source note: \(note.title.nilIfEmpty ?? "Untitled")")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.wiskSecondaryText)
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.button))
    }
}

private struct AcceptedBucketGroup: Identifiable {
    let bucketID: String?
    let title: String
    let items: [ParsedNoteItem]

    var id: String {
        bucketID ?? "__none"
    }
}

private struct BucketChoice: Identifiable, Hashable {
    let bucketID: String
    let name: String

    var id: String { bucketID }

    static func choices(from buckets: [NoteBucket], fallbackItems: [ParsedNoteItem]) -> [BucketChoice] {
        let configured = buckets.map { bucket in
            BucketChoice(
                bucketID: bucket.id.uuidString,
                name: bucket.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled bucket"
            )
        }

        let dynamic = Set(fallbackItems.compactMap { item in
            item.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        })
        .map { id in
            BucketChoice(bucketID: id, name: title(for: id, buckets: buckets))
        }

        var merged = Dictionary(uniqueKeysWithValues: configured.map { ($0.bucketID, $0) })
        dynamic.forEach { merged[$0.bucketID] = $0 }

        return merged.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func title(for bucketID: String?, buckets: [NoteBucket]) -> String {
        guard let raw = bucketID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return "Unbucketed"
        }
        if let configured = buckets.first(where: { $0.id.uuidString == raw }) {
            return configured.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled bucket"
        }
        let normalized = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Unbucketed" : normalized.capitalized
    }
}

private struct InfoCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(value)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.accent)
            Text(title)
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
            Text(detail)
                .foregroundStyle(Color.wiskSecondaryText)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct StatusPill: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.wiskSecondaryText)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.button))
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

private extension ToolbarItemPlacement {
    static var wiskPrimaryAction: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

private struct WiskEditorToolbarRole: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbarRole(.editor)
        #else
        content
        #endif
    }
}

/// Editor toolbar buttons. On iOS the Bear glass chrome owns Edit/Preview and
/// Info, so the system toolbar group is empty; Mac keeps its nav buttons.
private struct WiskNoteEditorToolbarButtons: ViewModifier {
    let showsPreviewToggle: Bool
    let isPreviewing: Bool
    let onTogglePreview: () -> Void
    let onShowInfo: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content
        #else
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if showsPreviewToggle {
                    Button(isPreviewing ? "Edit" : "Preview", action: onTogglePreview)
                        .accessibilityIdentifier("wisk.note.previewToggle")
                }
                Button(action: onShowInfo) {
                    Label("Info", systemImage: "info.circle")
                }
                .accessibilityIdentifier("wisk.note.infoButton")
            }
        }
        #endif
    }
}

private extension View {
    @ViewBuilder
    func wiskPlainTextInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func wiskInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func wiskContentBottomPadding() -> some View {
        #if os(iOS)
        self.padding(.bottom, Spacing.lg)
        #else
        self.padding(.bottom, Spacing.lg)
        #endif
    }

    /// iOS only: the keyboard must never inset the editor ScrollView.
    /// SwiftUI's default keyboard avoidance scrolled the whole note viewport
    /// when the keyboard rose, then the editor's caret bridge scrolled it
    /// back to the tapped caret — the reported tap-to-focus bounce. With the
    /// keyboard ignored here, caret visibility above the keyboard is handled
    /// exclusively by the coordinator's keyboard-aware caret bridge.
    @ViewBuilder
    func wiskIgnoresKeyboardSafeArea() -> some View {
        #if os(iOS)
        self.ignoresSafeArea(.keyboard)
        #else
        self
        #endif
    }
}
