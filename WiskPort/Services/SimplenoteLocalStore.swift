import Compression
import Foundation

struct SimplenoteNoteDraft: Equatable, Sendable {
    let sourceID: String
    let content: String
    let tags: [String]
    let pinned: Bool
    let markdownEnabled: Bool
    let createdAt: Date
    let updatedAt: Date
}

enum SimplenoteImportError: LocalizedError, Equatable, Sendable {
    case storeNotFound
    case invalidStore
    case invalidJSON
    case missingNotesJSON
    case unreadableArchive

    var errorDescription: String? {
        switch self {
        case .storeNotFound:
            return "Couldn't find Simplenote notes on this Mac."
        case .invalidStore:
            return "The Simplenote store could not be read."
        case .invalidJSON:
            return "The Simplenote export is not valid JSON."
        case .missingNotesJSON:
            return "The export does not contain notes.json."
        case .unreadableArchive:
            return "The Simplenote zip archive could not be read."
        }
    }
}

enum SimplenoteLocalStore {
    static let bundleIdentifierSuffix = "com.automattic.SimplenoteMac"
    static let storeFileName = "Simplenote.storedata"

    static func defaultStoreURL(fileManager: FileManager = .default) -> URL? {
        let containers = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: containers,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for container in contents where container.lastPathComponent.hasSuffix(bundleIdentifierSuffix) {
            let store = container
                .appendingPathComponent("Data", isDirectory: true)
                .appendingPathComponent(storeFileName)
            if fileManager.fileExists(atPath: store.path) {
                return store
            }
        }
        return nil
    }

    static func loadActiveNotes(from url: URL, fileManager: FileManager = .default) throws -> [SimplenoteNoteDraft] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SimplenoteImportError.storeNotFound
        }

        if isDirectory.boolValue {
            let candidates = [
                url.appendingPathComponent("source", isDirectory: true).appendingPathComponent("notes.json"),
                url.appendingPathComponent("notes.json"),
            ]
            guard let jsonURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                throw SimplenoteImportError.missingNotesJSON
            }
            return try loadJSON(data: Data(contentsOf: jsonURL))
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        switch url.pathExtension.lowercased() {
        case "zip":
            return try loadZip(data: data)
        case "json":
            return try loadJSON(data: data)
        default:
            if url.lastPathComponent == storeFileName || url.pathExtension.lowercased() == "storedata" {
                return try loadStoreData(data)
            }
            return try loadJSON(data: data)
        }
    }

    static func loadStoreData(_ data: Data) throws -> [SimplenoteNoteDraft] {
        let collector = CoreDataNoteParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse() else {
            throw SimplenoteImportError.invalidStore
        }
        return collector.notes
    }

    static func loadJSON(data: Data) throws -> [SimplenoteNoteDraft] {
        let trimmed: Data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            trimmed = data.dropFirst(3)
        } else {
            trimmed = data
        }

        let decoder = JSONDecoder()
        if let file = try? decoder.decode(ExportFile.self, from: trimmed),
           file.activeNotes != nil || file.notes != nil || file.trashedNotes != nil {
            if let activeNotes = file.activeNotes {
                return activeNotes.compactMap(SimplenoteNoteDraft.init(export:))
            }
            if let notes = file.notes {
                return notes.filter { $0.isTrashed == false }.compactMap(SimplenoteNoteDraft.init(export:))
            }
            return []
        }
        if let notes = try? decoder.decode([ExportNote].self, from: trimmed) {
            return notes.filter { $0.isTrashed == false }.compactMap(SimplenoteNoteDraft.init(export:))
        }
        throw SimplenoteImportError.invalidJSON
    }

    static func loadZip(data: Data) throws -> [SimplenoteNoteDraft] {
        let files = try SimplenoteZipArchive.files(in: data)
        let preferred = files.first { $0.name.lowercased() == "source/notes.json" }
            ?? files.first { $0.name.lowercased().hasSuffix("/notes.json") }
            ?? files.first { $0.name.lowercased() == "notes.json" }
        guard let preferred else {
            throw SimplenoteImportError.missingNotesJSON
        }
        return try loadJSON(data: preferred.data)
    }
}

private struct ExportFile: Decodable {
    var activeNotes: [ExportNote]?
    var trashedNotes: [ExportNote]?
    var notes: [ExportNote]?
}

private struct ExportNote: Decodable {
    var id: String?
    var key: String?
    var content: String?
    var tags: [String]?
    var pinned: Bool?
    var markdown: Bool?
    var deleted: Bool?
    var systemTags: [String]?
    var creationDate: FlexibleDate?
    var lastModified: FlexibleDate?
    var modificationDate: FlexibleDate?

    var isTrashed: Bool { deleted == true }

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case content
        case tags
        case pinned
        case markdown
        case deleted
        case systemTags
        case systemtags
        case creationDate
        case lastModified
        case modificationDate
        case modifyDate
        case createdate
        case modificationdate
        case simperiumKey
        case simperiumkey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .simperiumKey)
            ?? container.decodeIfPresent(String.self, forKey: .simperiumkey)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
        markdown = try container.decodeIfPresent(Bool.self, forKey: .markdown)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted)
        systemTags = try container.decodeIfPresent([String].self, forKey: .systemTags)
            ?? container.decodeIfPresent([String].self, forKey: .systemtags)
        creationDate = try container.decodeIfPresent(FlexibleDate.self, forKey: .creationDate)
            ?? container.decodeIfPresent(FlexibleDate.self, forKey: .createdate)
        lastModified = try container.decodeIfPresent(FlexibleDate.self, forKey: .lastModified)
            ?? container.decodeIfPresent(FlexibleDate.self, forKey: .modificationDate)
            ?? container.decodeIfPresent(FlexibleDate.self, forKey: .modifyDate)
            ?? container.decodeIfPresent(FlexibleDate.self, forKey: .modificationdate)
    }
}

