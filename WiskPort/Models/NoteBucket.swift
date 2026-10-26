import Foundation
import SwiftData

@Model
final class NoteBucket {
    var id: UUID = UUID()
    var name: String = ""
    var descriptionText: String = ""
    var examplesJSON: String = "[]"
    var sortOrder: Int = 0
    var isDefault: Bool = false
    var archivedAt: Date? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var examples: [String] {
        get { Self.decodeExamples(from: examplesJSON) }
        set { examplesJSON = Self.encodeExamples(newValue) }
    }

    init(
        name: String = "",
        descriptionText: String = "",
        examples: [String] = [],
        sortOrder: Int = 0,
        isDefault: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.descriptionText = descriptionText
        self.examplesJSON = Self.encodeExamples(examples)
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.archivedAt = archivedAt
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private static func decodeExamples(from json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let examples = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return examples
    }

    private static func encodeExamples(_ examples: [String]) -> String {
        let normalized = examples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

extension NoteBucket {
    var asParsingInput: NoteParsingBucketInput {
        NoteParsingBucketInput(
            id: id,
            name: name,
            descriptionText: descriptionText,
            examples: examples
        )
    }
}
