import Foundation

enum VoiceNoteTitleGenerator {
    static func title(for transcript: String, now: Date = Date()) -> String {
        let cleaned = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        guard !cleaned.isEmpty else {
            return "Voice note"
        }

        let words = cleaned.split(separator: " ")
        let prefix = words.prefix(8).joined(separator: " ")
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        return trimmed.isEmpty ? "Voice note" : trimmed
    }
}
