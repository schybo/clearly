#if os(iOS)
import ActivityKit
import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class VoiceNoteRecorder {
    enum RecordingState: Equatable {
        case idle
        case requestingPermission
        case recording
        case stopping
        case failed(String)
    }

    private(set) var state: RecordingState = .idle
    private(set) var transcript = ""
    private(set) var startedAt: Date?
    private(set) var didAutoStop = false

    @ObservationIgnored private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let activityManager = VoiceNoteActivityManager()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?

    var isRecording: Bool {
        state == .recording
    }

    var trimmedTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() async {
        guard state != .recording, state != .requestingPermission else { return }
        didAutoStop = false
        state = .requestingPermission

        do {
            try await requestPermissions()
            try startRecordingSession()
            state = .recording
        } catch {
            await stop(discardTranscript: false)
            state = .failed(Self.message(for: error))
        }
    }

    func stop(discardTranscript: Bool = false) async {
        autoStopTask?.cancel()
        autoStopTask = nil

        if state == .recording || state == .requestingPermission {
            state = .stopping
        }

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        activityManager.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if discardTranscript {
            transcript = ""
        }
        startedAt = nil
        if case .failed = state {
            return
        }
        state = .idle
    }

    func reset() {
        transcript = ""
        didAutoStop = false
        state = .idle
    }

    private func requestPermissions() async throws {
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard microphoneAllowed else {
            throw VoiceNoteRecorderError.microphoneDenied
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw VoiceNoteRecorderError.speechDenied
        }
        guard speechRecognizer?.isAvailable == true else {
            throw VoiceNoteRecorderError.speechUnavailable
        }
    }

    private func startRecordingSession() throws {
        transcript = ""
        let startedAt = Date()
        self.startedAt = startedAt

        try activityManager.start(startedAt: startedAt)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            let formattedTranscript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognition(
                    transcript: formattedTranscript,
                    isFinal: isFinal,
                    errorDescription: errorDescription
                )
            }
        }

        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.state == .recording else { return }
            self.didAutoStop = true
            await self.stop(discardTranscript: false)
        }
    }

    private func handleRecognition(transcript: String?, isFinal: Bool, errorDescription: String?) {
        if let transcript {
            self.transcript = transcript
            activityManager.update(startedAt: startedAt ?? Date(), transcript: transcript, isStopping: isFinal)
        }

        guard let errorDescription, !errorDescription.isEmpty, !isFinal else { return }
        state = .failed(errorDescription)
        Task { @MainActor in
            await stop(discardTranscript: false)
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private enum VoiceNoteRecorderError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case speechUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Wisk needs microphone access to record a voice note."
        case .speechDenied:
            return "Wisk needs Speech Recognition access to transcribe a voice note."
        case .speechUnavailable:
            return "Speech recognition is not available right now. Try again in a moment."
        }
    }
}

@MainActor
private final class VoiceNoteActivityManager {
    private var currentActivity: Activity<WiskVoiceNoteActivityAttributes>?

    func start(startedAt: Date) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw VoiceNoteActivityError.activitiesDisabled
        }

        let attributes = WiskVoiceNoteActivityAttributes(noteTitle: "Voice note")
        let state = WiskVoiceNoteActivityAttributes.ContentState(
            startedAt: startedAt,
            transcriptPreview: "",
            isStopping: false
        )

        currentActivity = try Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func update(startedAt: Date, transcript: String, isStopping: Bool) {
        guard let activity = currentActivity else { return }
        let preview = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = WiskVoiceNoteActivityAttributes.ContentState(
            startedAt: startedAt,
            transcriptPreview: String(preview.prefix(80)),
            isStopping: isStopping
        )

        Task {
            await activity.update(ActivityContent(state: content, staleDate: nil))
        }
    }

    func end() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

private enum VoiceNoteActivityError: LocalizedError {
    case activitiesDisabled

    var errorDescription: String? {
        "Enable Live Activities for Wisk before recording from the Action Button."
    }
}
#endif
