#if os(iOS)
import Foundation

enum PlaudRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case us
    case jp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .us: "US"
        case .jp: "Japan"
        }
    }

    var host: String {
        switch self {
        case .us: "platform-us.plaud.ai"
        case .jp: "platform-jp.plaud.ai"
        }
    }
}

enum PlaudImportNoteType: String, CaseIterable, Identifiable, Sendable {
    case general
    case structured
    case list
    case tracker
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General note"
        case .structured: "Structured meeting note"
        case .list: "Checklist"
        case .tracker: "Tracker"
        case .daily: "Daily note"
        }
    }
}

struct PlaudAccessToken: Codable, Equatable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let region: PlaudRegion
    let regionHost: String

    var expiresAt: Date {
        Date().addingTimeInterval(TimeInterval(expiresIn))
    }
}

struct PlaudDiscoveredDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let serialNumber: String
    let rssi: Int

    init(name: String, serialNumber: String, rssi: Int) {
        self.id = serialNumber
        self.name = name
        self.serialNumber = serialNumber
        self.rssi = rssi
    }
}

struct PlaudRecordingFile: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: Int
    let deviceSerialNumber: String?
    let sizeBytes: Int
    let duration: TimeInterval?
    let createdAt: Date
    var localAudioURL: URL?

    init(
        sessionId: Int,
        deviceSerialNumber: String? = nil,
        sizeBytes: Int = 0,
        duration: TimeInterval? = nil,
        createdAt: Date? = nil,
        localAudioURL: URL? = nil
    ) {
        self.id = String(sessionId)
        self.sessionId = sessionId
        self.deviceSerialNumber = deviceSerialNumber
        self.sizeBytes = sizeBytes
        self.duration = duration
        self.createdAt = createdAt ?? Date(timeIntervalSince1970: TimeInterval(sessionId))
        self.localAudioURL = localAudioURL
    }
}

struct PlaudTranscriptSegment: Codable, Equatable, Sendable {
    let speaker: String?
    let start: TimeInterval?
    let end: TimeInterval?
    let text: String
}

struct PlaudTranscript: Codable, Equatable, Sendable {
    let text: String
    let language: String?
    let duration: TimeInterval?
    let segments: [PlaudTranscriptSegment]
}

struct PlaudImportedNoteContext: Equatable, Sendable {
    let recording: PlaudRecordingFile
    let transcript: PlaudTranscript
    let noteType: PlaudImportNoteType
    let bucketID: UUID?
    let bucketName: String?
    let importedAt: Date
}
#endif
