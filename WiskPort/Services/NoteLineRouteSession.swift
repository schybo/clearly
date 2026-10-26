import Foundation
import SwiftData

struct NoteLineRouteResult: Equatable, Sendable {
    var body: String
    var message: String
    var savedAdageCount: Int
}

@MainActor
enum NoteLineRouteSession {
    static func route(
        body: String,
        mappings: [NoteRouteMapping],
        context: ModelContext,
        publisher: any NoteRoutePublishing,
        lessonsURL: URL?,
        schyboToken: String?,
        todoistToken: String?
    ) async -> NoteLineRouteResult {
        let plan = NoteLineRouter.plan(body: body, mappings: mappings)
        guard plan.matches.isEmpty == false else {
            return NoteLineRouteResult(
                body: body,
                message: NoteLineRouter.summary(adageCount: 0, taskCount: 0, failures: [], matched: false),
                savedAdageCount: 0
            )
        }

        var removed = Set<Int>()
        var failures: [String] = []
        var adageCount = 0
        var taskCount = 0

        for match in plan.matches {
            switch match.action {
            case let .adage(collectionName, title, adageBody, shorthand):
                let adage = Adage(
                    collectionName: collectionName,
                    title: title ?? "",
                    body: adageBody
                )
                context.insert(adage)
                if let shorthand {
                    do {
                        guard let lessonsURL, let schyboToken else {
                            throw NoteRouteRequestError(message: "Connect SCHYBO in Settings.")
                        }
                        try await publisher.publishLesson(
                            shorthand: shorthand,
                            title: title,
                            body: adageBody,
                            lessonsURL: lessonsURL,
                            token: schyboToken
                        )
                    } catch {
                        context.delete(adage)
                        failures.append(error.localizedDescription)
                        continue
                    }
                }
                do {
                    try context.save()
                } catch {
                    context.delete(adage)
                    failures.append(error.localizedDescription)
                    continue
                }
                removed.insert(match.lineIndex)
                adageCount += 1
            case let .todoist(projectID, content):
                do {
                    guard projectID.isEmpty == false else {
                        throw NoteRouteRequestError(message: "Choose a Todoist project for this prefix.")
                    }
                    guard let todoistToken else {
                        throw NoteRouteRequestError(message: "Connect Todoist in Settings.")
                    }
                    try await publisher.createTask(content: content, projectID: projectID, token: todoistToken)
                } catch {
                    failures.append(error.localizedDescription)
                    continue
                }
                removed.insert(match.lineIndex)
                taskCount += 1
            }
        }

        let updated = removed.isEmpty ? body : NoteLineRouter.bodyByRemovingLines(body, indexes: removed)
        return NoteLineRouteResult(
            body: updated,
            message: NoteLineRouter.summary(
                adageCount: adageCount,
                taskCount: taskCount,
                failures: failures,
                matched: true
            ),
            savedAdageCount: adageCount
        )
    }
}
