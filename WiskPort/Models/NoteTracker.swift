import Foundation

struct NoteTracker: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultUnitLabel = "hours"
    static let defaultQuickAdds = [0.25, 0.5, 1, 2]

    var version: Int
    var unitLabel: String
    var quickAdds: [Double]
    var counters: [Counter]
    var events: [Event]

    init(
        version: Int = Self.currentVersion,
        unitLabel: String = Self.defaultUnitLabel,
        quickAdds: [Double] = Self.defaultQuickAdds,
        counters: [Counter] = [],
        events: [Event] = []
    ) {
        self.version = version
        self.unitLabel = unitLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.defaultUnitLabel
        self.quickAdds = Self.normalizedQuickAdds(quickAdds)
        self.counters = counters
        self.events = events
    }

    struct Counter: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var sortOrder: Int
        var archivedAt: Date?
        var createdAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            sortOrder: Int = 0,
            archivedAt: Date? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sortOrder = sortOrder
            self.archivedAt = archivedAt
            self.createdAt = createdAt
        }
    }

    struct Event: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var counterID: UUID
        var amount: Double
        var memo: String?
        var createdAt: Date

        init(
            id: UUID = UUID(),
            counterID: UUID,
            amount: Double,
            memo: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.counterID = counterID
            self.amount = amount
            self.memo = memo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.createdAt = createdAt
        }
    }
}

enum NoteTrackerPeriod: CaseIterable, Sendable {
    case today
    case week
    case month
    case allTime

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .allTime: return "All Time"
        }
    }
}

enum NoteTrackerStore {
    static func tracker(from body: String) -> NoteTracker {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let tracker = try? decoder.decode(NoteTracker.self, from: data) else {
            return NoteTracker()
        }
        return tracker
    }

    static func body(from tracker: NoteTracker) -> String {
        guard let data = try? encoder.encode(tracker),
              let body = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return body
    }

    static func defaultBody(unitLabel: String = NoteTracker.defaultUnitLabel, counters: [String] = []) -> String {
        let tracker = NoteTracker(
            unitLabel: unitLabel,
            counters: counters.enumerated().map { index, name in
                NoteTracker.Counter(name: name, sortOrder: index)
            }
        )
        return body(from: tracker)
    }

    static func addingCounter(_ name: String, to body: String) -> String {
        var tracker = tracker(from: body)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        guard tracker.counters.contains(where: { $0.archivedAt == nil && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) == false else {
            return Self.body(from: tracker)
        }
        let nextSortOrder = (tracker.counters.map(\.sortOrder).max() ?? -1) + 1
        tracker.counters.append(NoteTracker.Counter(name: trimmed, sortOrder: nextSortOrder))
        return Self.body(from: tracker)
    }

    static func archivingCounter(id: UUID, in body: String) -> String {
        var tracker = tracker(from: body)
        guard let index = tracker.counters.firstIndex(where: { $0.id == id }) else { return body }
        tracker.counters[index].archivedAt = Date()
        return Self.body(from: tracker)
    }

    static func recording(amount: Double, counterID: UUID, memo: String? = nil, in body: String) -> String {
        var tracker = tracker(from: body)
        guard amount > 0, tracker.counters.contains(where: { $0.id == counterID && $0.archivedAt == nil }) else {
            return body
        }
        tracker.events.append(NoteTracker.Event(counterID: counterID, amount: amount, memo: memo))
        return Self.body(from: tracker)
    }

    static func removingLastEvent(from body: String) -> String {
        var tracker = tracker(from: body)
        guard !tracker.events.isEmpty else { return body }
        tracker.events.removeLast()
        return Self.body(from: tracker)
    }

    static func updatingSettings(unitLabel: String, quickAdds: [Double], in body: String) -> String {
        var tracker = tracker(from: body)
        tracker.unitLabel = unitLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? NoteTracker.defaultUnitLabel
        tracker.quickAdds = NoteTracker.normalizedQuickAdds(quickAdds)
        return Self.body(from: tracker)
    }

    static func summary(for body: String, calendar: Calendar = .current, now: Date = Date()) -> String {
        let tracker = tracker(from: body)
        let counters = activeCounters(in: tracker)
        guard !counters.isEmpty else { return "No counters yet" }
        let todayTotal = total(in: tracker, period: .today, calendar: calendar, now: now)
        let allTimeTotal = total(in: tracker, period: .allTime, calendar: calendar, now: now)
        if allTimeTotal == 0 {
            return "\(counters.count) counter\(counters.count == 1 ? "" : "s")"
        }
        return "\(formatted(todayTotal)) \(tracker.unitLabel) today • \(formatted(allTimeTotal)) total"
    }

    static func searchableText(for body: String) -> String {
        let tracker = tracker(from: body)
        let counterNames = tracker.counters.map(\.name)
        let memos = tracker.events.compactMap(\.memo)
        return ([tracker.unitLabel] + counterNames + memos).joined(separator: " ")
    }

    static func activeCounters(in tracker: NoteTracker) -> [NoteTracker.Counter] {
        tracker.counters
            .filter { $0.archivedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    static func total(
        in tracker: NoteTracker,
        counterID: UUID? = nil,
        period: NoteTrackerPeriod = .allTime,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Double {
        tracker.events
            .filter { event in
                if let counterID, event.counterID != counterID { return false }
                return includes(event.createdAt, in: period, calendar: calendar, now: now)
            }
            .reduce(0) { $0 + $1.amount }
    }

    static func lastEventDescription(in tracker: NoteTracker) -> String? {
        guard let event = tracker.events.sorted(by: { $0.createdAt < $1.createdAt }).last else { return nil }
        let counterName = tracker.counters.first(where: { $0.id == event.counterID })?.name ?? "Counter"
        return "\(counterName) +\(formatted(event.amount)) \(tracker.unitLabel)"
    }

    static func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func includes(_ date: Date, in period: NoteTrackerPeriod, calendar: Calendar, now: Date) -> Bool {
        switch period {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
                && calendar.isDate(date, equalTo: now, toGranularity: .yearForWeekOfYear)
        case .month:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
                && calendar.isDate(date, equalTo: now, toGranularity: .year)
        case .allTime:
            return true
        }
    }
}

extension NoteTracker {
    static func normalizedQuickAdds(_ values: [Double]) -> [Double] {
        let normalized = values
            .filter { $0 > 0 }
            .map { ($0 * 100).rounded() / 100 }
        let unique = Array(Set(normalized)).sorted()
        return unique.isEmpty ? defaultQuickAdds : unique
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
