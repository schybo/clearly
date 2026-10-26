import Foundation
import SwiftData

enum WiskStoreOpenError: Error, LocalizedError {
    case refusedLiveStore(URL)

    var errorDescription: String? {
        switch self {
        case .refusedLiveStore(let url):
            return "Refused to open the live Wisk note store at \(url.path) from a test launch."
        }
    }
}

enum WiskModelContainer {
    static let modelTypes: [any PersistentModel.Type] = [
        Note.self,
        NoteVersion.self,
        NoteTag.self,
        NoteProject.self,
        NoteBucket.self,
        DailyNote.self,
        ParsedNoteItem.self,
        SyncMutation.self,
        SyncConflict.self,
        NoteShare.self,
        PublishedNote.self,
        NoteAttachment.self,
        NoteLibraryRecord.self,
        Adage.self,
    ]

    static func makeInMemory() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(modelTypes),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        let schema = Schema(modelTypes)
        if let url = isolatedStoreURL(environment: environment, fileManager: fileManager) {
            try rejectLiveStoreIfTestLaunch(url, environment: environment, fileManager: fileManager)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let configuration = ModelConfiguration(url: url)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        #if os(macOS)
        try migrateLegacyUnscopedStoreIfNeeded(fileManager: fileManager)
        let url = productionStoreURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        snapshotLiveStoresIfNeeded(
            [url],
            environment: environment,
            fileManager: fileManager
        )
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)])
        #else
        snapshotLiveStoresIfNeeded(
            [
                productionStoreURL(fileManager: fileManager),
                legacyUnscopedStoreURL(fileManager: fileManager),
            ],
            environment: environment,
            fileManager: fileManager
        )
        return try ModelContainer(for: schema)
        #endif
    }

    private static func snapshotLiveStoresIfNeeded(
        _ urls: [URL],
        environment: [String: String],
        fileManager: FileManager
    ) {
        var seen = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            do {
                _ = try WiskLocalStoreBackup.snapshotLiveStoreIfNeeded(
                    storeURL: url,
                    environment: environment,
                    fileManager: fileManager
                )
            } catch {
                // Opening the library matters more than a failed snapshot.
            }
        }
    }

    static func makeOrFatal(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ModelContainer {
        do {
            return try make(environment: environment)
        } catch {
            fatalError("Wisk could not open its note store: \(error.localizedDescription)")
        }
    }

    static func isolatedStoreURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let rawValue = environment["WISK_STORE_URL"]?.nilIfBlank {
            return URL(fileURLWithPath: rawValue)
        }
        guard shouldIsolateStore(environment: environment) else { return nil }
        let uid = environment["WISK_SYNC_TEST_UID"]?.nilIfBlank ?? "default"
        return fileManager.temporaryDirectory
            .appendingPathComponent("WiskUITests-\(uid)", isDirectory: true)
            .appendingPathComponent("default.store")
    }

    static func shouldIsolateStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["WISK_SYNC_TEST_MODE"] == "1"
            || environment["WISK_RESET_LOCAL_STORE"] == "1"
            || environment["WISK_STORE_URL"]?.nilIfBlank != nil
            || environment["WISK_FORCE_SIGN_OUT"] == "1"
            || environment["WISK_BYPASS_AUTH"] == "1"
        {
            return true
        }
        return environment["XCTestConfigurationFilePath"] != nil
    }

    static func productionStoreURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.schybo.wisk"
    ) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("default.store")
    }

    static func legacyUnscopedStoreURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("default.store")
    }

    static func isLiveUserStore(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let livePaths = [
            productionStoreURL(fileManager: fileManager).standardizedFileURL.path,
            legacyUnscopedStoreURL(fileManager: fileManager).standardizedFileURL.path,
        ]
        return livePaths.contains(path)
    }

    static func allowsDestructiveReset(
        storeURL: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        guard environment["WISK_RESET_LOCAL_STORE"] == "1" else { return false }
        guard let storeURL, isLiveUserStore(storeURL, fileManager: fileManager) == false else {
            return false
        }
        guard let isolated = isolatedStoreURL(environment: environment, fileManager: fileManager) else {
            return false
        }
        return storeURL.standardizedFileURL.path == isolated.standardizedFileURL.path
    }

    static func migrateLegacyUnscopedStoreIfNeeded(fileManager: FileManager = .default) throws {
        let destination = productionStoreURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.fileExists(atPath: destination.path) == false else { return }
        let legacy = legacyUnscopedStoreURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        guard legacyStoreLooksLikeWisk(legacy) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacy.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(
                at: source,
                to: URL(fileURLWithPath: destination.path + suffix)
            )
        }
    }

    /// `default.store` in unsandboxed Application Support is shared by any SwiftData
    /// Mac app that omits a URL. Kite already collided with Wisk there (`ZWORKSPACERECORD`).
    private static func legacyStoreLooksLikeWisk(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        let bytes = data
        return bytes.range(of: Data("ZNOTE".utf8)) != nil
            && bytes.range(of: Data("ZSYNCMUTATION".utf8)) != nil
    }

    private static func rejectLiveStoreIfTestLaunch(
        _ url: URL,
        environment: [String: String],
        fileManager: FileManager
    ) throws {
        guard shouldIsolateStore(environment: environment) else { return }
        if isLiveUserStore(url, fileManager: fileManager) {
            throw WiskStoreOpenError.refusedLiveStore(url)
        }
    }
}
