import Foundation
import SwiftData

enum DailyNoteParseStatus: String, Codable, CaseIterable, Sendable {
    case unparsed
    case parsing
    case parsed
    case failed
}

@Model
final class DailyNote {
    static let defaultParseVersion = 1
    static let defaultParseModel = "local-note-parser-v1"

    var id: UUID = UUID()
    var date: Date = Date()
    var rawText: String = ""
    var parseStatusRaw: String = DailyNoteParseStatus.unparsed.rawValue
    var parseVersion: Int = DailyNote.defaultParseVersion
    var parseModel: String = DailyNote.defaultParseModel
    var parseErrorMessage: String? = nil
    var parsedAt: Date? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ParsedNoteItem.dailyNote)
    var parsedItems: [ParsedNoteItem] = []

    var parseStatus: DailyNoteParseStatus {
        get { DailyNoteParseStatus(rawValue: parseStatusRaw) ?? .unparsed }
        set { parseStatusRaw = newValue.rawValue }
    }

    init(
        date: Date = Date(),
        rawText: String = "",
        parseStatus: DailyNoteParseStatus = .unparsed,
        parseVersion: Int = DailyNote.defaultParseVersion,
        parseModel: String = DailyNote.defaultParseModel
    ) {
        self.id = UUID()
        self.date = date
        self.rawText = rawText
        self.parseStatusRaw = parseStatus.rawValue
        self.parseVersion = parseVersion
        self.parseModel = parseModel
        self.parseErrorMessage = nil
        self.parsedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.parsedItems = []
    }
}
