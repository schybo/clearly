import Foundation

struct WiskFirestoreBackupManifest: Codable, Equatable, Sendable {
    var uid: String
    var createdAt: Date
    var noteCount: Int
    var bucketCount: Int
}

enum WiskFirestoreLocalBackup {
    static let notesFileName = "notes.json"
    static let bucketsFileName = "buckets.json"
    static let adagesFileName = "adages.json"
    static let manifestFileName = "metadata.json"

    static func shouldDump(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isMac: Bool = {
            #if os(macOS)
            true
            #else
            false
            #endif
        }()
    ) -> Bool {
        guard isMac else { return false }
        return WiskModelContainer.shouldIsolateStore(environment: environment) == false
    }

    static func firestoreRoot(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.schybo.wisk"
    ) -> URL {
        WiskBackupLayout.firestoreRoot(
            forStoreURL: WiskModelContainer.productionStoreURL(
                fileManager: fileManager,
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    @discardableResult
    static func writeDump(
        uid: String,
        notes: [FirestoreNoteDocument],
        buckets: [FirestoreBucketDocument],
        adages: [FirestoreAdageDocument] = [],
        backupsRoot: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        documentsMirrorRoot: URL? = nil
    ) throws -> URL? {
        if WiskBackupLayout.hasFreshSnapshot(in: backupsRoot, now: now, fileManager: fileManager) {
            return nil
        }
        if WiskBackupLayout.shouldSkipShrunkenDump(
            noteCount: notes.count,
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
        let encoder = jsonEncoder()
        try encoder.encode(notes).write(
            to: destination.appendingPathComponent(notesFileName),
            options: .atomic
        )
        try encoder.encode(buckets).write(
            to: destination.appendingPathComponent(bucketsFileName),
            options: .atomic
        )
        try encoder.encode(adages).write(
            to: destination.appendingPathComponent(adagesFileName),
            options: .atomic
        )
        let manifest = WiskFirestoreBackupManifest(
            uid: uid,
            createdAt: now,
            noteCount: notes.count,
            bucketCount: buckets.count
        )
        try encoder.encode(manifest).write(
            to: destination.appendingPathComponent(manifestFileName),
            options: .atomic
        )
        try WiskBackupLayout.pruneSnapshots(in: backupsRoot, fileManager: fileManager)
        if let documentsMirrorRoot {
            _ = WiskBackupLayout.copyTimestampDirectories(
                from: backupsRoot,
                to: documentsMirrorRoot,
                fileManager: fileManager
            )
            try WiskBackupLayout.pruneSnapshots(in: documentsMirrorRoot, fileManager: fileManager)
        }
        return destination
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
