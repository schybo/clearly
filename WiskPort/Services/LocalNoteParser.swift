import Foundation

struct ParsedDailyNoteDraft: Sendable {
    var date: Date = Date()
    var rawText: String = ""
    var parseVersion: Int = LocalNoteParser.parseVersion
    var parseModel: String = LocalNoteParser.modelIdentifier
    var items: [ParsedNoteItemDraft] = []
}

struct ParsedNoteItemDraft: Identifiable, Sendable {
    var id: UUID = UUID()
    var rawText: String = ""
    var title: String = ""
    var itemType: ParsedNoteItemType = .reference
    var status: ParsedNoteItemStatus = .open
    var reviewStatus: ParsedNoteItemReviewStatus = .pending
    var confidence: Double = 0
    var sourceLineIndex: Int = 0
    var dueHint: String? = nil
    var project: String? = nil
    var people: [String] = []
    var bucketId: String? = nil
    var bucketReason: String? = nil

    var bucketID: UUID? {
        get {
            guard let bucketId else { return nil }
            return UUID(uuidString: bucketId)
        }
        set {
            bucketId = newValue?.uuidString
        }
    }
}

struct LocalNoteParser: Sendable {
    static let parseVersion = 1
    static let modelIdentifier = "local-note-parser-v1"

    private let actionPrefixes: Set<String> = [
        "ask", "book", "buy", "call", "cancel", "clean", "draft", "email",
        "file", "finish", "fix", "follow up", "make", "order", "pay",
        "pick up", "prep", "prepare", "review", "schedule", "send",
        "submit", "text", "update", "write"
    ]

    private let topicPrefixes: Set<String> = [
        "idea", "ideas", "project", "topic", "topics"
    ]

    private let learningPrefixes: Set<String> = [
        "decided", "insight", "learned", "learning", "realized", "takeaway"
    ]

    private let referencePrefixes: Set<String> = [
        "link", "links", "note", "notes", "ref", "reference"
    ]

    func parse(_ rawText: String, date: Date = Date()) -> ParsedDailyNoteDraft {
        let lines = rawText.components(separatedBy: .newlines)
        let items = lines.enumerated().compactMap { index, line in
            parseLine(line, sourceLineIndex: index)
        }

        return ParsedDailyNoteDraft(
            date: date,
            rawText: rawText,
            parseVersion: Self.parseVersion,
            parseModel: Self.modelIdentifier,
            items: items
        )
    }

    private func parseLine(_ line: String, sourceLineIndex: Int) -> ParsedNoteItemDraft? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let content = stripListMarker(from: trimmed)
        let checklist = parseChecklistPrefix(from: content)
        let title = normalizedTitle(from: checklist?.title ?? content)
        guard !title.isEmpty else { return nil }

        let classification = classify(title: title, hasChecklistPrefix: checklist != nil)
        let status = checklist?.isCompleted == true ? ParsedNoteItemStatus.completed : .open

