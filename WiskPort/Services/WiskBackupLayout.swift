import Foundation

enum WiskBackupLayout {
    static let keepCount = 10
    static let snapshotInterval: TimeInterval = 6 * 60 * 60
    static let minimumKeepRatio = 0.25
    static let backupsDirectoryName = "backups"
    static let backupsDirectorySuffix = ".backups"
    static let firestoreDirectoryName = "firestore"
    static let documentsBackupFolderName = "Wisk Backups"
    static let timestampFormat = "yyyyMMdd-HHmmss"
    static let storeFileName = "default.store"
    static let storeFileSuffixes = ["", "-wal", "-shm"]

    static func backupsRoot(
        forStoreURL storeURL: URL,
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.schybo.wisk"
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].standardizedFileURL
        let storeDirectory = storeURL.deletingLastPathComponent().standardizedFileURL
        if storeDirectory.path == applicationSupport.path {
            return applicationSupport.appendingPathComponent(
                "\(bundleIdentifier)\(backupsDirectorySuffix)",
                isDirectory: true
            )
        }
        return URL(fileURLWithPath: storeDirectory.path + backupsDirectorySuffix, isDirectory: true)
    }

    static func legacyBackupsRoot(forStoreURL storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(
            backupsDirectoryName,
            isDirectory: true
        )
    }

    static func firestoreRoot(forStoreURL storeURL: URL) -> URL {
        backupsRoot(forStoreURL: storeURL).appendingPathComponent(
            firestoreDirectoryName,
            isDirectory: true
        )
    }

    static func legacyFirestoreRoot(forStoreURL storeURL: URL) -> URL {
        legacyBackupsRoot(forStoreURL: storeURL).appendingPathComponent(
            firestoreDirectoryName,
            isDirectory: true
        )
    }

    static func documentsFirestoreRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(documentsBackupFolderName, isDirectory: true)
            .appendingPathComponent(firestoreDirectoryName, isDirectory: true)
    }

    static func timestamp(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(fromTimestamp rawValue: String) -> Date? {
        formatter.date(from: rawValue)
    }

    static func snapshotDirectories(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { url in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return false
                }
                return date(fromTimestamp: url.lastPathComponent) != nil
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    static func hasFreshSnapshot(
        in root: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard let newest = snapshotDirectories(in: root, fileManager: fileManager).first,
              let createdAt = date(fromTimestamp: newest.lastPathComponent)
        else {
            return false
        }
        return now.timeIntervalSince(createdAt) < snapshotInterval
    }

    static func pruneSnapshots(
        in root: URL,
        keep: Int = keepCount,
        fileManager: FileManager = .default
    ) throws {
        let directories = snapshotDirectories(in: root, fileManager: fileManager)
        guard directories.count > keep else { return }
        for stale in directories.dropFirst(keep) {
            try fileManager.removeItem(at: stale)
        }
    }

    static func byteCount(
        ofStoreFilesAt storeURL: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        storeFileSuffixes.reduce(into: Int64(0)) { total, suffix in
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard let values = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = values[.size] as? NSNumber
            else { return }
            total += size.int64Value
        }
    }

    static func byteCount(
        ofSnapshotAt snapshotURL: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        byteCount(
            ofStoreFilesAt: snapshotURL.appendingPathComponent(storeFileName),
            fileManager: fileManager
        )
    }

    static func shouldSkipShrunkenStore(
        storeURL: URL,
        backupsRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let current = byteCount(ofStoreFilesAt: storeURL, fileManager: fileManager)
        if current == 0 {
            return snapshotDirectories(in: backupsRoot, fileManager: fileManager).isEmpty == false
        }
        guard let newest = snapshotDirectories(in: backupsRoot, fileManager: fileManager).first else {
            return false
        }
        let previous = byteCount(ofSnapshotAt: newest, fileManager: fileManager)
        guard previous > 0 else { return false }
        return Double(current) < Double(previous) * minimumKeepRatio
    }

    static func shouldSkipShrunkenDump(
        noteCount: Int,
        backupsRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let newest = snapshotDirectories(in: backupsRoot, fileManager: fileManager).first else {
            return false
        }
        let manifestURL = newest.appendingPathComponent(WiskFirestoreLocalBackup.manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? WiskFirestoreLocalBackup.jsonDecoder().decode(
                WiskFirestoreBackupManifest.self,
                from: data
              )
        else {
            return false
        }
        guard manifest.noteCount > 0 else { return false }
        return Double(noteCount) < Double(manifest.noteCount) * minimumKeepRatio
    }

    @discardableResult
    static func migrateLegacySnapshotsIfNeeded(
        storeURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let current = backupsRoot(forStoreURL: storeURL)
        let legacy = legacyBackupsRoot(forStoreURL: storeURL)
        var copied = copyTimestampDirectories(
            from: legacy,
            to: current,
            fileManager: fileManager
        )
        copied = copyTimestampDirectories(
            from: legacyFirestoreRoot(forStoreURL: storeURL),
            to: firestoreRoot(forStoreURL: storeURL),
            fileManager: fileManager
        ) || copied
        return copied
    }

    @discardableResult
    static func copyTimestampDirectories(
        from sourceRoot: URL,
        to destinationRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let sources = snapshotDirectories(in: sourceRoot, fileManager: fileManager)
        guard sources.isEmpty == false else { return false }
        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            return false
        }
        var copied = false
        for source in sources {
            let destination = destinationRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            guard fileManager.fileExists(atPath: destination.path) == false else { continue }
            do {
                try fileManager.copyItem(at: source, to: destination)
                copied = true
            } catch {
                continue
            }
        }
        return copied
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = timestampFormat
        return formatter
    }()
}
