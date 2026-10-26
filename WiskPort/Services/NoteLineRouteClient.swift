import Foundation

protocol NoteRoutePublishing: Sendable {
    func publishLesson(
        shorthand: String,
        title: String?,
        body: String,
        lessonsURL: URL,
        token: String
    ) async throws

    func createTask(content: String, projectID: String, token: String) async throws
}

struct NoteRouteHTTPClient: NoteRoutePublishing, Sendable {
    static let todoistBaseURL = URL(string: "https://api.todoist.com/api/v1")!

    var session: URLSession = .shared

    func listProjects(token: String) async throws -> [NoteRouteTodoistProject] {
        var projects: [NoteRouteTodoistProject] = []
        var cursor: String?
        var pages = 0
        repeat {
            pages += 1
            var components = URLComponents(url: Self.todoistBaseURL.appendingPathComponent("projects"), resolvingAgainstBaseURL: false)
            if let cursor {
                components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
            }
            guard let url = components?.url else {
                throw NoteRouteRequestError(message: "Todoist project URL is invalid.")
            }
            let data = try await data(for: url, method: "GET", token: token, body: nil, service: "Todoist")
            let page = try decodeProjects(from: data)
            projects.append(contentsOf: page.projects)
            cursor = page.nextCursor?.nilIfBlank
        } while cursor != nil && pages < 20
        return projects
    }

    func verifyLearningToken(lessonsURL: URL, token: String) async throws {
        var request = authorizedRequest(url: lessonsURL, method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NoteRouteRequestError(message: "SCHYBO did not respond.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NoteRouteRequestError(message: "SCHYBO rejected the learning API token.")
        }
        if (200..<300).contains(http.statusCode) || http.statusCode == 400 || http.statusCode == 422 {
            return
        }
        throw NoteRouteRequestError(message: "SCHYBO request failed (\(http.statusCode)).")
    }

    func publishLesson(
        shorthand: String,
        title: String?,
        body: String,
        lessonsURL: URL,
        token: String
    ) async throws {
        var payload: [String: Any] = [
            "shorthand": shorthand,
            "body": body,
        ]
        if let title, title.isEmpty == false {
            payload["title"] = title
        }
        _ = try await data(for: lessonsURL, method: "POST", token: token, body: payload, service: "SCHYBO")
    }

    func createTask(content: String, projectID: String, token: String) async throws {
        let url = Self.todoistBaseURL.appendingPathComponent("tasks")
        _ = try await data(
            for: url,
            method: "POST",
            token: token,
            body: ["content": content, "project_id": projectID],
            service: "Todoist"
        )
    }

    static func lessonsURL(from base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard text.isEmpty == false else { return nil }
        if text.hasSuffix("/api/learning/lessons") {
            return URL(string: text)
        }
        return URL(string: text + "/api/learning/lessons")
    }

    private func data(
        for url: URL,
        method: String,
        token: String,
        body: [String: Any]?,
        service: String
    ) async throws -> Data {
        var request = authorizedRequest(url: url, method: method, token: token)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NoteRouteRequestError(message: "\(service) did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NoteRouteRequestError(message: failureMessage(data: data, status: http.statusCode, service: service))
        }
        return data
    }

    private func authorizedRequest(url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func failureMessage(data: Data, status: Int, service: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let detail = (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? (object["error_description"] as? String)
            if let detail, detail.isEmpty == false {
                return "\(service) request failed (\(status)): \(detail.prefix(300))"
            }
        }
        return "\(service) request failed (\(status))."
    }

    private func decodeProjects(from data: Data) throws -> (projects: [NoteRouteTodoistProject], nextCursor: String?) {
        let json = try JSONSerialization.jsonObject(with: data)
        if let rows = json as? [[String: Any]] {
            return (rows.compactMap(Self.project(from:)), nil)
        }
        if let object = json as? [String: Any] {
            let rows = object["results"] as? [[String: Any]] ?? []
            return (rows.compactMap(Self.project(from:)), object["next_cursor"] as? String)
        }
        throw NoteRouteRequestError(message: "Todoist returned an unexpected project list.")
    }

    private static func project(from row: [String: Any]) -> NoteRouteTodoistProject? {
        let id: String?
        if let string = row["id"] as? String {
            id = string
        } else if let number = row["id"] as? Int {
            id = String(number)
        } else if let number = row["id"] as? NSNumber {
            id = number.stringValue
        } else {
            id = nil
        }
        guard let id, id.isEmpty == false, let name = row["name"] as? String, name.isEmpty == false else {
            return nil
        }
        return NoteRouteTodoistProject(id: id, name: name)
    }
}
