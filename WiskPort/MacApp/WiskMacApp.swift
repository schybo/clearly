import FirebaseCore
import SwiftData
import SwiftUI
import AppKit

@main
struct WiskMacApp: App {
    @State private var runtime: WiskMacRuntime?
    @State private var proEntitlementService = WiskProEntitlementService()
    @State private var organizer = BackgroundNoteOrganizer()
    @State private var fontManager = WiskFontManager()
    @AppStorage("wisk.mac.appearance") private var appearanceRawValue = WiskAppearance.light.rawValue
    @AppStorage(WiskEditorDefaults.macFontSizeKey) private var editorFontSize = WiskEditorDefaults.defaultFontSize
    @AppStorage(WiskEditorDefaults.fontFamilyKey) private var editorFontFamilyRawValue = WiskEditorFontFamily.system.rawValue
    @AppStorage(WiskEditorDefaults.formattingControlsKey) private var formattingControlsEnabled = false
    @NSApplicationDelegateAdaptor(WiskMacAppDelegate.self) private var appDelegate
    @State private var clipboardController = ClipboardHistoryController()

    var body: some Scene {
        WindowGroup {
            WiskMacLaunchHost(
                runtime: $runtime,
                proEntitlementService: proEntitlementService,
                organizer: organizer,
                fontManager: fontManager,
                appearanceRawValue: appearanceRawValue
            )
            .environment(clipboardController)
            .onAppear {
                clipboardController.start()
            }
        }
        .defaultSize(width: 1120, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    NotificationCenter.default.post(name: .wiskNewNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New List") {
                    NotificationCenter.default.post(name: .wiskNewList, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])

                Menu("New Structured Note") {
                    ForEach(NoteStructuredSections.allTemplates()) { template in
                        Button(template.title) {
                            NotificationCenter.default.post(name: .wiskNewStructuredNote, object: template)
                        }
                    }
                    let savedTemplates = NoteStructuredSections.loadUserTemplates()
                    if !savedTemplates.isEmpty {
                        Divider()
                        Menu("Delete Saved Template") {
                            ForEach(savedTemplates) { template in
                                Button(template.title, role: .destructive) {
                                    NoteStructuredSections.deleteUserTemplate(id: template.id)
                                }
                            }
                        }
                    }
                }

                Button("New Structured Note from Daily Workflow") {
                    NotificationCenter.default.post(name: .wiskNewStructuredNote, object: NoteStructuredSections.defaultTemplate)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Tracker") {
                    NotificationCenter.default.post(name: .wiskNewTracker, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Import Markdown or TextBundle...") {
                    NotificationCenter.default.post(name: .wiskImportNote, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Import Notes from Simplenote...") {
                    NotificationCenter.default.post(name: .wiskImportSimplenote, object: nil)
                }

                Button("Import Simplenote JSON...") {
                    NotificationCenter.default.post(name: .wiskImportSimplenoteJSON, object: nil)
                }

                Button("Undo Last Simplenote Import") {
                    NotificationCenter.default.post(name: .wiskUndoSimplenoteImport, object: nil)
                }

                Button("Restore Simplenote Dates") {
                    NotificationCenter.default.post(name: .wiskRestoreSimplenoteDates, object: nil)
                }

                Button("Remove Duplicate Simplenote Notes") {
                    NotificationCenter.default.post(name: .wiskRemoveDuplicateSimplenoteNotes, object: nil)
                }

                Menu("Export Note") {
                    ForEach(WiskExportFormat.allCases) { format in
                        Button(format.title + "...") {
                            NotificationCenter.default.post(name: .wiskExportNote, object: format)
                        }
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                WiskFindCommandButton()
                WiskMultiCursorCommandButtons()

                Button("Command Palette") {
                    NotificationCenter.default.post(name: .wiskShowCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("Format") {
                Button("Bold") {
                    applyFormatting(.bold)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    applyFormatting(.italic)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Underline") {
                    applyFormatting(.underline)
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("Strikethrough") {
                    applyFormatting(.strikethrough)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("Highlight") {
                    applyFormatting(.highlight)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button("Heading") {
                    applyFormatting(.heading)
                }

                Button("Bulleted List") {
                    applyFormatting(.bullet)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("Numbered List") {
                    applyFormatting(.numberedList)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Button("Insert Checklist") {
                    applyFormatting(.checklist)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Quote") {
                    applyFormatting(.quote)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button("Code") {
                    applyFormatting(.code)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Link") {
                    applyFormatting(.link)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                Menu("Copy As") {
                    ForEach(WiskCopyAsFormat.allCases) { format in
                        Button(format.title) {
                            NotificationCenter.default.post(name: .wiskCopyAs, object: format)
                        }
                    }
                }

                Button("Toggle Markdown Preview") {
                    NotificationCenter.default.post(name: .wiskToggleMarkdownPreview, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Note") {
                Button("Review with Wisk") {
                    NotificationCenter.default.post(name: .wiskShowAI, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Organize") {
                    NotificationCenter.default.post(name: .wiskOrganizeNote, object: nil)
                }

                Button("Route") {
                    NotificationCenter.default.post(name: .wiskRouteNote, object: nil)
                }

                Button("Clean Up") {
                    NotificationCenter.default.post(name: .wiskCleanUpNote, object: nil)
                }

                Button("Collaborate") {
                    NotificationCenter.default.post(name: .wiskShowShare, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Archive Note") {
                    NotificationCenter.default.post(name: .wiskDeleteNote, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }

            CommandMenu("Wisk") {
                Button("Light Appearance") {
                    appearanceRawValue = WiskAppearance.light.rawValue
                }
                Button("Dark Appearance") {
                    appearanceRawValue = WiskAppearance.dark.rawValue
                }
                Button("System Appearance") {
                    appearanceRawValue = WiskAppearance.system.rawValue
                }
            }

            CommandMenu("Editor") {
                Menu("Default Font") {
                    ForEach(WiskEditorFontFamily.allCases) { fontFamily in
                        Button(fontFamily.title) {
                            editorFontFamilyRawValue = fontFamily.rawValue
                            fontManager.selectBuiltIn(fontFamily)
                        }
                    }
                }

                Toggle("Show Formatting Controls", isOn: $formattingControlsEnabled)

                Divider()

                Button("Bigger") {
                    editorFontSize = min(editorFontSize + 1, 30)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Smaller") {
                    editorFontSize = max(editorFontSize - 1, 11)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Font Size") {
                    editorFontSize = WiskEditorDefaults.defaultFontSize
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            WiskMacSettingsHost(
                runtime: $runtime,
                proEntitlementService: proEntitlementService,
                fontManager: fontManager
            )
            .environment(clipboardController)
            .onAppear {
                clipboardController.start()
            }
        }

        WindowGroup("Wisk Pro", id: "wisk-pro", for: WiskProUpgradeContext.self) { context in
            WiskMacProUpgradeWindowView(context: context.wrappedValue ?? .ai)
                .environment(proEntitlementService)
                .preferredColorScheme((WiskAppearance(rawValue: appearanceRawValue) ?? .light).colorScheme)
                .tint(.accent)
        }
        .defaultSize(width: 520, height: 560)
        .windowResizability(.contentSize)
    }

    private func applyFormatting(_ action: WiskMarkdownFormattingAction) {
        NotificationCenter.default.post(name: .wiskApplyFormatting, object: action)
    }
}

private final class WiskMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private struct WiskMacRuntime {
    let modelContainer: ModelContainer
    let authService: WiskAuthService
    let syncService: SyncService
    let profileService: WiskProfileService
    let attachmentService: WiskAttachmentService
    let parsingService: NoteParsingService

    static func boot() -> WiskMacRuntime {
        if FirebaseApp.app() == nil {
            guard let macConfigPath = Bundle.main.path(
                forResource: "GoogleService-Info-Mac",
                ofType: "plist"
            ), let macOptions = FirebaseOptions(contentsOfFile: macConfigPath) else {
                fatalError("WiskMac requires GoogleService-Info-Mac.plist")
            }
            FirebaseApp.configure(options: macOptions)
        }
        WiskDebugSyncConfiguration.configureFirebaseEmulatorsIfNeeded()
        let authService = WiskAuthService()
        let syncService = SyncService(authService: authService, defaults: WiskDebugSyncDefaults.make())
        return WiskMacRuntime(
            modelContainer: WiskModelContainer.makeOrFatal(),
            authService: authService,
            syncService: syncService,
            profileService: WiskProfileService(authService: authService),
            attachmentService: WiskAttachmentService(authService: authService),
            parsingService: NoteParsingService(authService: authService)
        )
    }
}

private struct WiskMacOpeningLibraryView: View {
    var body: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Opening your library…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening your library")
    }
}

@MainActor
private func bootWiskMacRuntimeIfNeeded(_ runtime: Binding<WiskMacRuntime?>) async {
    await Task.yield()
    guard runtime.wrappedValue == nil else { return }
        let booted = WiskMacRuntime.boot()
        NoteLibraryIndex.backfillIfNeeded(in: booted.modelContainer.mainContext)
        WiskByteSwapEscapeMigration.runIfNeeded(
            in: booted.modelContainer.mainContext,
            syncService: booted.syncService,
            defaults: WiskDebugSyncDefaults.make()
        )
    #if DEBUG
    if ProcessInfo.processInfo.environment["WISK_SYNC_TEST_HEADLESS"] == "1" {
        await WiskDebugSyncHarness.prepareIfNeeded(
            context: booted.modelContainer.mainContext,
            syncService: booted.syncService
        )
        NSApp.terminate(nil)
        return
    }
    #endif
    runtime.wrappedValue = booted
}

private struct WiskMacLaunchHost: View {
    @Binding var runtime: WiskMacRuntime?
    var proEntitlementService: WiskProEntitlementService
    var organizer: BackgroundNoteOrganizer
    var fontManager: WiskFontManager
    var appearanceRawValue: String

    var body: some View {
        Group {
            if let runtime {
                WiskMacAuthenticatedRootView()
                    .environment(proEntitlementService)
                    .environment(runtime.parsingService)
                    .environment(organizer)
                    .environment(runtime.authService)
                    .environment(runtime.syncService)
                    .environment(runtime.profileService)
                    .environment(runtime.attachmentService)
                    .environment(fontManager)
                    .modelContainer(runtime.modelContainer)
                    .task {
                        fontManager.configure()
                        await proEntitlementService.configure()
                    }
            } else {
                WiskMacOpeningLibraryView()
                    .task {
                        await bootWiskMacRuntimeIfNeeded($runtime)
                    }
            }
        }
        .preferredColorScheme((WiskAppearance(rawValue: appearanceRawValue) ?? .light).colorScheme)
        .tint(.accent)
    }
}

private struct WiskMacSettingsHost: View {
    @Binding var runtime: WiskMacRuntime?
    var proEntitlementService: WiskProEntitlementService
    var fontManager: WiskFontManager

    var body: some View {
        Group {
            if let runtime {
                WiskMacSettingsView()
                    .environment(proEntitlementService)
                    .environment(runtime.authService)
                    .environment(runtime.syncService)
                    .environment(runtime.profileService)
                    .environment(fontManager)
                    .modelContainer(runtime.modelContainer)
            } else {
                WiskMacOpeningLibraryView()
                    .task {
                        await bootWiskMacRuntimeIfNeeded($runtime)
                    }
            }
        }
    }
}

private struct WiskMacAuthenticatedRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAuthService.self) private var authService
    @Environment(SyncService.self) private var syncService
    @Environment(WiskProfileService.self) private var profileService
    @Environment(WiskFontManager.self) private var fontManager
    @Environment(WiskAttachmentService.self) private var attachmentService

    private var bypassAuthForUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["WISK_BYPASS_AUTH"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if WiskDebugSyncHarness.isActive {
                MacContentView()
            } else if bypassAuthForUITesting {
                MacContentView()
                    .task {
                        NoteLibraryIndex.backfillIfNeeded(in: modelContext)
                        _ = try? NoteBucketSeedService.ensureDefaultTasksBucket(context: modelContext)
                    }
            } else if authService.isLoading {
                ProgressView("Loading Wisk...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else if authService.isSignedIn {
                MacContentView()
                    .task {
                        profileService.startObserving()
                        let handledDebugSync = await WiskDebugSyncHarness.prepareIfNeeded(context: modelContext, syncService: syncService)
                        if !handledDebugSync {
                            _ = try? NoteBucketSeedService.ensureDefaultTasksBucket(context: modelContext)
                            // Let the note list paint before sync mutates hundreds of notes and
                            // invalidates SwiftData @Query observation on the main thread.
                            syncService.hydrateAccountSyncWatermark()
                            let hadCompletedSync = syncService.hasCompletedAccountSync
                            try? await Task.sleep(for: .milliseconds(300))
                            // Launch does one rate-limited full pull: the persisted
                            // watermark only self-heals frozen-`updatedAt` notes
                            // through a `since: nil` fetch.
                            await syncService.syncNow(context: modelContext, fullPull: true)
                            await attachmentService.healPendingUploads(context: modelContext, syncService: syncService)
                            WiskHelperNoteSeedService.seedIfNeeded(
                                context: modelContext,
                                syncService: syncService,
                                uid: authService.firebaseUID,
                                hadCompletedSync: hadCompletedSync
                            )
                            await syncService.startAutomaticSync(context: modelContext)
                        }
                    }
            } else {
                AuthGateView()
                    .onAppear {
                        profileService.stopObserving()
                    }
            }
        }
        .onChange(of: authService.firebaseUID) { _, _ in
            profileService.startObserving()
        }
        .onChange(of: profileService.syncedGoogleFont) { _, googleFont in
            Task {
                await fontManager.applySyncedGoogleFontIfAppropriate(googleFont)
            }
        }
        .onOpenURL { url in
            _ = authService.handleOpenURL(url)
        }
    }
}

private struct WiskFindCommandButton: View {
    @FocusedValue(\.wiskEditorBodyFocused) private var editorBodyFocused

    private var findInNote: Bool {
        editorBodyFocused == true || WiskMacBodyEditorFocus.isFirstResponder
    }

    var body: some View {
        Button(findInNote ? "Find in Note" : "Find Notes") {
            if findInNote {
                NotificationCenter.default.post(name: .wiskFindInNote, object: nil)
            } else {
                NotificationCenter.default.post(name: .wiskFocusSearch, object: nil)
            }
        }
        .keyboardShortcut("f", modifiers: .command)
    }
}

private struct WiskMultiCursorCommandButtons: View {
    @FocusedValue(\.wiskEditorBodyFocused) private var editorBodyFocused

    private var editorFocused: Bool {
        editorBodyFocused == true || WiskMacBodyEditorFocus.isFirstResponder
    }

    var body: some View {
        Button("Split Selection into Lines") {
            NotificationCenter.default.post(name: .wiskSplitSelectionIntoLines, object: nil)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!editorFocused)

        Button("Select Next Occurrence") {
            NotificationCenter.default.post(name: .wiskSelectNextOccurrence, object: nil)
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(!editorFocused)

        Button("Select All Occurrences") {
            NotificationCenter.default.post(name: .wiskSelectAllOccurrences, object: nil)
        }
        .keyboardShortcut("g", modifiers: [.command, .control])
        .disabled(!editorFocused)
    }
}

/// One-time migration repairing notes whose text was corrupted by a tool that
/// byte-swapped UTF-16 code units into literal `\uXXXX` escapes
/// (`>` stored as `\u3e00`). Snapshots each note before rewriting and enqueues
/// the repaired copies so Firestore receives the fix.
@MainActor
enum WiskByteSwapEscapeMigration {
    static let defaultsKey = "wisk.migration.byteSwapEscapeRepair"
    private static let snapshotReason = "byte-swap-escape-repair"

    @discardableResult
    static func runIfNeeded(
        in context: ModelContext,
        syncService: SyncService,
        defaults: UserDefaults = WiskDebugSyncDefaults.make()
    ) -> Bool {
        guard defaults.object(forKey: defaultsKey) == nil else { return false }

        do {
            let notes = try context.fetch(FetchDescriptor<Note>())
            var repairedNotes: [Note] = []
            for note in notes where note.deletedAt == nil {
                let repairedBody = WiskByteSwappedEscapeRepair.repaired(note.body)
                let repairedTitle = WiskByteSwappedEscapeRepair.repaired(note.title)
                guard repairedBody != note.body || repairedTitle != note.title else { continue }
                note.snapshotIfNeeded(reason: snapshotReason)
                note.body = repairedBody
                note.title = repairedTitle
                note.updatedAt = Date()
                repairedNotes.append(note)
            }
            guard repairedNotes.isEmpty == false else {
                defaults.set(true, forKey: defaultsKey)
                return false
            }

            try context.save()
            syncService.enqueue(notes: repairedNotes, context: context)
            defaults.set(true, forKey: defaultsKey)
            NSLog("WiskMac repaired \(repairedNotes.count) byte-swapped escape notes and enqueued them for sync.")
            return true
        } catch {
            // Leave the flag unset so the migration retries on next launch.
            NSLog("WiskMac byte-swap escape repair failed: \(error.localizedDescription)")
            return false
        }
    }
}
