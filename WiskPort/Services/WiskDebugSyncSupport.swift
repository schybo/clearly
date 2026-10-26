import Foundation
import SwiftData

#if DEBUG
import FirebaseAuth
import FirebaseFirestore
#endif

enum WiskDebugSyncDefaults {
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        #if DEBUG
        if let suiteName = suiteName(environment: environment) {
            return UserDefaults(suiteName: suiteName) ?? .standard
        }
        #endif
        return .standard
    }

    static func suiteName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        #if DEBUG
        guard environment["WISK_SYNC_TEST_MODE"] == "1" else { return nil }
        let uid = environment["WISK_SYNC_TEST_UID"]?.nilIfBlank ?? "default"
        return "wisk.uitests.\(uid)"
        #else
        return nil
        #endif
    }
}

enum WiskDebugSyncConfiguration {
    #if DEBUG
    static var syncTestCredentials: (email: String, password: String)? {
        guard let email = environment["WISK_SYNC_TEST_EMAIL"]?.nilIfBlank,
              let password = environment["WISK_SYNC_TEST_PASSWORD"]?.nilIfBlank else {
            return nil
        }
        return (email, password)
    }

    static func configureFirebaseEmulatorsIfNeeded() {
        guard environment["WISK_USE_FIRESTORE_EMULATOR"] == "1" else { return }

        let firestoreHost = environment["WISK_FIRESTORE_EMULATOR_HOST"]?.nilIfBlank ?? "127.0.0.1:8080"
        let authHost = environment["WISK_AUTH_EMULATOR_HOST"]?.nilIfBlank ?? "127.0.0.1:9099"

        Auth.auth().useEmulator(withHost: authHost.hostPart, port: authHost.portPart(default: 9099))

        let settings = Firestore.firestore().settings
        settings.host = firestoreHost
        settings.isSSLEnabled = false
        Firestore.firestore().settings = settings
    }
    #else
    static func configureFirebaseEmulatorsIfNeeded() {}
    #endif

    #if DEBUG
    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }
    #endif
}

@MainActor
enum WiskDebugSyncHarness {
    #if DEBUG
    private static var didPrepare = false

    static var isActive: Bool {
        isActive(environment: ProcessInfo.processInfo.environment)
    }

    static func isActive(environment: [String: String]) -> Bool {
        environment["WISK_SYNC_TEST_MODE"] == "1"
    }

    /// Test and debug launches may talk to Firestore only through the emulator.
    /// `WISK_BYPASS_AUTH` always skips remote sync, even if the emulator flag is set.
    static func allowsRemoteSync(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["WISK_USE_FIRESTORE_EMULATOR"] == "1"
            && environment["WISK_BYPASS_AUTH"] != "1"
    }

    static func resetPrepareStateForTests() {
        didPrepare = false
    }

