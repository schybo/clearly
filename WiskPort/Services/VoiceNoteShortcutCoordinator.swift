#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class VoiceNoteShortcutCoordinator {
    private(set) var requestToken = UUID()
    var isCapturePresented = false
    var statusMessage: String?

    func requestToggleFromShortcut() {
        requestToken = UUID()
    }

    func presentRecorder() {
        isCapturePresented = true
    }

    func dismissRecorder() {
        isCapturePresented = false
    }
}
#endif
