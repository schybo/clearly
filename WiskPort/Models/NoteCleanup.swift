import Foundation

enum NoteCleanup {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "as", "at", "be", "by", "for", "from", "if", "in", "is", "it",
        "of", "on", "or", "the", "this", "that", "to", "with", "note", "notes", "todo",
        "task", "today", "tomorrow", "tonight", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday",
    ]

    static func supports(_ kind: NoteKind) -> Bool {
        kind == .general || kind == .daily
    }

    static func cleanedBody(_ body: String) -> String {
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let items = lines.enumerated().compactMap { index, line -> LineItem? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return LineItem(index: index, line: line)
        }

        let keysByIndex = assignKeys(to: items)
        var emitted = Set<String>()
        var ungroupedRun: [String] = []
        var result: [String] = []

        func flushUngrouped() {
            guard !ungroupedRun.isEmpty else { return }
            appendGroup(ungroupedRun)
            ungroupedRun = []
        }

        func appendGroup(_ group: [String]) {
            if !result.isEmpty {
                result.append("")
            }
            result.append(contentsOf: group)
        }

        for item in items {
            if let key = keysByIndex[item.index] {
                if emitted.contains(key) { continue }
                flushUngrouped()
                let grouped = items
                    .filter { keysByIndex[$0.index] == key }
                    .map(\.line)
                appendGroup(grouped)
                emitted.insert(key)
            } else {
                ungroupedRun.append(item.line)
            }
        }
        flushUngrouped()

        var cleaned = result.joined(separator: "\n")
        if body.hasSuffix("\n") && !cleaned.hasSuffix("\n") {
            cleaned.append("\n")
        }
        return cleaned
    }

    private struct LineItem {
        let index: Int
        let line: String
    }

    private static func assignKeys(to items: [LineItem]) -> [Int: String] {
        var explicit: [Int: String] = [:]
        var firstSeen: [String: String] = [:]
        var mentionCounts: [String: Int] = [:]

        for item in items {
            if headingMarker(in: item.line) != nil {
                continue
            }
            if let slash = slashPrefix(in: item.line) {
                let canonical = remember(&firstSeen, slash)
                explicit[item.index] = canonical
            } else if let label = leadingLabel(in: item.line) {
                let canonical = remember(&firstSeen, label)
                explicit[item.index] = canonical
            }

            for token in mentionTokens(in: item.line) {
                _ = remember(&firstSeen, token)
                mentionCounts[token.lowercased(), default: 0] += 1
            }
        }

        var mentionKeys: [String] = []
        for (lowercased, count) in mentionCounts where count >= 2 {
            if let canonical = firstSeen[lowercased] {
                mentionKeys.append(canonical)
            }
        }
        mentionKeys.sort { lhs, rhs in
            firstIndex(of: lhs, in: items) < firstIndex(of: rhs, in: items)
        }

        var assigned = explicit
        for item in items where assigned[item.index] == nil {
            if headingMarker(in: item.line) != nil { continue }
            if let match = mentionKeys.first(where: { containsWholeToken(item.line, $0) }) {
                assigned[item.index] = match
            }
        }
        return assigned
    }

    private static func firstIndex(of key: String, in items: [LineItem]) -> Int {
        items.first { containsWholeToken($0.line, key) }?.index ?? .max
    }

    private static func remember(_ firstSeen: inout [String: String], _ token: String) -> String {
        let key = token.lowercased()
        if let existing = firstSeen[key] {
            return existing
        }
        firstSeen[key] = token
        return token
    }

    private static func contentForKey(in line: String) -> String {
        var content = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ ", "• "] where content.hasPrefix(marker) {
            content = String(content.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if content.hasPrefix("[") {
            if let close = content.firstIndex(of: "]") {
                content = String(content[content.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return content
    }

    private static func headingMarker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let markerCount = trimmed.prefix(while: { $0 == "#" }).count
        guard markerCount >= 1, markerCount <= 6 else { return nil }
        let rest = trimmed.dropFirst(markerCount)
        guard rest.first?.isWhitespace == true || rest.isEmpty else { return nil }
        return trimmed
    }

    private static func slashPrefix(in line: String) -> String? {
        let content = contentForKey(in: line)
        let pattern = #"^([A-Za-z]{1,4}/[A-Za-z0-9]{1,4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let swiftRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[swiftRange])
    }

    private static func leadingLabel(in line: String) -> String? {
        let content = contentForKey(in: line)
        let pattern = #"^([A-Za-z][A-Za-z0-9.+#-]{1,24})\s*[-:–—]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let swiftRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        let label = String(content[swiftRange])
        if stopWords.contains(label.lowercased()) { return nil }
        return label
    }

    private static func mentionTokens(in line: String) -> [String] {
        if headingMarker(in: line) != nil { return [] }
        var tokens: [String] = []
        if let slash = slashPrefix(in: line) {
            tokens.append(slash)
        }
        if let label = leadingLabel(in: line) {
            tokens.append(label)
        }
        let content = contentForKey(in: line)
        let pattern = #"\b([A-Z][A-Za-z0-9]{1,})\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            regex.enumerateMatches(in: content, range: range) { match, _, _ in
                guard let match,
                      let swiftRange = Range(match.range(at: 1), in: content) else { return }
                let token = String(content[swiftRange])
                if !stopWords.contains(token.lowercased()) {
                    tokens.append(token)
                }
            }
        }
        return tokens
    }

    private static func containsWholeToken(_ line: String, _ token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }
}
