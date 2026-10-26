import Foundation

enum NoteChecklistMode: String, Codable, Sendable {
    case checkbox
    case customStatus
}

struct NoteChecklistStatus: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var isCompleted: Bool
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        title: String,
        systemImage: String = "circle",
        isCompleted: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.systemImage = systemImage
        self.isCompleted = isCompleted
        self.sortOrder = sortOrder
    }
}

struct NoteChecklistItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var isCompleted: Bool

    // Non-nil only for custom-status lists.
    var statusID: String?

    init(id: UUID = UUID(), text: String, isCompleted: Bool, statusID: String? = nil) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.statusID = statusID
    }
}

struct NoteChecklistList: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var mode: NoteChecklistMode
    var statuses: [NoteChecklistStatus]
    var items: [NoteChecklistItem]

    init(
        version: Int = Self.currentVersion,
        mode: NoteChecklistMode = .checkbox,
        statuses: [NoteChecklistStatus] = NoteChecklist.defaultStatuses,
        items: [NoteChecklistItem] = []
    ) {
        self.version = version
        self.mode = mode
        self.statuses = NoteChecklist.normalizedStatuses(statuses)
        self.items = NoteChecklist.normalizedItems(items, statuses: self.statuses, mode: mode)
    }
}

struct NoteChecklistTemplate: Identifiable, Sendable {
    let id: String
    let title: String
    let statuses: [NoteChecklistStatus]
}

enum NoteChecklist {
    static let openStatusID = "open"
    static let completedStatusID = "done"

    static let defaultStatuses = [
        NoteChecklistStatus(id: openStatusID, title: "Open", systemImage: "circle", isCompleted: false, sortOrder: 0),
        NoteChecklistStatus(id: completedStatusID, title: "Done", systemImage: "checkmark.circle.fill", isCompleted: true, sortOrder: 1),
    ]

    static let templates = [
        NoteChecklistTemplate(id: "todo", title: "To-do", statuses: defaultStatuses),
        NoteChecklistTemplate(
            id: "shows",
            title: "Shows",
            statuses: [
                NoteChecklistStatus(id: "want-to-try", title: "Want to try", systemImage: "sparkle.magnifyingglass", isCompleted: false, sortOrder: 0),
                NoteChecklistStatus(id: "downloaded", title: "Downloaded", systemImage: "arrow.down.circle", isCompleted: false, sortOrder: 1),
                NoteChecklistStatus(id: "watched", title: "Watched", systemImage: "play.circle.fill", isCompleted: true, sortOrder: 2),
                NoteChecklistStatus(id: "liked", title: "Liked", systemImage: "hand.thumbsup.fill", isCompleted: true, sortOrder: 3),
                NoteChecklistStatus(id: "didnt-like", title: "Didn't like", systemImage: "hand.thumbsdown", isCompleted: true, sortOrder: 4),
            ]
        ),
    ]

    static func list(from body: String) -> NoteChecklistList {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let data = trimmed.data(using: .utf8),
           let decoded = try? decoder.decode(NoteChecklistList.self, from: data) {
            return NoteChecklistList(
                version: decoded.version,
                mode: decoded.mode,
                statuses: decoded.statuses,
                items: decoded.items
            )
        }

        return NoteChecklistList(
            mode: .checkbox,
            statuses: defaultStatuses,
            items: legacyItems(from: body)
        )
    }

    static func items(from body: String) -> [NoteChecklistItem] {
        list(from: body).items
    }

    static func body(from items: [NoteChecklistItem]) -> String {
        items
            .map { "\($0.isCompleted ? "- [x]" : "- [ ]") \($0.text)" }
            .joined(separator: "\n")
    }

    static func body(from list: NoteChecklistList) -> String {
        let normalized = NoteChecklistList(
            version: list.version,
            mode: list.mode,
            statuses: list.statuses,
            items: list.items
        )

        guard normalized.mode == .customStatus else {
            return body(from: normalized.items)
        }

        guard let data = try? encoder.encode(normalized),
              let body = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return body
    }

    static func addingItem(_ text: String, to body: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        var list = list(from: body)
        let defaultStatus = list.statuses.first(where: { !$0.isCompleted }) ?? list.statuses.first
        list.items.append(NoteChecklistItem(
            text: trimmed,
            isCompleted: defaultStatus?.isCompleted ?? false,
            statusID: list.mode == .customStatus ? defaultStatus?.id : nil
        ))
        return self.body(from: list)
    }

    static func togglingItem(at index: Int, in body: String) -> String {
        var list = list(from: body)
        guard list.items.indices.contains(index) else { return body }

        if list.mode == .customStatus {
            let nextStatus = statusAfterCurrentItem(at: index, in: list)
            list.items[index].statusID = nextStatus.id
            list.items[index].isCompleted = nextStatus.isCompleted
        } else {
            list.items[index].isCompleted.toggle()
        }

        return self.body(from: list)
    }

    static func settingStatus(_ statusID: String, forItemAt index: Int, in body: String) -> String {
        var list = list(from: body)
        guard list.mode == .customStatus,
              list.items.indices.contains(index),
              let status = list.statuses.first(where: { $0.id == statusID })
        else { return body }
        list.items[index].statusID = status.id
        list.items[index].isCompleted = status.isCompleted
        return self.body(from: list)
    }

