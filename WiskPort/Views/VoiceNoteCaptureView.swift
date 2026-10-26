#if os(iOS)
import SwiftUI

struct VoiceNoteCaptureView: View {
    let recorder: VoiceNoteRecorder
    let saveAndDismiss: () -> Void
    let cancelAndDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wiskCanvasBackground
                    .ignoresSafeArea()

                VStack(spacing: Spacing.xl) {
                    recordingGlyph
                    statusText
                    transcriptCard
                    controls
                }
                .padding(Spacing.xl)
                .readableWidth()
            }
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancelAndDismiss)
                        .accessibilityIdentifier("wisk.voiceNote.cancelButton")
                }
            }
            .task {
                if recorder.state == .idle, recorder.trimmedTranscript.isEmpty {
                    await recorder.start()
                }
            }
        }
    }

    private var recordingGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.accentGlow)
                .frame(width: 126, height: 126)
                .scaleEffect(recorder.isRecording ? 1.08 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: recorder.isRecording)

            Image(systemName: recorder.isRecording ? "mic.fill" : "waveform")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.accent)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusText: some View {
        switch recorder.state {
        case .idle:
            Text(recorder.didAutoStop ? "Recording paused after one minute" : "Ready")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
        case .requestingPermission:
            Text("Checking microphone access...")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
        case .recording:
            Text("Listening...")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
        case .stopping:
            Text("Finishing transcript...")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)
        case .failed(let message):
            VStack(spacing: Spacing.sm) {
                Text("Voice note unavailable")
                    .font(AppFont.sectionTitle)
                    .foregroundStyle(Color.wiskPrimaryText)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.wiskSecondaryText)
            }
        }
    }

    private var transcriptCard: some View {
        ScrollView {
            Text(recorder.trimmedTranscript.isEmpty ? "Your transcript will appear here as you speak." : recorder.transcript)
                .font(.body)
                .foregroundStyle(recorder.trimmedTranscript.isEmpty ? Color.wiskTertiaryText : Color.wiskPrimaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.lg)
        }
        .frame(minHeight: 180, maxHeight: 280)
        .background(Color.wiskInputBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(Color.cardBorder, lineWidth: 0.6)
                .allowsHitTesting(false)
        )
        .accessibilityIdentifier("wisk.voiceNote.transcript")
    }

    private var controls: some View {
        VStack(spacing: Spacing.md) {
            Button {
                if recorder.isRecording {
                    saveAndDismiss()
                } else if recorder.trimmedTranscript.isEmpty {
                    Task { await recorder.start() }
                } else {
                    saveAndDismiss()
                }
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(recorder.state == .requestingPermission || recorder.state == .stopping)
            .accessibilityIdentifier("wisk.voiceNote.primaryButton")

            if !recorder.trimmedTranscript.isEmpty || recorder.isRecording {
                Button("Discard", role: .destructive, action: cancelAndDismiss)
                    .accessibilityIdentifier("wisk.voiceNote.discardButton")
            }
        }
    }

    private var primaryActionTitle: String {
        if recorder.isRecording { return "Stop and Save" }
        if recorder.trimmedTranscript.isEmpty { return "Try Again" }
        return "Save Note"
    }

    private var primaryActionIcon: String {
        recorder.isRecording ? "stop.circle.fill" : "checkmark.circle.fill"
    }
}
#endif