    @discardableResult
    static func prepareIfNeeded(
        context: ModelContext,
        syncService: SyncService,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Bool {
        guard isActive(environment: environment) else { return false }
        guard !didPrepare else { return true }
        didPrepare = true
        let allowsRemote = allowsRemoteSync(environment: environment)

        do {
            if allowsRemote {
                try await waitForDebugAuthIfNeeded()
            }

            if environment["WISK_RESET_LOCAL_STORE"] == "1" {
                let storeURL = context.container.configurations.first?.url
                guard WiskModelContainer.allowsDestructiveReset(
                    storeURL: storeURL,
                    environment: environment
                ) else {
                    try writeMarker(payload: [
                        "ok": false,
                        "error": "Refused to reset the default Wisk note store.",
                    ], environment: environment)
                    return true
                }
                try resetLocalStore(context: context)
                resetIsolatedSyncDefaults(environment: environment)
            }

            _ = try NoteBucketSeedService.ensureDefaultTasksBucket(context: context)

            if let title = environment["WISK_SYNC_TEST_SEED_TITLE"]?.nilIfBlank {
                try seedNoteIfNeeded(
                    title: title,
                    context: context,
                    syncService: syncService,
                    enqueueForRemote: allowsRemote,
                    environment: environment
                )
            }

            if allowsRemote {
                await syncService.syncNow(context: context)
            } else {
                try writeMarker(payload: [
                    "ok": true,
                    "skippedRemoteSync": true,
                    "reason": "Refused production Firestore from a test launch.",
                ], environment: environment)
            }
            try writeMarkerIfRequested(
                context: context,
                syncState: syncService.state,
                skippedRemoteSync: allowsRemote == false,
                environment: environment
            )
        } catch {
            try? writeMarker(payload: [
                "ok": false,
                "error": error.localizedDescription,
            ], environment: environment)
        }

        return true
    }

    private static func waitForDebugAuthIfNeeded() async throws {
        guard let credentials = WiskDebugSyncConfiguration.syncTestCredentials else { return }

        for _ in 0..<100 {
            if Auth.auth().currentUser?.email == credentials.email {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SyncServiceError.requestFailed("Timed out waiting for sync test auth.")
    }

    private static func seedNoteIfNeeded(
        title: String,
        context: ModelContext,
        syncService: SyncService,
        enqueueForRemote: Bool,
        environment: [String: String]
    ) throws {
        let body = environment["WISK_SYNC_TEST_SEED_BODY"]?.nilIfBlank ?? "Created by Wisk sync smoke test."
        let kind = environment["WISK_SYNC_TEST_SEED_KIND"]
            .flatMap(NoteKind.init(rawValue:)) ?? .general
        let notes = try context.fetch(FetchDescriptor<Note>())
        guard notes.contains(where: { $0.title == title && $0.deletedAt == nil }) == false else { return }

        let note = Note(title: title, body: body, kind: kind)
        if kind == .structured {
            note.markdownEnabled = true
        }
        note.snapshotIfNeeded(reason: "sync-smoke")
        context.insert(note)
        try context.save()
        if enqueueForRemote {
            syncService.enqueue(note: note, context: context)
        }
    }

    private static func resetLocalStore(context: ModelContext) throws {
        try context.fetch(FetchDescriptor<SyncConflict>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<SyncMutation>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<PublishedNote>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<NoteShare>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ParsedNoteItem>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<DailyNote>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<NoteBucket>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<NoteAttachment>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Note>()).forEach(context.delete)
        try context.save()
    }

    private static func resetIsolatedSyncDefaults(environment: [String: String]) {
        guard let suiteName = WiskDebugSyncDefaults.suiteName(environment: environment) else { return }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func writeMarkerIfRequested(
        context: ModelContext,
        syncState: SyncService.State,
        skippedRemoteSync: Bool,
        environment: [String: String]
    ) throws {
        guard markerURL(environment: environment) != nil else { return }

        let notes = try context.fetch(FetchDescriptor<Note>())
        let titles = notes
            .filter { $0.deletedAt == nil }
            .map(\.title)
            .sorted()
        let expected = expectedTitles(environment: environment)
        let missing = expected.filter { titles.contains($0) == false }
        var payload: [String: Any] = [
            "ok": missing.isEmpty && (skippedRemoteSync || syncState == .idle),
            "titles": titles,
            "expectedTitles": expected,
            "missingTitles": missing,
            "syncState": String(describing: syncState),
        ]
        if skippedRemoteSync {
            payload["skippedRemoteSync"] = true
        }
        try writeMarker(payload: payload, environment: environment)
    }

    static func writeMarker(
        payload: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let markerURL = markerURL(environment: environment) else { return }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: markerURL, options: .atomic)
    }

    private static func expectedTitles(environment: [String: String]) -> [String] {
        environment["WISK_SYNC_TEST_EXPECT_TITLES"]?
            .split(separator: "|")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func markerURL(environment: [String: String]) -> URL? {
        guard let rawValue = environment["WISK_SYNC_TEST_MARKER_FILE"]?.nilIfBlank else { return nil }
        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents?.appendingPathComponent(rawValue)
    }
    #else
    static var isActive: Bool { false }

    @discardableResult
    static func prepareIfNeeded(context: ModelContext, syncService: SyncService) async -> Bool {
        false
    }
    #endif
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hostPart: String {
        split(separator: ":", maxSplits: 1).first.map(String.init) ?? self
    }

    func portPart(default defaultPort: Int) -> Int {
        guard let portString = split(separator: ":", maxSplits: 1).dropFirst().first,
              let port = Int(portString) else {
            return defaultPort
        }
        return port
    }
}
