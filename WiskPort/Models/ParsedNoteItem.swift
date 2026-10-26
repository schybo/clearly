import Foundation
import SwiftData

enum ParsedNoteItemType: String, Codable, CaseIterable, Sendable {
    case action
    case learning
    case topic
    case reminder
    case reference
}

enum ParsedNoteItemStatus: String, Codable, CaseIterable, Sendable {
    case open
    case completed
    case archived
}

enum ParsedNoteItemReviewStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected
}

@Model
final class ParsedNoteItem {
    var id: UUID = UUID()
    var rawText: String = ""
    var title: String = ""
    var itemTypeRaw: String = ParsedNoteItemType.reference.rawValue
    var statusRaw: String = ParsedNoteItemStatus.open.rawValue
    var confidence: Double = 0
    var sourceLineIndex: Int = 0
    var dueHint: String? = nil
    var project: String? = nil
    var peopleJSON: String = "[]"
    var bucketId: String? = nil
    var bucketReason: String? = nil
    var acceptedAt: Date? = nil
    var completedAt: Date? = nil
    var archivedAt: Date? = nil
    var reviewStatusRaw: String = ParsedNoteItemReviewStatus.pending.rawValue
    var userEdited: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var dailyNote: DailyNote? = nil
    var note: Note? = nil
    var rejectedAt: Date? = nil
    var correctionJSON: String = "{}"
    var remoteID: String? = nil

    var itemType: ParsedNoteItemType {
        get { ParsedNoteItemType(rawValue: itemTypeRaw) ?? .reference }
        set { itemTypeRaw = newValue.rawValue }
    }

    var status: ParsedNoteItemStatus {
        get { ParsedNoteItemStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var people: [String] {
        get { Self.decodePeople(from: peopleJSON) }
        set { peopleJSON = Self.encodePeople(newValue) }
    }

    var bucketID: UUID? {
        get {
            guard let bucketId else { return nil }
            return UUID(uuidString: bucketId)
        }
        set {
            bucketId = newValue?.uuidString
        }
    }

    var reviewStatus: ParsedNoteItemReviewStatus {
        get {
            if let status = ParsedNoteItemReviewStatus(rawValue: reviewStatusRaw) {
                if status == .pending {
                    if acceptedAt != nil { return .accepted }
                    if rejectedAt != nil { return .rejected }
                }
                return status
            }

            if acceptedAt != nil { return .accepted }
            if rejectedAt != nil { return .rejected }
            return .pending
        }
        set {
            reviewStatusRaw = newValue.rawValue
            switch newValue {
            case .pending:
                acceptedAt = nil
                rejectedAt = nil
            case .accepted:
                acceptedAt = acceptedAt ?? Date()
                rejectedAt = nil
            case .rejected:
                rejectedAt = rejectedAt ?? Date()
                acceptedAt = nil
            }
        }
    }

    init(
        rawText: String = "",
        title: String = "",
        itemType: ParsedNoteItemType = .reference,
        status: ParsedNoteItemStatus = .open,
        confidence: Double = 0,
        sourceLineIndex: Int = 0,
        dueHint: String? = nil,
        project: String? = nil,
        people: [String] = [],
        bucketId: String? = nil,
        bucketReason: String? = nil,
        acceptedAt: Date? = nil,
        rejectedAt: Date? = nil,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        reviewStatus: ParsedNoteItemReviewStatus = .pending,
        userEdited: Bool = false,
        sortOrder: Int = 0,
        dailyNote: DailyNote? = nil,
        note: Note? = nil
    ) {
        self.id = UUID()
        self.rawText = rawText
        self.title = title
        self.itemTypeRaw = itemType.rawValue
        self.statusRaw = status.rawValue
        self.confidence = confidence
        self.sourceLineIndex = sourceLineIndex
        self.dueHint = dueHint
        self.project = project
        self.peopleJSON = Self.encodePeople(people)
        self.bucketId = bucketId
        self.bucketReason = bucketReason
        self.acceptedAt = acceptedAt
        self.rejectedAt = rejectedAt
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.reviewStatusRaw = reviewStatus.rawValue
        if acceptedAt != nil {
            self.reviewStatusRaw = ParsedNoteItemReviewStatus.accepted.rawValue
        } else if rejectedAt != nil {
            self.reviewStatusRaw = ParsedNoteItemReviewStatus.rejected.rawValue
        }
        self.userEdited = userEdited
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
        self.dailyNote = dailyNote
        self.note = note
    }

    private static func decodePeople(from json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let people = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return people
    }

    private static func encodePeople(_ people: [String]) -> String {
        let normalized = people
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
