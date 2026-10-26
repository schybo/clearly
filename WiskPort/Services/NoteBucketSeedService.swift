import Foundation
import SwiftData

@MainActor
enum NoteBucketSeedService {
    static let defaultTasksBucketName = "Tasks"

    @discardableResult
    static func ensureDefaultTasksBucket(context: ModelContext) throws -> NoteBucket {
        var defaultDescriptor = FetchDescriptor<NoteBucket>(
            predicate: #Predicate { $0.isDefault && $0.archivedAt == nil }
        )
        defaultDescriptor.fetchLimit = 1
        if let existing = try context.fetch(defaultDescriptor).first {
            return existing
        }

        var tasksDescriptor = FetchDescriptor<NoteBucket>(
            predicate: #Predicate { $0.name == defaultTasksBucketName && $0.archivedAt == nil }
        )
        tasksDescriptor.fetchLimit = 1
        if let tasks = try context.fetch(tasksDescriptor).first {
            tasks.isDefault = true
            tasks.sortOrder = min(tasks.sortOrder, 0)
            tasks.updatedAt = Date()
            try context.save()
            return tasks
        }

        let tasksBucket = NoteBucket(
            name: defaultTasksBucketName,
            descriptionText: "Default bucket for actionable tasks and reminders.",
            examples: ["[ ] Follow up with Alex", "Pay internet bill", "Book dentist appointment"],
            sortOrder: 0,
            isDefault: true
        )
        context.insert(tasksBucket)
        try context.save()
        return tasksBucket
    }
}