        return ParsedNoteItemDraft(
            rawText: line,
            title: title,
            itemType: classification.itemType,
            status: status,
            confidence: checklist != nil ? 0.98 : classification.confidence,
            sourceLineIndex: sourceLineIndex,
            dueHint: dueHint(in: title),
            project: project(in: title),
            people: people(in: title)
        )
    }

    private func stripListMarker(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              let first = parts.first,
              first.last == ".",
              first.dropLast().allSatisfy(\.isNumber) else {
            return trimmed
        }

        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    private func parseChecklistPrefix(from line: String) -> (isCompleted: Bool, title: String)? {
        guard line.count >= 3,
              line.first == "[",
              let closingIndex = line.firstIndex(of: "]") else {
            return nil
        }

        let mark = String(line[line.index(after: line.startIndex)..<closingIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mark.isEmpty || mark == "x" else { return nil }

        let titleStart = line.index(after: closingIndex)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)
        return (isCompleted: mark == "x", title: title)
    }

    private func normalizedTitle(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        for prefix in ["todo:", "task:", "remember to "] where lowercased.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }

        return trimmed
    }

    private func classify(title: String, hasChecklistPrefix: Bool) -> (itemType: ParsedNoteItemType, confidence: Double) {
        if hasChecklistPrefix {
            return (.action, 0.98)
        }

        let lowercased = title.lowercased()
        if hasActionCue(in: lowercased) {
            return (.action, 0.82)
        }

        if hasKnownPrefix(in: lowercased, prefixes: learningPrefixes) || lowercased.contains(" learned ") || lowercased.contains(" realized ") {
            return (.learning, 0.78)
        }

        if lowercased.contains("bday") || lowercased.contains("birthday") {
            return (.reminder, 0.76)
        }

        if title.hasPrefix("#") || title.hasSuffix(":") || hasKnownPrefix(in: lowercased, prefixes: topicPrefixes) {
            return (.topic, 0.72)
        }

        if lowercased.contains("://") || hasKnownPrefix(in: lowercased, prefixes: referencePrefixes) {
            return (.reference, 0.75)
        }

        return (.reference, 0.58)
    }

    private func hasActionCue(in lowercased: String) -> Bool {
        if lowercased.hasPrefix("todo:") || lowercased.hasPrefix("task:") || lowercased.hasPrefix("remember to ") {
            return true
        }

        if dueHint(in: lowercased) != nil {
            return true
        }

        return actionPrefixes.contains { prefix in
            lowercased == prefix || lowercased.hasPrefix(prefix + " ")
        }
    }

    private func hasKnownPrefix(in lowercased: String, prefixes: Set<String>) -> Bool {
        prefixes.contains { prefix in
            lowercased == prefix || lowercased.hasPrefix(prefix + ":") || lowercased.hasPrefix(prefix + " ")
        }
    }

    private func dueHint(in title: String) -> String? {
        let lowercased = title.lowercased()
        let directHints = [
            "today", "tomorrow", "tonight", "next week",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
        ]

        if let hint = directHints.first(where: { lowercased.contains($0) }) {
            return hint
        }

        for marker in [" by ", " due "] {
            guard let range = title.range(of: marker, options: .caseInsensitive) else { continue }
            let suffix = title[range.upperBound...]
            let hint = String(suffix)
                .split(whereSeparator: { ",.;".contains($0) })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let hint, !hint.isEmpty {
                return marker.trimmingCharacters(in: .whitespaces) + " " + hint
            }
        }

        return nil
    }

    private func project(in title: String) -> String? {
        let words = title.split(whereSeparator: \.isWhitespace)
        if let tag = words.first(where: { $0.hasPrefix("#") && $0.count > 1 }) {
            return String(tag.dropFirst()).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }

        guard let range = title.range(of: "project:", options: .caseInsensitive) else { return nil }
        let suffix = title[range.upperBound...]
        return String(suffix)
            .split(whereSeparator: { ",;".contains($0) })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func people(in title: String) -> [String] {
        let ignoredNames: Set<String> = [
            "Friday", "Monday", "Saturday", "Sunday", "Thursday", "Tuesday", "Wednesday"
        ]
        var seen = Set<String>()
        var results: [String] = []

        let tokens = title.split(whereSeparator: \.isWhitespace)
        for (index, rawToken) in tokens.enumerated() {
            let cleaned = String(rawToken).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !cleaned.isEmpty else { continue }

            let lowercased = cleaned.lowercased()
            if index == 0, actionPrefixes.contains(where: { lowercased == $0 || lowercased.hasPrefix($0 + " ") }) {
                continue
            }

            let candidate: String?
            if rawToken.hasPrefix("@") {
                candidate = cleaned
            } else if cleaned.first?.isUppercase == true, !ignoredNames.contains(cleaned) {
                candidate = cleaned
            } else {
                candidate = nil
            }

            guard let candidate, !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            results.append(candidate)
        }

        return results
    }
}

