import Foundation
import UniformTypeIdentifiers

enum WiskShareInbox {
    static var appGroupID: String {
        #if DEV_BUILD
        "group.com.schybo.wisk.dev"
        #else
        "group.com.schybo.wisk"
        #endif
    }

    static let inboxDirectoryName = "ShareInbox"
    static let payloadExtension = "json"

    struct Item: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var body: String
        var imageFileNames: [String]
        var createdAt: Date
    }

    struct Draft: Equatable, Sendable {
        var title: String
        var body: String
    }

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func inboxDirectory(in container: URL) -> URL {
        container.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    static func makeDraft(text: String?, url: URL?) -> Draft {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url {
            let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
            if trimmedText.isEmpty {
                return Draft(title: host.isEmpty ? "Shared link" : host, body: url.absoluteString)
            }
            let split = splitTitleAndBody(trimmedText)
            let body = split.body.isEmpty ? url.absoluteString : "\(split.body)\n\n\(url.absoluteString)"
            return Draft(title: split.title, body: body)
        }
        if trimmedText.isEmpty == false {
            return splitTitleAndBody(trimmedText)
        }
        return Draft(title: "Shared image", body: "")
    }

    static func write(
        title: String,
        body: String,
        images: [Data],
        fileManager: FileManager = .default,
        containerURL: URL? = nil
    ) throws -> Item {
        guard let container = containerURL ?? Self.containerURL(fileManager: fileManager) else {
            throw WiskShareInboxError.containerUnavailable
        }
        let inbox = inboxDirectory(in: container)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let itemID = UUID()
        var fileNames: [String] = []
        for (index, image) in images.enumerated() {
            let fileName = "\(itemID.uuidString)-\(index).jpg"
            try image.write(to: inbox.appendingPathComponent(fileName), options: .atomic)
            fileNames.append(fileName)
        }
        let resolvedTitle: String
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTitle = fileNames.isEmpty ? "Untitled" : (fileNames.count == 1 ? "Shared image" : "Shared images")
        } else {
            resolvedTitle = title
        }
        let item = Item(
            id: itemID,
            title: resolvedTitle,
            body: body,
            imageFileNames: fileNames,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)
        try data.write(
            to: inbox.appendingPathComponent("\(itemID.uuidString).\(payloadExtension)"),
            options: .atomic
        )
        return item
    }

    static func consumePendingItems(
        fileManager: FileManager = .default,
        containerURL: URL? = nil
    ) throws -> [(item: Item, imageData: [Data])] {
        guard let container = containerURL ?? Self.containerURL(fileManager: fileManager) else {
            return []
        }
        let inbox = inboxDirectory(in: container)
        guard fileManager.fileExists(atPath: inbox.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == payloadExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [(item: Item, imageData: [Data])] = []
        for fileURL in files {
            do {
                let item = try decoder.decode(Item.self, from: Data(contentsOf: fileURL))
                let images = item.imageFileNames.compactMap { name -> Data? in
                    try? Data(contentsOf: inbox.appendingPathComponent(name))
                }
                results.append((item, images))
                try? fileManager.removeItem(at: fileURL)
                for name in item.imageFileNames {
                    try? fileManager.removeItem(at: inbox.appendingPathComponent(name))
                }
            } catch {
                try? fileManager.removeItem(at: fileURL)
            }
        }
        return results
    }

    private static func splitTitleAndBody(_ content: String) -> Draft {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let titleIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            return Draft(title: "Untitled", body: "")
        }
        let title = lines[titleIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = lines.suffix(from: titleIndex + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Draft(title: title, body: remaining)
    }
}

enum WiskShareInboxError: Error, LocalizedError, Equatable {
    case containerUnavailable

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "Wisk could not open its shared notes inbox."
        }
    }
}