    static func deletingItem(at index: Int, in body: String) -> String {
        var list = list(from: body)
        guard list.items.indices.contains(index) else { return body }
        list.items.remove(at: index)
        return self.body(from: list)
    }

    static func removingCompletedItems(from body: String) -> String {
        var list = list(from: body)
        list.items = list.items.filter { !$0.isCompleted }
        return self.body(from: list)
    }

    static func progressSummary(for body: String) -> String {
        let list = list(from: body)
        guard !list.items.isEmpty else { return "No items yet" }

        guard list.mode == .customStatus else {
            let completed = list.items.filter(\.isCompleted).count
            return "\(completed) of \(list.items.count) done"
        }

        let counts = Dictionary(grouping: list.items, by: { status(for: $0, in: list).id })
            .mapValues(\.count)
        let summaries = list.statuses
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { status -> String? in
                guard let count = counts[status.id], count > 0 else { return nil }
                return "\(count) \(status.title.lowercased())"
            }
        return summaries.prefix(2).joined(separator: ", ")
    }

    static func firstItemText(in body: String) -> String? {
        items(from: body).first?.text
    }

    static func customizingStatuses(in body: String, template: NoteChecklistTemplate? = nil) -> String {
        var list = list(from: body)
        list.mode = .customStatus
        list.statuses = normalizedStatuses(template?.statuses ?? list.statuses)
        list.items = normalizedItems(list.items, statuses: list.statuses, mode: .customStatus)
        return self.body(from: list)
    }

    static func replacingStatuses(_ statuses: [NoteChecklistStatus], in body: String) -> String {
        var list = list(from: body)
        list.mode = .customStatus
        list.statuses = normalizedStatuses(statuses)
        list.items = normalizedItems(list.items, statuses: list.statuses, mode: .customStatus)
        return self.body(from: list)
    }

    static func convertingToCheckbox(_ body: String) -> String {
        var list = list(from: body)
        list.items = list.items.map { item in
            var updated = item
            updated.isCompleted = status(for: item, in: list).isCompleted
            updated.statusID = nil
            return updated
        }
        list.mode = .checkbox
        list.statuses = defaultStatuses
        return self.body(from: list)
    }

    static func status(for item: NoteChecklistItem, in list: NoteChecklistList) -> NoteChecklistStatus {
        if let statusID = item.statusID,
           let status = list.statuses.first(where: { $0.id == statusID }) {
            return status
        }
        return list.statuses.first(where: { $0.isCompleted == item.isCompleted })
            ?? list.statuses.first
            ?? defaultStatuses[0]
    }

    static func normalizedStatuses(_ statuses: [NoteChecklistStatus]) -> [NoteChecklistStatus] {
        let trimmed = statuses.enumerated().compactMap { index, status -> NoteChecklistStatus? in
            let title = status.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            var normalized = status
            normalized.title = title
            normalized.sortOrder = index
            return normalized
        }
        return trimmed.isEmpty ? defaultStatuses : trimmed
    }

    static func normalizedItems(
        _ items: [NoteChecklistItem],
        statuses: [NoteChecklistStatus],
        mode: NoteChecklistMode
    ) -> [NoteChecklistItem] {
        let sortedStatuses = normalizedStatuses(statuses)
        return items.map { item in
            var normalized = item
            guard mode == .customStatus else {
                normalized.statusID = nil
                return normalized
            }

            if let statusID = normalized.statusID,
               let status = sortedStatuses.first(where: { $0.id == statusID }) {
                normalized.isCompleted = status.isCompleted
                return normalized
            }

            let fallbackStatus = sortedStatuses.first(where: { $0.isCompleted == item.isCompleted })
                ?? sortedStatuses.first
            normalized.statusID = fallbackStatus?.id
            normalized.isCompleted = fallbackStatus?.isCompleted ?? item.isCompleted
            return normalized
        }
    }

    private static func legacyItems(from body: String) -> [NoteChecklistItem] {
        body.components(separatedBy: .newlines).compactMap { line in
            item(from: line)
        }
    }

    private static func item(from rawLine: String) -> NoteChecklistItem? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("- [ ] ") {
            return NoteChecklistItem(text: String(line.dropFirst(6)), isCompleted: false)
        }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return NoteChecklistItem(text: String(line.dropFirst(6)), isCompleted: true)
        }
        if line.hasPrefix("[ ] ") {
            return NoteChecklistItem(text: String(line.dropFirst(4)), isCompleted: false)
        }
        if line.hasPrefix("[x] ") || line.hasPrefix("[X] ") {
            return NoteChecklistItem(text: String(line.dropFirst(4)), isCompleted: true)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return NoteChecklistItem(text: String(line.dropFirst(2)), isCompleted: false)
        }
        return NoteChecklistItem(text: line, isCompleted: false)
    }

    private static func statusAfterCurrentItem(at index: Int, in list: NoteChecklistList) -> NoteChecklistStatus {
        let statuses = list.statuses.sorted { $0.sortOrder < $1.sortOrder }
        guard !statuses.isEmpty else { return defaultStatuses[0] }
        let current = status(for: list.items[index], in: list)
        guard let currentIndex = statuses.firstIndex(where: { $0.id == current.id }) else {
            return statuses[0]
        }
        return statuses[(currentIndex + 1) % statuses.count]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
