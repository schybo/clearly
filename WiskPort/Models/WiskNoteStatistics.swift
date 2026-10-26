import Foundation

struct WiskNoteStatistics: Equatable, Sendable {
    var wordCount: Int
    var characterCount: Int
    var estimatedReadMinutes: Int

    static let wordsPerMinute = 200

    static func from(title: String, body: String) -> WiskNoteStatistics {
        let combined = [title, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
        let words = combined.split { $0.isWhitespace || $0.isNewline }.count
        return WiskNoteStatistics(
            wordCount: words,
            characterCount: combined.count,
            estimatedReadMinutes: words == 0 ? 0 : max(1, Int(ceil(Double(words) / Double(wordsPerMinute))))
        )
    }

    var wordCountLabel: String {
        "\(wordCount.formatted()) \(wordCount == 1 ? "word" : "words")"
    }

    var characterCountLabel: String {
        "\(characterCount.formatted()) \(characterCount == 1 ? "character" : "characters")"
    }

    var readTimeLabel: String {
        if estimatedReadMinutes == 0 {
            return "Less than a minute"
        }
        if estimatedReadMinutes == 1 {
            return "1 min read"
        }
        return "\(estimatedReadMinutes.formatted()) min read"
    }
}
