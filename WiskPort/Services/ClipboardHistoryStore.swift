import Foundation
import Observation

enum ClipboardHistoryPreferences {
    static let recordingEnabledKey = "wisk.mac.clipboard.recordingEnabled"
    static let historyLimitKey = "wisk.mac.clipboard.historyLimit"
    static let pasteAsPlainTextKey = "wisk.mac.clipboard.pasteAsPlainText"
    static let directPasteKey = "wisk.mac.clipboard.directPaste"
    static let defaultHistoryLimit = 300
    static let minimumHistoryLimit = 50
    static let maximumHistoryLimit = 2000
    static let maximumClipBytes = 1_048_576
    static let pollInterval: TimeInterval = 0.5
    static let fileName = "clipboard-history.json"

    static func clampedLimit(_ value: Int) -> Int {
        min(maximumHistoryLimit, max(minimumHistoryLimit, value))
    }

    static func storedRecordingEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: recordingEnabledKey) != nil else { return true }
        return defaults.bool(forKey: recordingEnabledKey)
    }

    static func storedHistoryLimit(defaults: UserDefaults = .standard) -> Int {
        let raw = defaults.object(forKey: historyLimitKey) as? Int ?? defaultHistoryLimit
        return clampedLimit(raw)
    }

    static func defaultFileURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.schybo.wisk.mac"
    ) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

struct ClipboardCapture: Equatable, Sendable {
    var plainText: String
    var rtfData: Data?
    var isConcealed: Bool
    var isTransient: Bool
    var sourceAppName: String?
}

struct ClipboardClip: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var plainText: String
    var rtfData: Data?
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool
    var sourceAppName: String?
}

enum ClipboardRecordResult: Equatable, Sendable {
    case recorded
    case refreshed
    case skippedSensitive
    case skippedEmpty
    case skippedTooLarge
}

private struct ClipboardHistoryFile: Codable {
    var clips: [ClipboardClip]
}

@MainActor
@Observable
final class ClipboardHistoryStore {
    private(set) var clips: [ClipboardClip] = []
    private(set) var historyLimit: Int
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL,
        historyLimit: Int = ClipboardHistoryPreferences.defaultHistoryLimit,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.historyLimit = max(historyLimit, 1)
        clips = Self.load(from: fileURL)
        if clips.count > self.historyLimit {
            clips = Self.trimmed(clips, limit: self.historyLimit)
            persist()
        }
    }

    func record(_ capture: ClipboardCapture, now: Date = .now) -> ClipboardRecordResult {
        if capture.isConcealed || capture.isTransient {
            return .skippedSensitive
        }
        let plainText = capture.plainText
        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skippedEmpty
        }
        let textBytes = plainText.utf8.count
        if textBytes > ClipboardHistoryPreferences.maximumClipBytes {
            return .skippedTooLarge
        }
        let rtfData: Data?
        if let captureRTF = capture.rtfData, textBytes + captureRTF.count > ClipboardHistoryPreferences.maximumClipBytes {
            rtfData = nil
        } else {
            rtfData = capture.rtfData
        }

        var updated = clips
        if let index = updated.firstIndex(where: { $0.plainText == plainText }) {
            updated[index].rtfData = rtfData
            updated[index].updatedAt = now
            updated[index].sourceAppName = capture.sourceAppName
            if !updated[index].pinned {
                let clip = updated.remove(at: index)
                let insertAt = updated.firstIndex(where: { !$0.pinned }) ?? updated.endIndex
                updated.insert(clip, at: insertAt)
            }
            clips = Self.trimmed(updated, limit: historyLimit)
            persist()
            return .refreshed
        }

        let clip = ClipboardClip(
            id: UUID(),
            plainText: plainText,
            rtfData: rtfData,
            createdAt: now,
            updatedAt: now,
            pinned: false,
            sourceAppName: capture.sourceAppName
        )
        let insertAt = updated.firstIndex(where: { !$0.pinned }) ?? updated.endIndex
        updated.insert(clip, at: insertAt)
        clips = Self.trimmed(updated, limit: historyLimit)
        persist()
        return .recorded
    }

    func search(_ query: String) -> [ClipboardClip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clips }
        return clips.filter { $0.plainText.localizedStandardContains(trimmed) }
    }

    func setPinned(_ pinned: Bool, id: UUID, now: Date = .now) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        guard clips[index].pinned != pinned else { return }
        var updated = clips
        var clip = updated.remove(at: index)
        clip.pinned = pinned
        clip.updatedAt = now
        if pinned {
            updated.insert(clip, at: 0)
        } else {
            let insertAt = updated.firstIndex(where: { !$0.pinned }) ?? updated.endIndex
            updated.insert(clip, at: insertAt)
        }
        clips = updated
        persist()
    }

    func delete(id: UUID) {
        guard clips.contains(where: { $0.id == id }) else { return }
        clips.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        guard !clips.isEmpty else { return }
        clips = []
        persist()
    }

    func setHistoryLimit(_ limit: Int) {
        let clamped = max(limit, 1)
        historyLimit = clamped
        let trimmed = Self.trimmed(clips, limit: clamped)
        guard trimmed != clips else { return }
        clips = trimmed
        persist()
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ClipboardHistoryFile(clips: clips))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep the in-memory list when the file cannot be written.
        }
    }

    private static func load(from fileURL: URL) -> [ClipboardClip] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ClipboardHistoryFile.self, from: data).clips) ?? []
    }

    private static func trimmed(_ clips: [ClipboardClip], limit: Int) -> [ClipboardClip] {
        var updated = clips
        while updated.count > limit {
            if let index = updated.lastIndex(where: { !$0.pinned }) {
                updated.remove(at: index)
            } else {
                updated.removeLast()
            }
        }
        return updated
    }
}
