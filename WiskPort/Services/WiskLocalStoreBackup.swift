import Foundation

enum WiskLocalStoreBackup {
    static let storeFileSuffixes = WiskBackupLayout.storeFileSuffixes

    static func snapshotLiveStoreIfNeeded(
        storeURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL? {
        guard shouldSnapshot(
            storeURL: storeURL,
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }
        try WiskBackupLayout.migrateLegacySnapshotsIfNeeded(
            storeURL: storeURL,
            fileManager: fileManager
        )
        return try snapshotStoreFiles(
            storeURL: storeURL,
            backupsRoot: WiskBackupLayout.backupsRoot(forStoreURL: storeURL, fileManager: fileManager),
            fileManager: fileManager,
            now: now
        )
    }

    static func shouldSnapshot(
        storeURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        guard WiskModelContainer.shouldIsolateStore(environment: environment) == false else {
            return false
        }
        guard WiskModelContainer.isLiveUserStore(storeURL, fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(atPath: storeURL.path)
    }

    @discardableResult
    static func snapshotStoreFiles(
        storeURL: URL,
        backupsRoot: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }
        if WiskBackupLayout.hasFreshSnapshot(in: backupsRoot, now: now, fileManager: fileManager) {
            return nil
        }
        if WiskBackupLayout.shouldSkipShrunkenStore(
            storeURL: storeURL,
            backupsRoot: backupsRoot,
            fileManager: fileManager
        ) {
            return nil
        }

        var destination = backupsRoot.appendingPathComponent(
            WiskBackupLayout.timestamp(from: now),
            isDirectory: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            destination = backupsRoot.appendingPathComponent(
                "\(WiskBackupLayout.timestamp(from: now))-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for suffix in storeFileSuffixes {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(
                at: source,
                to: destination.appendingPathComponent(source.lastPathComponent)
            )
        }
        try WiskBackupLayout.pruneSnapshots(in: backupsRoot, fileManager: fileManager)
        return destination
    }
}
