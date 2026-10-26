import FirebaseCore
#if os(iOS)
import AppIntents
#endif
import SwiftData
import SwiftUI

@main
struct WiskApp: App {
    @State private var proEntitlementService = WiskProEntitlementService()
    @State private var parsingService: NoteParsingService
    @State private var organizer = BackgroundNoteOrganizer()
    @State private var authService: WiskAuthService
    @State private var syncService: SyncService
    @State private var profileService: WiskProfileService
    @State private var attachmentService: WiskAttachmentService
    @State private var fontManager = WiskFontManager()
    private let modelContainer: ModelContainer
    #if os(iOS)
    @State private var voiceNoteCoordinator: VoiceNoteShortcutCoordinator
    #endif

    init() {
        #if DEV_BUILD
        guard let devConfigPath = Bundle.main.path(
            forResource: "GoogleService-Info-Dev",
            ofType: "plist"
        ), let devOptions = FirebaseOptions(contentsOfFile: devConfigPath) else {
            fatalError("WiskDev requires GoogleService-Info-Dev.plist")
        }
        FirebaseApp.configure(options: devOptions)
        #else
        FirebaseApp.configure()
        #endif
        WiskAnalytics.track("app_opened")
        WiskDebugSyncConfiguration.configureFirebaseEmulatorsIfNeeded()
        let authService = WiskAuthService()
        _authService = State(initialValue: authService)
        _syncService = State(initialValue: SyncService(authService: authService, defaults: WiskDebugSyncDefaults.make()))
        _profileService = State(initialValue: WiskProfileService(authService: authService))
        _attachmentService = State(initialValue: WiskAttachmentService(authService: authService))
        _parsingService = State(initialValue: NoteParsingService(authService: authService))
        #if os(iOS)
        let voiceNoteCoordinator = VoiceNoteShortcutCoordinator()
        _voiceNoteCoordinator = State(initialValue: voiceNoteCoordinator)
        AppDependencyManager.shared.add(dependency: voiceNoteCoordinator)
        #endif
        modelContainer = WiskModelContainer.makeOrFatal()
    }

    var body: some Scene {
        WindowGroup {
            WiskAuthenticatedRootView()
                .environment(proEntitlementService)
                .environment(parsingService)
                .environment(organizer)
                .environment(authService)
                .environment(syncService)
                .environment(profileService)
                .environment(attachmentService)
                .environment(fontManager)
                #if os(iOS)
                .environment(voiceNoteCoordinator)
                #endif
                .task {
                    fontManager.configure()
                    await proEntitlementService.configure()
                }
        }
        .modelContainer(modelContainer)
    }
}

private struct WiskAuthenticatedRootView: View {
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
                ContentView()
                    .task {
                        NoteLibraryIndex.backfillIfNeeded(in: modelContext)
                        await WiskDebugSyncHarness.prepareIfNeeded(context: modelContext, syncService: syncService)
                    }
            } else if bypassAuthForUITesting {
                ContentView()
                    .task {
                        NoteLibraryIndex.backfillIfNeeded(in: modelContext)
                        _ = try? NoteBucketSeedService.ensureDefaultTasksBucket(context: modelContext)
                    }
            } else if authService.isLoading {
                ProgressView("Loading Wisk...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authService.isSignedIn {
                ContentView()
                    .task {
                        profileService.startObserving()
                        syncService.hydrateAccountSyncWatermark()
                        // Let the existing library paint before sync mutates notes and
                        // invalidates the SwiftData query on the main thread.
                        await Task.yield()
                        let handledDebugSync = await WiskDebugSyncHarness.prepareIfNeeded(context: modelContext, syncService: syncService)
                        if !handledDebugSync {
                            _ = try? NoteBucketSeedService.ensureDefaultTasksBucket(context: modelContext)
                            syncService.hydrateAccountSyncWatermark()
                            let hadCompletedSync = syncService.hasCompletedAccountSync
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
        .onChange(of: profileService.syncedGoogleFont) { _, googleFont in
            Task {
                await fontManager.applySyncedGoogleFontIfAppropriate(googleFont)
            }
        }
        .onOpenURL { url in
            if url.scheme == "wisk" || url.scheme == "wisk-dev" {
                return
            }
            _ = authService.handleOpenURL(url)
        }
    }
}
