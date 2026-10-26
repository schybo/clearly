import SwiftData
import SwiftUI

struct ContentView: View {
    #if os(iOS)
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncService.self) private var syncService
    @Environment(WiskAttachmentService.self) private var attachmentService
    @Environment(VoiceNoteShortcutCoordinator.self) private var voiceNoteCoordinator
    @State private var voiceNoteRecorder = VoiceNoteRecorder()
    #endif

    var body: some View {
        MainTabView()
            .tint(.accent)
            #if os(iOS)
            .sheet(isPresented: voiceNotePresentation) {
                VoiceNoteCaptureView(
                    recorder: voiceNoteRecorder,
                    saveAndDismiss: {
                        Task { await stopAndSaveVoiceNote() }
                    },
                    cancelAndDismiss: {
                        Task { await cancelVoiceNote() }
                    }
                )
            }
            .onChange(of: voiceNoteCoordinator.requestToken) { _, _ in
                Task { await handleVoiceNoteShortcutToggle() }
            }
            .task {
                await ingestShareInbox()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    Task {
                        await ingestShareInbox()
                        // Foregrounding must pull immediately — the 45s poll can
                        // otherwise leave a freshly pushed Mac edit invisible for
                        // up to a minute. Rate-limited full pull heals notes whose
                        // `updatedAt` was frozen in the past.
                        await syncService.syncNow(context: modelContext, fullPull: true)
                    }
                case .background, .inactive:
                    // The 45s poll usually never fires: iOS suspends the app within
                    // seconds of backgrounding, leaving committed edits queued until
                    // the next foregrounding. Push now, while the system still
                    // grants background runtime.
                    Task { await syncService.syncNow(context: modelContext) }
                default:
                    break
                }
            }
            #endif
    }

    #if os(iOS)
    private var voiceNotePresentation: Binding<Bool> {
        Binding(
            get: { voiceNoteCoordinator.isCapturePresented },
            set: { isPresented in
                if isPresented {
                    voiceNoteCoordinator.presentRecorder()
                } else {
                    Task { await cancelVoiceNote() }
                }
            }
        )
    }

    private func handleVoiceNoteShortcutToggle() async {
        if voiceNoteRecorder.isRecording {
            await stopAndSaveVoiceNote()
        } else {
            voiceNoteCoordinator.presentRecorder()
            await voiceNoteRecorder.start()
        }
    }

    private func stopAndSaveVoiceNote() async {
        await voiceNoteRecorder.stop(discardTranscript: false)
        let transcript = voiceNoteRecorder.trimmedTranscript
        guard !transcript.isEmpty else {
            voiceNoteCoordinator.statusMessage = "No speech was captured."
            voiceNoteCoordinator.dismissRecorder()
            voiceNoteRecorder.reset()
            return
        }

        let note = Note(
            title: VoiceNoteTitleGenerator.title(for: transcript),
            body: transcript,
            kind: .general
        )
        WiskAnalytics.track("voice_note_recorded", properties: [
            "transcript_length": String(transcript.count)
        ])
        note.snapshotIfNeeded(reason: "voice-note")
        modelContext.insert(note)
        syncService.enqueue(note: note, context: modelContext)
        Task {
            await syncService.syncNow(context: modelContext)
        }

        voiceNoteCoordinator.statusMessage = "Saved voice note."
        voiceNoteCoordinator.dismissRecorder()
        voiceNoteRecorder.reset()
    }

    private func cancelVoiceNote() async {
        await voiceNoteRecorder.stop(discardTranscript: true)
        voiceNoteCoordinator.dismissRecorder()
        voiceNoteRecorder.reset()
    }

    private func ingestShareInbox() async {
        _ = await WiskShareInboxImporter.ingestPendingItems(
            context: modelContext,
            attachmentService: attachmentService,
            syncService: syncService
        )
    }
    #endif
}
