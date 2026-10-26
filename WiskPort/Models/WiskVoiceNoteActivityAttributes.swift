#if os(iOS)
import ActivityKit
import Foundation

struct WiskVoiceNoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let startedAt: Date
        let transcriptPreview: String
        let isStopping: Bool
    }

    let noteTitle: String
}
#endif
