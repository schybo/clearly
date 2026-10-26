import Foundation
import Observation

@MainActor
@Observable
final class BackgroundNoteOrganizer {
    enum State: Equatable {
        case idle
        case scheduled
        case organizing
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func schedule(
        noteID: UUID,
        title: String,
        body: String,
        bucketDefinitions: [NoteBucket] = [],
        delay: Duration = .seconds(1),
        parse: @escaping @MainActor (ParsedDailyNoteDraft, String) -> Void,
        aiService: NoteParsingService
    ) {
        task?.cancel()
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .idle
            return
        }

        state = .scheduled
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.state = .organizing
                let combined = Self.combinedText(title: title, body: body)
                do {
                    let response = try await aiService.parse(note: combined, bucketDefinitions: bucketDefinitions)
                    guard !Task.isCancelled else { return }
                    parse(response.asDraft(rawText: combined, fallbackDate: Date()), "wisk-pro-ai")
                    self?.state = .idle
                } catch {
                    self?.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            } catch {
                if !Task.isCancelled {
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    nonisolated static func combinedText(title: String, body: String) -> String {
        [title, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

@MainActor
enum WiskNoteOrganizationPhase: Equatable {
    case idle
    case organizing
    case failed(String)

    init(organizer: BackgroundNoteOrganizer.State, parsing: NoteParsingService.State) {
        if case .parsing = parsing {
            self = .organizing
            return
        }

        switch organizer {
        case .scheduled, .organizing:
            self = .organizing
            return
        case .failed(let message):
            self = .failed(message)
            return
        case .idle:
            break
        }

        if case .error(let error) = parsing {
            self = .failed(error.errorDescription ?? "Could not reach Wisk AI. Check your connection and try again.")
            return
        }

        self = .idle
    }

    var isOrganizing: Bool {
        if case .organizing = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
