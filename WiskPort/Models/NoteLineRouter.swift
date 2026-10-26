import Foundation

enum NoteRouteDestination: String, Codable, Equatable, Sendable {
    case wiskAdage
    case schyboAndWisk
    case todoist
}

struct NoteRouteMapping: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var prefix: String = ""
    var destination: NoteRouteDestination = .wiskAdage
    var collectionName: String = ""
    var shorthand: String = ""
    var todoistProjectID: String = ""
    var todoistProjectName: String = ""
}

struct NoteRouteTodoistProject: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
}

enum NoteLineRouteAction: Equatable, Sendable {
    case adage(collectionName: String, title: String?, body: String, shorthand: String?)
    case todoist(projectID: String, content: String)
}

struct NoteLineRouteMatch: Equatable, Sendable {
    var lineIndex: Int
    var action: NoteLineRouteAction
}

struct NoteLineRoutePlan: Equatable, Sendable {
    var matches: [NoteLineRouteMatch]
}

enum NoteLineRouter {
    static let separator = " - "
    static let defaultSchyboBaseURL = "https://schybo.com"

    static func plan(body: String, mappings: [NoteRouteMapping]) -> NoteLineRoutePlan {
        let lines = lines(in: body)
        let ordered = mappings
            .compactMap { mapping -> (NoteRouteMapping, String)? in
                let prefix = mapping.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                guard prefix.isEmpty == false else { return nil }
                return (mapping, prefix)
            }
            .sorted { $0.1.count > $1.1.count }

        var matches: [NoteLineRouteMatch] = []
        for (index, line) in lines.enumerated() {
            guard let action = action(for: line, mappings: ordered) else { continue }
            matches.append(NoteLineRouteMatch(lineIndex: index, action: action))
        }
        return NoteLineRoutePlan(matches: matches)
    }

    static func bodyByRemovingLines(_ body: String, indexes: Set<Int>) -> String {
        lines(in: body)
            .enumerated()
            .filter { indexes.contains($0.offset) == false }
            .map(\.element)
            .joined(separator: "\n")
    }

    static func splitAdageText(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let boundary = firstSentenceBoundary(in: trimmed) else {
            return (nil, trimmed)
        }
        let title = String(trimmed[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(trimmed[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false, rest.isEmpty == false else {
            return (nil, trimmed)
        }
        return (title, rest)
    }

    static func unavailableReason(
        mappings: [NoteRouteMapping],
        todoistConnected: Bool,
        schyboConnected: Bool
    ) -> String? {
        let active = mappings.filter {
            $0.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard active.isEmpty == false else {
            return "Add prefix mappings in Settings."
        }
        if active.contains(where: { $0.destination == .todoist && todoistConnected == false }) {
            return "Connect Todoist in Settings."
        }
        if active.contains(where: { $0.destination == .schyboAndWisk && schyboConnected == false }) {
            return "Connect SCHYBO in Settings."
        }
        if active.contains(where: { $0.destination == .todoist && $0.todoistProjectID.nilIfBlank == nil }) {
            return "Choose a Todoist project for each prefix."
        }
        return nil
    }

    static func summary(adageCount: Int, taskCount: Int, failures: [String], matched: Bool) -> String {
        guard matched else {
            return "No prefixed lines matched your mappings."
        }
        var parts: [String] = []
        if adageCount > 0 {
            parts.append("\(adageCount) adage\(adageCount == 1 ? "" : "s")")
        }
        if taskCount > 0 {
            parts.append("\(taskCount) Todoist task\(taskCount == 1 ? "" : "s")")
        }
        var message = parts.isEmpty
            ? "No lines were routed."
            : "Filed \(parts.joined(separator: " and "))."
        if failures.isEmpty == false {
            let noun = failures.count == 1 ? "line" : "lines"
            message += " \(failures.count) \(noun) stayed: \(failures.prefix(3).joined(separator: " "))"
        }
        return message
    }

    private static func lines(in body: String) -> [String] {
        body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private static func action(
        for line: String,
        mappings: [(NoteRouteMapping, String)]
    ) -> NoteLineRouteAction? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for (mapping, prefix) in mappings {
            let needle = prefix + separator
            guard let range = trimmed.range(of: needle, options: [.caseInsensitive, .anchored]) else {
                continue
            }
            let content = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.isEmpty == false else { return nil }
            return makeAction(mapping: mapping, prefix: prefix, content: content)
        }
        return nil
    }

    private static func makeAction(
        mapping: NoteRouteMapping,
        prefix: String,
        content: String
    ) -> NoteLineRouteAction {
        switch mapping.destination {
        case .wiskAdage, .schyboAndWisk:
            let split = splitAdageText(content)
            let collection = mapping.collectionName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? prefix
            let shorthand = mapping.destination == .schyboAndWisk
                ? (mapping.shorthand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? prefix)
                : nil
            return .adage(
                collectionName: collection,
                title: split.title,
                body: split.body,
                shorthand: shorthand
            )
        case .todoist:
            return .todoist(projectID: mapping.todoistProjectID, content: content)
        }
    }

    private static func firstSentenceBoundary(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isWhitespace {
                    return next
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