private struct FlexibleDate: Decodable {
    var date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            date = Self.date(fromNumeric: value)
            return
        }
        if let value = try? container.decode(Int.self) {
            date = Self.date(fromNumeric: Double(value))
            return
        }
        let raw = try container.decode(String.self)
        if let parsed = Self.parseISO8601(raw) {
            date = parsed
            return
        }
        if let value = Double(raw) {
            date = Self.date(fromNumeric: value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized Simplenote date.")
    }

    static func date(fromNumeric value: Double) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        if value > 1_000_000_000 {
            return Date(timeIntervalSince1970: value)
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private extension SimplenoteNoteDraft {
    init?(export note: ExportNote) {
        guard note.isTrashed == false else { return nil }
        let content = note.content ?? ""
        let createdAt = note.creationDate?.date ?? Date()
        let updatedAt = note.lastModified?.date ?? note.modificationDate?.date ?? createdAt
        let sourceID = [
            note.id,
            note.key,
        ]
        .compactMap { $0?.nilIfBlank }
        .first { !$0.isEmpty }
            ?? "anon-\(createdAt.timeIntervalSinceReferenceDate)-\(content.count)"
        let systemTags = note.systemTags ?? []
        self.init(
            sourceID: sourceID,
            content: content,
            tags: note.tags ?? [],
            pinned: note.pinned ?? false,
            markdownEnabled: note.markdown ?? systemTags.contains { $0.caseInsensitiveCompare("markdown") == .orderedSame },
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private final class CoreDataNoteParser: NSObject, XMLParserDelegate {
    private(set) var notes: [SimplenoteNoteDraft] = []

    private var objectType = ""
    private var attributeName = ""
    private var text = ""
    private var fields: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "object" {
            objectType = attributeDict["type"] ?? ""
            fields = [:]
            text = ""
            return
        }
        if elementName == "attribute" {
            attributeName = attributeDict["name"] ?? ""
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) {
            text += value
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "attribute" {
            fields[attributeName.lowercased()] = text
            attributeName = ""
            text = ""
            return
        }
        guard elementName == "object" else { return }
        if objectType.caseInsensitiveCompare("NOTE") == .orderedSame,
           let note = SimplenoteNoteDraft(coreDataFields: fields) {
            notes.append(note)
        }
        objectType = ""
        fields = [:]
    }
}

private extension SimplenoteNoteDraft {
    init?(coreDataFields fields: [String: String]) {
        if Self.boolValue(fields["deleted"]) {
            return nil
        }
        let content = fields["content"] ?? ""
        let createdAt = Self.dateValue(fields["creationdate"]) ?? Date()
        let updatedAt = Self.dateValue(fields["modificationdate"]) ?? createdAt
        let sourceID = fields["simperiumkey"]?.nilIfBlank
            ?? "anon-\(createdAt.timeIntervalSinceReferenceDate)-\(content.count)"
        let tags = Self.stringArray(fields["tags"])
        let systemTags = Self.stringArray(fields["systemtags"])
        let markdownFlag = Self.boolValue(fields["markdown"])
            || systemTags.contains { $0.caseInsensitiveCompare("markdown") == .orderedSame }
        self.init(
            sourceID: sourceID,
            content: content,
            tags: tags,
            pinned: Self.boolValue(fields["pinned"]),
            markdownEnabled: markdownFlag,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func boolValue(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }

    static func dateValue(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let value = Double(raw) {
            return FlexibleDate.date(fromNumeric: value)
        }
        return FlexibleDate.parseISO8601(raw)
    }

    static func stringArray(_ raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }
        if let data = raw.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            return values
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum SimplenoteZipArchive {
    struct File {
        let name: String
        let data: Data
    }

    static func files(in data: Data) throws -> [File] {
        var offset = 0
        var files: [File] = []
        while offset + 30 <= data.count {
            let signature = data.u32(offset)
            if signature == 0x02014B50 || signature == 0x06054B50 {
                break
            }
            guard signature == 0x04034B50 else {
                throw SimplenoteImportError.unreadableArchive
            }

            let flags = data.u16(offset + 6)
            let method = data.u16(offset + 8)
            let compressedSize = Int(data.u32(offset + 18))
            let uncompressedSize = Int(data.u32(offset + 22))
            let nameLength = Int(data.u16(offset + 26))
            let extraLength = Int(data.u16(offset + 28))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard dataStart <= data.count else {
                throw SimplenoteImportError.unreadableArchive
            }
            if flags & 0x08 != 0 && compressedSize == 0 {
                throw SimplenoteImportError.unreadableArchive
            }
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else {
                throw SimplenoteImportError.unreadableArchive
            }

            let nameData = data.subdata(in: nameStart..<nameStart + nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            if name.hasSuffix("/") == false {
                let payload = data.subdata(in: dataStart..<dataEnd)
                let fileData = try decompress(payload, method: method, uncompressedSize: uncompressedSize)
                files.append(File(name: name, data: fileData))
            }
            offset = dataEnd
        }
        return files
    }

    static func decompress(_ payload: Data, method: UInt16, uncompressedSize: Int) throws -> Data {
        switch method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, uncompressedSize: uncompressedSize)
        default:
            throw SimplenoteImportError.unreadableArchive
        }
    }

    static func inflate(_ payload: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let decodedCount = output.withUnsafeMutableBytes { outRaw -> Int in
            payload.withUnsafeBytes { inRaw -> Int in
                guard let inBase = inRaw.bindMemory(to: UInt8.self).baseAddress,
                      let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    outBase,
                    uncompressedSize,
                    inBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == uncompressedSize else {
            throw SimplenoteImportError.unreadableArchive
        }
        return output
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
