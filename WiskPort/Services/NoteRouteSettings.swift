import Foundation
import Observation

@Observable
final class NoteRouteSettings {
    static let shared = NoteRouteSettings()

    private let defaults: UserDefaults

    var schyboBaseURL: String {
        didSet { defaults.set(schyboBaseURL, forKey: Key.schyboBaseURL) }
    }

    var mappings: [NoteRouteMapping] {
        didSet { persist(mappings, key: Key.mappings) }
    }

    private(set) var todoistProjects: [NoteRouteTodoistProject]
    private(set) var todoistToken: String?
    private(set) var schyboToken: String?

    var isTodoistConnected: Bool { todoistToken?.nilIfBlank != nil }
    var isSchyboConnected: Bool { schyboToken?.nilIfBlank != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        schyboBaseURL = defaults.string(forKey: Key.schyboBaseURL)?.nilIfBlank ?? NoteLineRouter.defaultSchyboBaseURL
        mappings = Self.load([NoteRouteMapping].self, key: Key.mappings, defaults: defaults) ?? []
        todoistProjects = Self.load([NoteRouteTodoistProject].self, key: Key.todoistProjects, defaults: defaults) ?? []
        todoistToken = WiskKeychain.read(account: WiskKeychain.todoistAccount)
        schyboToken = WiskKeychain.read(account: WiskKeychain.schyboAccount)
    }

    func saveTodoistConnection(token: String, projects: [NoteRouteTodoistProject]) throws {
        try WiskKeychain.save(token, account: WiskKeychain.todoistAccount)
        todoistToken = token
        todoistProjects = projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist(todoistProjects, key: Key.todoistProjects)
    }

    func disconnectTodoist() {
        WiskKeychain.delete(account: WiskKeychain.todoistAccount)
        todoistToken = nil
        todoistProjects = []
        defaults.removeObject(forKey: Key.todoistProjects)
    }

    func saveSchyboConnection(token: String) throws {
        try WiskKeychain.save(token, account: WiskKeychain.schyboAccount)
        schyboToken = token
    }

    func disconnectSchybo() {
        WiskKeychain.delete(account: WiskKeychain.schyboAccount)
        schyboToken = nil
    }

    func lessonsURL() -> URL? {
        NoteRouteHTTPClient.lessonsURL(from: schyboBaseURL)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Key {
        static let mappings = "wisk.route.mappings"
        static let schyboBaseURL = "wisk.route.schyboBaseURL"
        static let todoistProjects = "wisk.route.todoistProjects"
    }
}
