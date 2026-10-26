import Foundation
import SwiftData

@Model
final class Adage {
    @Attribute(.unique) var id: UUID = UUID()
    var collectionName: String = ""
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        collectionName: String,
        title: String = "",
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.collectionName = collectionName
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

enum AdageLibrary {
    struct Group: Identifiable, Equatable, Sendable {
        var name: String
        var adages: [Summary]
        var id: String { name }
    }

    struct Summary: Identifiable, Equatable, Sendable {
        var id: UUID
        var collectionName: String
        var title: String
        var body: String
        var createdAt: Date
    }

    static func grouped(_ adages: [Summary]) -> [Group] {
        let sorted = adages.sorted { $0.createdAt > $1.createdAt }
        var order: [String] = []
        var grouped: [String: [Summary]] = [:]
        for adage in sorted {
            let name = adage.collectionName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Adages"
            if grouped[name] == nil {
                order.append(name)
            }
            grouped[name, default: []].append(adage)
        }
        return order.map { Group(name: $0, adages: grouped[$0] ?? []) }
    }
}
