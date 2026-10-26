import FirebaseFirestore
import os
import Foundation
import Observation
import SwiftData

@MainActor
protocol SyncAuthProviding: AnyObject {
    var firebaseUID: String? { get }
}

@MainActor
protocol SyncRemoteStore: AnyObject {
    func push(notes: [FirestoreNoteDocument], buckets: [FirestoreBucketDocument], uid: String) async throws
    func fetchNotes(since: Date?, uid: String) async throws -> [FirestoreNoteDocument]
    func fetchBuckets(since: Date?, uid: String) async throws -> [FirestoreBucketDocument]
    func pushAdages(_ adages: [FirestoreAdageDocument], uid: String) async throws
    func fetchAdages(since: Date?, uid: String) async throws -> [FirestoreAdageDocument]
}

extension SyncRemoteStore {
    func pushAdages(_ adages: [FirestoreAdageDocument], uid: String) async throws {}

    func fetchAdages(since: Date?, uid: String) async throws -> [FirestoreAdageDocument] { [] }
}

final class FirestoreSyncRemoteStore: SyncRemoteStore {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func push(notes: [FirestoreNoteDocument], buckets: [FirestoreBucketDocument], uid: String) async throws {
        guard !notes.isEmpty || !buckets.isEmpty else { return }

        let batch = db.batch()
        for note in notes {
            batch.setData(note.firestoreData, forDocument: notesCollection(uid: uid).document(note.id), merge: true)
        }
        for bucket in buckets {
            batch.setData(bucket.firestoreData, forDocument: bucketsCollection(uid: uid).document(bucket.id), merge: true)
        }
        try await batch.commit()
    }

    func fetchNotes(since: Date?, uid: String) async throws -> [FirestoreNoteDocument] {
        let snapshot: QuerySnapshot
        if let since {
            snapshot = try await notesCollection(uid: uid)
                .whereField("updatedAt", isGreaterThan: Timestamp(date: since))
                .getDocuments()
        } else {
            snapshot = try await notesCollection(uid: uid).getDocuments()
        }
        return snapshot.documents.compactMap {
            FirestoreNoteDocument(id: $0.documentID, data: $0.data())
        }
    }

    func fetchBuckets(since: Date?, uid: String) async throws -> [FirestoreBucketDocument] {
        let snapshot: QuerySnapshot
        if let since {
            snapshot = try await bucketsCollection(uid: uid)
                .whereField("updatedAt", isGreaterThan: Timestamp(date: since))
                .getDocuments()
        } else {
            snapshot = try await bucketsCollection(uid: uid).getDocuments()
        }
        return snapshot.documents.compactMap {
            FirestoreBucketDocument(id: $0.documentID, data: $0.data())
        }
    }

    private func notesCollection(uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("notes")
    }

    func pushAdages(_ adages: [FirestoreAdageDocument], uid: String) async throws {
        guard adages.isEmpty == false else { return }
        let collection = adagesCollection(uid: uid)
        var index = 0
        while index < adages.count {
            let batch = db.batch()
            let end = min(index + 400, adages.count)
            for adage in adages[index..<end] {
                batch.setData(adage.firestoreData, forDocument: collection.document(adage.id), merge: true)
            }
            try await batch.commit()
            index = end
        }
    }

    func fetchAdages(since: Date?, uid: String) async throws -> [FirestoreAdageDocument] {
        let snapshot: QuerySnapshot
        if let since {
            snapshot = try await adagesCollection(uid: uid)
                .whereField("updatedAt", isGreaterThan: Timestamp(date: since))
                .getDocuments()
        } else {
            snapshot = try await adagesCollection(uid: uid).getDocuments()
        }
        return snapshot.documents.compactMap {
            FirestoreAdageDocument(id: $0.documentID, data: $0.data())
        }
    }

    private func bucketsCollection(uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("buckets")
    }

    private func adagesCollection(uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("adages")
    }
}

@MainActor
@Observable
final class SyncService {
    enum State: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastSyncedAt: Date?
    /// The uid `lastSyncedAt` was resolved for. Lets `resolvedLastSyncedAt`
    /// tell "still the same signed-in account this session" apart from "just
    /// switched accounts" without re-reading UserDefaults on every call.
    private var lastSyncedUID: String?
    private let authService: SyncAuthProviding
    private let remoteStore: SyncRemoteStore
    private let deviceID: String
    private let defaults: UserDefaults
    /// Last time a full (`since: nil`) pull completed this session. Full pulls
    /// are the self-heal for notes whose `updatedAt` is frozen in the past, so
    /// they are rate-limited to once per `fullPullInterval` — Firestore bills
    /// one read per fetched note and the (default) database is still on the
    /// Spark free tier (~50k reads/day).
    private var lastFullPullAt: Date?

    init(
        authService: SyncAuthProviding,
        remoteStore: SyncRemoteStore = FirestoreSyncRemoteStore(),
        deviceID: String = SyncService.loadDeviceID(),
        defaults: UserDefaults = .standard
    ) {
        self.authService = authService
        self.remoteStore = remoteStore
        self.deviceID = deviceID
        self.defaults = defaults
    }

    func enqueue(note: Note, operation: BackendMutationOperation = .noteUpsert, context: ModelContext) {
        enqueue(notes: [note], operation: operation, context: context)
    }

    func enqueue(notes: [Note], operation: BackendMutationOperation = .noteUpsert, context: ModelContext) {
        guard notes.isEmpty == false else { return }
        do {
            try SyncMutationWriter.enqueue(notes: notes, operation: operation, context: context)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reportFailure(_ message: String) {
        state = .failed(message)
    }

    /// True when this device has already finished a successful sync for `uid`
    /// (in-memory watermark, or the persisted per-uid UserDefaults value).
    /// Does not write `lastSyncedAt`; call `hydrateAccountSyncWatermark()` from
    /// sync entry points, not from a SwiftUI `body`.
    func hasCompletedAccountSync(for uid: String? = nil) -> Bool {
        guard let resolvedUID = uid ?? authService.firebaseUID else { return false }
        return persistedLastSyncedAt(for: resolvedUID) != nil
    }

    var hasCompletedAccountSync: Bool {
        hasCompletedAccountSync(for: authService.firebaseUID)
    }

    /// Loads the current account's watermark into `lastSyncedAt` without
    /// starting a sync. Safe to call from `task` / `onAppear`, not from `body`.
    func hydrateAccountSyncWatermark() {
        guard let uid = authService.firebaseUID else { return }
        _ = resolvedLastSyncedAt(for: uid)
    }

    /// How far the incremental pull cursor is clamped back before querying.
    /// The cursor compares the *writer* device's local-clock `updatedAt`
    /// against this device's own clock; a reader whose clock runs ahead of the
    /// writer's would otherwise permanently skip edits pushed after its last
    /// poll (the watermark only ever advances). The margin bounds that miss.
    static let pullSkewGuard: TimeInterval = 600

    /// Minimum spacing between full (`since: nil`) pulls. Chosen so heavy
    /// all-day use stays well inside the Spark free tier (~50k reads/day at
    /// ~3.6k notes per full pull on this library).
    static let fullPullInterval: TimeInterval = 3 * 3600

    func syncNow(context: ModelContext, fullPull: Bool = false) async {
        guard state != .syncing else { return }
        hydrateAccountSyncWatermark()
        state = .syncing
        do {
            // Decide the full pull once, before the loop: repeat iterations
            // only happen when pushes remain pending, and re-fetching the
            // whole library for those would be pure waste.
            let now = Date()
            let consumeFullPull = fullPull && shouldFullPull(now: now)
            repeat {
                try SyncQueueRepair.queueLocalNotesForSync(context: context)
                let uid = try verifyAccountForUpload(context: context)
                let previousSync = resolvedLastSyncedAt(for: uid)
                try await pushPendingMutations(context: context, since: previousSync, uid: uid)
                let pullSince = consumeFullPull
                    ? nil
                    : previousSync?.addingTimeInterval(-Self.pullSkewGuard)
                try await pullChanges(since: pullSince, uid: uid, context: context)
                defaults.set(uid, forKey: Self.lastSyncedFirebaseUIDKey)
                updateLastSyncedAt(Date(), for: uid)
                await Task.yield()
            } while try hasPendingMutations(context: context)
            if consumeFullPull {
                lastFullPullAt = now
            }
            // Housekeeping: completed mutation rows are dead weight (the
            // note's own `syncStatus` governs recovery); drop ones past the
            // retention window. Non-fatal — pruning must not fail the sync.
            do {
                try SyncMutationWriter.pruneCompleted(context: context)
            } catch {
                Self.syncLog.error("mutation prune failed: \(error.localizedDescription, privacy: .public)")
            }
            state = .idle
        } catch {
            Self.syncLog.error("syncNow failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func shouldFullPull(now: Date) -> Bool {
        guard let lastFullPullAt else { return true }
        return now.timeIntervalSince(lastFullPullAt) >= Self.fullPullInterval
    }

    static let syncLog = Logger(subsystem: "com.schybo.wisk", category: "Sync")

    /// Resolves the sync watermark for `uid`, preferring the in-memory value
    /// from earlier this session but falling back to a value persisted in
    /// UserDefaults from a previous launch. Without this, `lastSyncedAt` was
    /// in-memory-only and reset to `nil` on every cold launch, forcing
    /// `pullChanges`/`bucketsForPush` into an unbounded `since: nil` fetch of
    /// the account's *entire* note and bucket history on every app open
    /// instead of an incremental pull. Scoping the persisted value by uid
    /// means switching accounts on one device can't reuse a stale watermark
    /// from a different user's data.
    private func persistedLastSyncedAt(for uid: String) -> Date? {
        if lastSyncedUID == uid {
            return lastSyncedAt
        }
        return defaults.object(forKey: Self.lastSyncedAtKey(for: uid)) as? Date
    }

    private func resolvedLastSyncedAt(for uid: String) -> Date? {
        let persisted = persistedLastSyncedAt(for: uid)
        if lastSyncedUID != uid {
            lastSyncedAt = persisted
            lastSyncedUID = uid
        }
        return persisted
    }

    private func updateLastSyncedAt(_ date: Date, for uid: String) {
        lastSyncedAt = date
        lastSyncedUID = uid
        defaults.set(date, forKey: Self.lastSyncedAtKey(for: uid))
    }

    private static func lastSyncedAtKey(for uid: String) -> String {
        "wisk.sync.lastSyncedAt.\(uid)"
    }

    /// Polls for remote changes made from other devices (there's no push
    /// listener for that path — local edits already sync immediately via
    /// the `enqueue` + `syncNow` call sites). 45s trades a little multi-device
    /// latency for roughly a third of the Firestore read volume 15s produced.
    func startAutomaticSync(context: ModelContext, interval: Duration = .seconds(45)) async {
        hydrateAccountSyncWatermark()
        await dumpRemoteLibraryIfNeeded()
        await syncNow(context: context)
        #if os(iOS)
        await NoteLibraryIndex.backfillIfNeededYielding(in: context)
        #endif

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            // Rate-limited by shouldFullPull inside syncNow: while the app stays
            // open past a launch this re-fetches the whole library at most once
            // per fullPullInterval, healing pushes that landed outside every
            // incremental window (stale `updatedAt` + late push) without a
            // relaunch. Budgeted in fullPullInterval's doc comment.
            await syncNow(context: context, fullPull: true)
        }
    }

    func dumpRemoteLibraryIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) async {
        guard WiskFirestoreLocalBackup.shouldDump(environment: environment) else { return }
        guard let uid = authService.firebaseUID else { return }
        try? WiskBackupLayout.migrateLegacySnapshotsIfNeeded(
            storeURL: WiskModelContainer.productionStoreURL(fileManager: fileManager),
            fileManager: fileManager
        )
        let backupsRoot = WiskFirestoreLocalBackup.firestoreRoot(fileManager: fileManager)
        #if os(macOS)
        let documentsMirrorRoot: URL? = WiskBackupLayout.documentsFirestoreRoot(fileManager: fileManager)
        #else
        let documentsMirrorRoot: URL? = nil
        #endif
        if WiskBackupLayout.hasFreshSnapshot(in: backupsRoot, now: now, fileManager: fileManager) {
            if let documentsMirrorRoot {
                _ = WiskBackupLayout.copyTimestampDirectories(
                    from: backupsRoot,
                    to: documentsMirrorRoot,
                    fileManager: fileManager
                )
            }
            return
        }
        do {
            let notes = try await remoteStore.fetchNotes(since: nil, uid: uid)
            let buckets = try await remoteStore.fetchBuckets(since: nil, uid: uid)
            let adages = (try? await remoteStore.fetchAdages(since: nil, uid: uid)) ?? []
            _ = try WiskFirestoreLocalBackup.writeDump(
                uid: uid,
                notes: notes,
                buckets: buckets,
                adages: adages,
                backupsRoot: backupsRoot,
                fileManager: fileManager,
                now: now,
                documentsMirrorRoot: documentsMirrorRoot
            )
        } catch {
            // A failed dump must not block launch or sync.
        }
    }

    private func verifyAccountForUpload(context: ModelContext) throws -> String {
        guard let uid = authService.firebaseUID else {
            throw SyncServiceError.requestFailed("Sign in before syncing.")
        }
        let previousUID = defaults.string(forKey: Self.lastSyncedFirebaseUIDKey)
        guard let previousUID, previousUID != uid else { return uid }

        var descriptor = FetchDescriptor<SyncMutation>(
            predicate: #Predicate { $0.syncedAt == nil }
        )
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).isEmpty == false {
            throw SyncServiceError.requestFailed("This device was last synced with a different Wisk account. Sign back into that account or export your local notes before uploading them to this account.")
        }
        return uid
    }

    func pushPendingMutations(context: ModelContext, since: Date?, uid: String) async throws {
        var descriptor = FetchDescriptor<SyncMutation>(
            predicate: #Predicate { $0.syncedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 250
        let mutations = try context.fetch(descriptor)
        let buckets = try bucketsForPush(context: context, since: since)
        let adages = try adagesForPush(context: context, since: since)
        guard !mutations.isEmpty || !buckets.isEmpty || !adages.isEmpty else { return }

        let now = Date()
        var latestMutationByEntityID: [UUID: SyncMutation] = [:]
        for mutation in mutations {
            latestMutationByEntityID[mutation.entityID] = mutation
        }

        var documents: [FirestoreNoteDocument] = []
        var pushedNoteIDs: Set<UUID> = []
        var missingNoteIDs: Set<UUID> = []
        for mutation in latestMutationByEntityID.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let note = try fetchNote(id: mutation.entityID, context: context) else {
                mutation.retryCount += 1
                mutation.lastError = "Local note no longer exists."
                missingNoteIDs.insert(mutation.entityID)
                continue
            }

            let nextRevision = max(note.syncRevision + 1, 1)
            var document = FirestoreNoteDocument(note: note, revision: nextRevision, lastSyncedDeviceID: deviceID)
            // Queued mutations can be pushed long after the edit: iOS suspends
            // the app before the 45s poll fires, and the mutation rides the next
            // foregrounding. Peers pull on `updatedAt > watermark - pullSkewGuard`,
            // so a push landing more than `pullSkewGuard` after the edit's
            // timestamp falls outside every peer's incremental window and stays
            // invisible until a launch-time full pull. Freshen the timestamp so
            // the push always lands inside it.
            if document.updatedAt < now.addingTimeInterval(-Self.pullSkewGuard) {
                document.updatedAt = now
                note.updatedAt = now
            }
            documents.append(document)
            note.syncRevision = nextRevision
            note.remoteID = document.id
            note.syncStatus = .synced
            pushedNoteIDs.insert(note.id)
        }

        let bucketDocuments = buckets.map { FirestoreBucketDocument(bucket: $0, lastSyncedDeviceID: deviceID) }
        let adageDocuments = adages.map { FirestoreAdageDocument(adage: $0, lastSyncedDeviceID: deviceID) }

        try await remoteStore.push(notes: documents, buckets: bucketDocuments, uid: uid)
        try await remoteStore.pushAdages(adageDocuments, uid: uid)

        for mutation in mutations {
            if pushedNoteIDs.contains(mutation.entityID) {
                mutation.syncedAt = now
                mutation.lastError = nil
            } else if missingNoteIDs.contains(mutation.entityID) {
                mutation.syncedAt = now
            }
        }
        try context.save()
    }

    private func bucketsForPush(context: ModelContext, since: Date?) throws -> [NoteBucket] {
        let descriptor = FetchDescriptor<NoteBucket>(sortBy: [SortDescriptor(\.updatedAt)])
        let buckets = try context.fetch(descriptor)
        let filtered: [NoteBucket]
        if let since {
            filtered = buckets.filter { $0.updatedAt >= since || $0.createdAt >= since }
        } else {
            filtered = buckets
        }
        return filtered
    }

    private func adagesForPush(context: ModelContext, since: Date?) throws -> [Adage] {
        let adages = try context.fetch(FetchDescriptor<Adage>(sortBy: [SortDescriptor(\.updatedAt)]))
        guard let since else { return adages }
        return adages.filter { $0.updatedAt >= since || $0.createdAt >= since }
    }

    func pullChanges(since: Date?, uid: String, context: ModelContext) async throws {
        let notes = try await remoteStore.fetchNotes(since: since, uid: uid)
        let buckets = try await remoteStore.fetchBuckets(since: since, uid: uid)
        let adages = try await remoteStore.fetchAdages(since: since, uid: uid)
        guard notes.isEmpty == false || buckets.isEmpty == false || adages.isEmpty == false else { return }
        let session = try IncomingLibraryApplySession(remoteNotes: notes, context: context)
        var changedSinceSave = 0
        for remote in notes {
            guard session.apply(remote) else { continue }
            changedSinceSave += 1
            if changedSinceSave >= Self.applyYieldBatchSize {
                try context.save()
                changedSinceSave = 0
                await Task.yield()
            }
        }
        session.applyBuckets(buckets)
        try session.applyAdages(adages)
        try context.save()
    }

    /// Full-table `Note` fetch is cheaper than thousands of unique-index lookups
    /// on a first-time pull. Incremental 45s polls stay on the per-ID path.
    static let bulkLocalNoteFetchThreshold = 1_000

    /// How many changed notes to write before yielding so SwiftUI can paint.
    static let applyYieldBatchSize = 25

    func apply(
        notes remoteNotes: [FirestoreNoteDocument],
        buckets remoteBuckets: [FirestoreBucketDocument],
        adages remoteAdages: [FirestoreAdageDocument] = [],
        context: ModelContext
    ) throws {
        guard remoteNotes.isEmpty == false || remoteBuckets.isEmpty == false || remoteAdages.isEmpty == false else {
            return
        }
        let session = try IncomingLibraryApplySession(remoteNotes: remoteNotes, context: context)
        for remote in remoteNotes {
            _ = session.apply(remote)
        }
        session.applyBuckets(remoteBuckets)
        try session.applyAdages(remoteAdages)
        try context.save()
    }

    private func fetchNote(id: UUID, context: ModelContext) throws -> Note? {
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func hasPendingMutations(context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<SyncMutation>(
            predicate: #Predicate { $0.syncedAt == nil }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).isEmpty == false
    }

    private static func loadDeviceID() -> String {
        let key = "wisk.sync.clientDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static let lastSyncedFirebaseUIDKey = "wisk.sync.lastFirebaseUID"
}

/// Applies one remote pull. Library rows are loaded once so each note does not fetch its own index record.
@MainActor
private final class IncomingLibraryApplySession {
    private let context: ModelContext
    private var notesByID: [UUID: Note]
    private let pendingNoteIDs: Set<UUID>
    private var bucketsByID: [UUID: NoteBucket]
    private var libraryRecordsByNoteID: [UUID: NoteLibraryRecord]

    init(remoteNotes: [FirestoreNoteDocument], context: ModelContext) throws {
        self.context = context
        if remoteNotes.isEmpty {
            notesByID = [:]
            libraryRecordsByNoteID = [:]
        } else {
            if remoteNotes.count >= SyncService.bulkLocalNoteFetchThreshold {
                let localNotes = try context.fetch(FetchDescriptor<Note>())
                notesByID = Dictionary(uniqueKeysWithValues: localNotes.map { ($0.id, $0) })
            } else {
                let remoteIDs = Set(remoteNotes.compactMap { UUID(uuidString: $0.id) })
                notesByID = Dictionary(
                    uniqueKeysWithValues: WiskNoteFetch.notes(ids: remoteIDs, in: context).map { ($0.id, $0) }
                )
            }
            let records = try context.fetch(FetchDescriptor<NoteLibraryRecord>())
            libraryRecordsByNoteID = Dictionary(uniqueKeysWithValues: records.map { ($0.noteID, $0) })
        }
        let pendingMutationDescriptor = FetchDescriptor<SyncMutation>(
            predicate: #Predicate { $0.syncedAt == nil }
        )
        pendingNoteIDs = Set(try context.fetch(pendingMutationDescriptor).map(\.entityID))
        let localBuckets = try context.fetch(FetchDescriptor<NoteBucket>())
        bucketsByID = Dictionary(uniqueKeysWithValues: localBuckets.map { ($0.id, $0) })
    }

    /// Returns true when the remote note was written onto the local store.
    func apply(_ remote: FirestoreNoteDocument) -> Bool {
        guard let noteID = UUID(uuidString: remote.id) else { return false }
        if let local = notesByID[noteID],
           pendingNoteIDs.contains(noteID) {
            if remote.syncRevision > local.syncRevision {
                context.insert(SyncConflict(
                    entityID: noteID,
                    localJSON: FirestoreNoteDocument(note: local).jsonString,
                    remoteJSON: remote.jsonString
                ))
                local.syncStatus = .conflict
            }
            return false
        }

        if let local = notesByID[noteID],
           local.syncStatus == .queued,
           remote.syncRevision > local.syncRevision {
            context.insert(SyncConflict(
                entityID: noteID,
                localJSON: FirestoreNoteDocument(note: local).jsonString,
                remoteJSON: remote.jsonString
            ))
            local.syncStatus = .conflict
            return false
        }

        if let local = notesByID[noteID],
           local.syncRevision == remote.syncRevision,
           local.updatedAt == remote.updatedAt {
            return false
        }

        let note = notesByID[noteID] ?? Note(title: remote.title, body: remote.body, kind: remote.kind)
        if notesByID[noteID] == nil {
            note.id = noteID
            context.insert(note)
            notesByID[noteID] = note
        }
        remote.apply(to: note, libraryRecords: &libraryRecordsByNoteID, context: context)
        return true
    }

    func applyBuckets(_ remoteBuckets: [FirestoreBucketDocument]) {
        for remoteBucket in remoteBuckets {
            guard let bucketID = UUID(uuidString: remoteBucket.id) else { continue }
            let bucket = bucketsByID[bucketID] ?? NoteBucket(
                name: remoteBucket.name,
                descriptionText: remoteBucket.descriptionText,
                examples: remoteBucket.examples,
                sortOrder: remoteBucket.sortOrder,
                isDefault: remoteBucket.isDefault,
                archivedAt: remoteBucket.archivedAt
            )
            if bucketsByID[bucketID] == nil {
                bucket.id = bucketID
                context.insert(bucket)
                bucketsByID[bucketID] = bucket
            }
            remoteBucket.apply(to: bucket)
        }
    }

    func applyAdages(_ remoteAdages: [FirestoreAdageDocument]) throws {
        guard remoteAdages.isEmpty == false else { return }
        let localAdages = try context.fetch(FetchDescriptor<Adage>())
        var adagesByID = Dictionary(uniqueKeysWithValues: localAdages.map { ($0.id, $0) })
        for remoteAdage in remoteAdages {
            guard let adageID = UUID(uuidString: remoteAdage.id) else { continue }
            let adage = adagesByID[adageID] ?? Adage(
                collectionName: remoteAdage.collectionName,
                title: remoteAdage.title,
                body: remoteAdage.body,
                createdAt: remoteAdage.createdAt
            )
            if adagesByID[adageID] == nil {
                adage.id = adageID
                context.insert(adage)
                adagesByID[adageID] = adage
            }
            remoteAdage.apply(to: adage)
        }
    }
}

@MainActor
enum SyncQueueRepair {
    @discardableResult
    static func queueLocalNotesForSync(context: ModelContext) throws -> Int {
        let localStatus = SyncStatus.local.rawValue
        let queuedStatus = SyncStatus.queued.rawValue
        let notesDescriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.syncStatusRaw == localStatus || note.syncStatusRaw == queuedStatus
            }
        )
        let candidateNotes = try context.fetch(notesDescriptor)
        guard !candidateNotes.isEmpty else { return 0 }

        let pendingMutationDescriptor = FetchDescriptor<SyncMutation>(
            predicate: #Predicate { mutation in
                mutation.syncedAt == nil
            }
        )
        let pendingEntityIDs = Set(try context.fetch(pendingMutationDescriptor).map(\.entityID))

        var queuedCount = 0
        for note in candidateNotes where !pendingEntityIDs.contains(note.id) {
            let payload = FirestoreNoteDocument(note: note).jsonString
            let operation: SyncMutationKind = note.deletedAt == nil ? .upsertNote : .deleteNote
            context.insert(SyncMutation(kind: operation, entityID: note.id, payloadJSON: payload))
            note.syncStatus = .queued
            queuedCount += 1
        }

        if queuedCount > 0 {
            try context.save()
        }
        return queuedCount
    }
}

struct FirestoreNoteDocument: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var kindRaw: String
    var pinned: Bool
    var markdownEnabled: Bool
    var syncRevision: Int
    var archivedAt: Date?
    var deletedAt: Date?
    var dailyDate: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedDeviceID: String?
    var tags: [FirestoreNoteTagDocument]
    var projects: [FirestoreNoteProjectDocument]
    var parsedItems: [FirestoreParsedNoteItemDocument]
    var versions: [FirestoreNoteVersionDocument]
    var shares: [FirestoreNoteShareDocument]
    var publications: [FirestorePublishedNoteDocument]
    var attachments: [FirestoreNoteAttachmentDocument]

    var kind: NoteKind {
        NoteKind(rawValue: kindRaw) ?? .general
    }

    init(note: Note, revision: Int? = nil, lastSyncedDeviceID: String? = nil) {
        self.id = note.id.uuidString
        self.title = note.title
        self.body = note.body
        self.kindRaw = note.kindRaw
        self.pinned = note.pinned
        self.markdownEnabled = note.markdownEnabled
        self.syncRevision = revision ?? note.syncRevision
        self.archivedAt = note.archivedAt
        self.deletedAt = note.deletedAt
        self.dailyDate = note.dailyDate
        self.createdAt = note.createdAt
        self.updatedAt = note.updatedAt
        self.lastSyncedDeviceID = lastSyncedDeviceID
        self.tags = note.tags.map(FirestoreNoteTagDocument.init)
        self.projects = note.projects.map(FirestoreNoteProjectDocument.init)
        self.parsedItems = note.parsedItems.sorted { $0.sortOrder < $1.sortOrder }.map(FirestoreParsedNoteItemDocument.init)
        self.versions = []
        self.shares = note.shares.map(FirestoreNoteShareDocument.init)
        self.publications = note.publications.map(FirestorePublishedNoteDocument.init)
        self.attachments = note.attachments.sorted { $0.createdAt < $1.createdAt }.map(FirestoreNoteAttachmentDocument.init)
    }

    init?(id: String, data: [String: Any]) {
        guard let title = data["title"] as? String,
              let body = data["body"] as? String
        else { return nil }

        self.id = id
        self.title = title
        self.body = body
        self.kindRaw = data["kindRaw"] as? String ?? NoteKind.general.rawValue
        self.pinned = data["pinned"] as? Bool ?? false
        self.markdownEnabled = data["markdownEnabled"] as? Bool ?? false
        self.syncRevision = data["syncRevision"] as? Int ?? 0
        self.archivedAt = FirestoreValue.date(data["archivedAt"])
        self.deletedAt = FirestoreValue.date(data["deletedAt"])
        self.dailyDate = FirestoreValue.date(data["dailyDate"])
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
        self.updatedAt = FirestoreValue.date(data["updatedAt"]) ?? self.createdAt
        self.lastSyncedDeviceID = data["lastSyncedDeviceID"] as? String
        self.tags = FirestoreValue.array(data["tags"]).map(FirestoreNoteTagDocument.init)
        self.projects = FirestoreValue.array(data["projects"]).map(FirestoreNoteProjectDocument.init)
        self.parsedItems = FirestoreValue.array(data["parsedItems"]).compactMap(FirestoreParsedNoteItemDocument.init)
        self.versions = FirestoreValue.array(data["versions"]).compactMap(FirestoreNoteVersionDocument.init)
        self.shares = FirestoreValue.array(data["shares"]).compactMap(FirestoreNoteShareDocument.init)
        self.publications = FirestoreValue.array(data["publications"]).compactMap(FirestorePublishedNoteDocument.init)
        self.attachments = FirestoreValue.array(data["attachments"]).compactMap(FirestoreNoteAttachmentDocument.init)
    }

    var firestoreData: [String: Any] {
        var data: [String: Any] = [
            "title": title,
            "body": body,
            "kindRaw": kindRaw,
            "pinned": pinned,
            "markdownEnabled": markdownEnabled,
            "syncRevision": syncRevision,
            "archivedAt": FirestoreValue.optional(archivedAt),
            "deletedAt": FirestoreValue.optional(deletedAt),
            "dailyDate": FirestoreValue.optional(dailyDate),
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "lastSyncedDeviceID": FirestoreValue.optional(lastSyncedDeviceID),
            "tags": tags.map(\.firestoreData),
            "projects": projects.map(\.firestoreData),
            "parsedItems": parsedItems.map(\.firestoreData),
            "shares": shares.map(\.firestoreData),
            "publications": publications.map(\.firestoreData),
            "attachments": attachments.map(\.firestoreData),
        ]
        if versions.isEmpty == false {
            data["versions"] = versions.map(\.firestoreData)
        }
        return data
    }

    var jsonString: String {
        Self.jsonString(self)
    }

    @MainActor
    func apply(to note: Note, context: ModelContext) {
        applyStoredFields(to: note, context: context)
        NoteLibraryIndex.upsert(note, in: context)
    }

    @MainActor
    func apply(
        to note: Note,
        libraryRecords: inout [UUID: NoteLibraryRecord],
        context: ModelContext
    ) {
        applyStoredFields(to: note, context: context)
        NoteLibraryIndex.upsert(note, into: &libraryRecords, context: context)
    }

    @MainActor
    private func applyStoredFields(to note: Note, context: ModelContext) {
        var localAttachmentState: [UUID: LocalAttachmentState] = [:]
        for attachment in note.attachments where localAttachmentState[attachment.id] == nil {
            localAttachmentState[attachment.id] = LocalAttachmentState(
                localCachePath: attachment.localCachePath,
                uploadStatus: attachment.uploadStatus,
                lastError: attachment.lastError
            )
        }

        note.remoteID = id
        note.title = title
        note.body = body
        note.kindRaw = kindRaw
        note.pinned = pinned
        note.markdownEnabled = markdownEnabled
        note.archivedAt = archivedAt
        note.deletedAt = deletedAt
        note.dailyDate = dailyDate
        note.createdAt = createdAt
        note.updatedAt = updatedAt
        note.syncRevision = syncRevision
        note.syncStatus = .synced

        note.tags.forEach { context.delete($0) }
        note.projects.forEach { context.delete($0) }
        note.parsedItems.forEach { context.delete($0) }
        note.shares.forEach { context.delete($0) }
        note.publications.forEach { context.delete($0) }
        note.attachments.forEach { context.delete($0) }

        note.tags = tags.map { $0.model(note: note) }
        note.projects = projects.map { $0.model(note: note) }
        note.parsedItems = parsedItems.map { $0.model(note: note) }
        if versions.isEmpty == false {
            note.versions.forEach { context.delete($0) }
            note.versions = versions.map { $0.model(note: note) }
        }
        note.shares = shares.map { $0.model(note: note) }
        note.publications = publications.map { $0.model(note: note) }
        var seenAttachmentIDs: Set<UUID> = []
        note.attachments = attachments.compactMap { document in
            let attachment = document.model(note: note)
            guard seenAttachmentIDs.insert(attachment.id).inserted else {
                return nil
            }
            if let localState = localAttachmentState[attachment.id] {
                attachment.localCachePath = localState.localCachePath
                if attachment.storagePath == nil, localState.localCachePath != nil {
                    attachment.uploadStatus = localState.uploadStatus
                    attachment.lastError = localState.lastError
                }
            }
            return attachment
        }
    }

    private struct LocalAttachmentState {
        var localCachePath: String?
        var uploadStatus: NoteAttachmentUploadStatus
        var lastError: String?
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

struct FirestoreNoteTagDocument: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var suggestedByAI: Bool
    var createdAt: Date

    init(tag: NoteTag) {
        self.id = tag.id.uuidString
        self.name = tag.name
        self.suggestedByAI = tag.suggestedByAIRaw
        self.createdAt = tag.createdAt
    }

    init(data: [String: Any]) {
        self.id = data["id"] as? String ?? UUID().uuidString
        self.name = data["name"] as? String ?? ""
        self.suggestedByAI = data["suggestedByAI"] as? Bool ?? false
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
    }

    var firestoreData: [String: Any] {
        ["id": id, "name": name, "suggestedByAI": suggestedByAI, "createdAt": createdAt]
    }

    @MainActor
    func model(note: Note) -> NoteTag {
        let tag = NoteTag(name: name, suggestedByAI: suggestedByAI, note: note)
        tag.id = UUID(uuidString: id) ?? tag.id
        tag.createdAt = createdAt
        return tag
    }
}

struct FirestoreNoteProjectDocument: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var suggestedByAI: Bool
    var createdAt: Date

    init(project: NoteProject) {
        self.id = project.id.uuidString
        self.name = project.name
        self.suggestedByAI = project.suggestedByAI
        self.createdAt = project.createdAt
    }

    init(data: [String: Any]) {
        self.id = data["id"] as? String ?? UUID().uuidString
        self.name = data["name"] as? String ?? ""
        self.suggestedByAI = data["suggestedByAI"] as? Bool ?? false
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
    }

    var firestoreData: [String: Any] {
        ["id": id, "name": name, "suggestedByAI": suggestedByAI, "createdAt": createdAt]
    }

    @MainActor
    func model(note: Note) -> NoteProject {
        let project = NoteProject(name: name, suggestedByAI: suggestedByAI, note: note)
        project.id = UUID(uuidString: id) ?? project.id
        project.createdAt = createdAt
        return project
    }
}

struct FirestoreParsedNoteItemDocument: Codable, Equatable, Sendable {
    var id: String
    var rawText: String
    var title: String
    var itemTypeRaw: String
    var statusRaw: String
    var confidence: Double
    var sourceLineIndex: Int
    var dueHint: String?
    var project: String?
    var people: [String]
    var bucketId: String?
    var bucketReason: String?
    var acceptedAt: Date?
    var rejectedAt: Date?
    var completedAt: Date?
    var archivedAt: Date?
    var reviewStatusRaw: String
    var userEdited: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var remoteID: String?

    init(item: ParsedNoteItem) {
        self.id = item.id.uuidString
        self.rawText = item.rawText
        self.title = item.title
        self.itemTypeRaw = item.itemTypeRaw
        self.statusRaw = item.statusRaw
        self.confidence = item.confidence
        self.sourceLineIndex = item.sourceLineIndex
        self.dueHint = item.dueHint
        self.project = item.project
        self.people = item.people
        self.bucketId = item.bucketId
        self.bucketReason = item.bucketReason
        self.acceptedAt = item.acceptedAt
        self.rejectedAt = item.rejectedAt
        self.completedAt = item.completedAt
        self.archivedAt = item.archivedAt
        self.reviewStatusRaw = item.reviewStatusRaw
        self.userEdited = item.userEdited
        self.sortOrder = item.sortOrder
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.remoteID = item.remoteID
    }

    init?(data: [String: Any]) {
        guard let rawText = data["rawText"] as? String,
              let title = data["title"] as? String else { return nil }
        self.id = data["id"] as? String ?? UUID().uuidString
        self.rawText = rawText
        self.title = title
        self.itemTypeRaw = data["itemTypeRaw"] as? String ?? ParsedNoteItemType.reference.rawValue
        self.statusRaw = data["statusRaw"] as? String ?? ParsedNoteItemStatus.open.rawValue
        self.confidence = data["confidence"] as? Double ?? 0
        self.sourceLineIndex = data["sourceLineIndex"] as? Int ?? 0
        self.dueHint = data["dueHint"] as? String
        self.project = data["project"] as? String
        self.people = data["people"] as? [String] ?? []
        self.bucketId = data["bucketId"] as? String
        self.bucketReason = data["bucketReason"] as? String
        self.acceptedAt = FirestoreValue.date(data["acceptedAt"])
        self.rejectedAt = FirestoreValue.date(data["rejectedAt"])
        self.completedAt = FirestoreValue.date(data["completedAt"])
        self.archivedAt = FirestoreValue.date(data["archivedAt"])
        self.reviewStatusRaw = data["reviewStatusRaw"] as? String ?? ParsedNoteItemReviewStatus.pending.rawValue
        self.userEdited = data["userEdited"] as? Bool ?? false
        self.sortOrder = data["sortOrder"] as? Int ?? 0
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
        self.updatedAt = FirestoreValue.date(data["updatedAt"]) ?? self.createdAt
        self.remoteID = data["remoteID"] as? String
    }

    var firestoreData: [String: Any] {
        [
            "id": id,
            "rawText": rawText,
            "title": title,
            "itemTypeRaw": itemTypeRaw,
            "statusRaw": statusRaw,
            "confidence": confidence,
            "sourceLineIndex": sourceLineIndex,
            "dueHint": FirestoreValue.optional(dueHint),
            "project": FirestoreValue.optional(project),
            "people": people,
            "bucketId": FirestoreValue.optional(bucketId),
            "bucketReason": FirestoreValue.optional(bucketReason),
            "acceptedAt": FirestoreValue.optional(acceptedAt),
            "rejectedAt": FirestoreValue.optional(rejectedAt),
            "completedAt": FirestoreValue.optional(completedAt),
            "archivedAt": FirestoreValue.optional(archivedAt),
            "reviewStatusRaw": reviewStatusRaw,
            "userEdited": userEdited,
            "sortOrder": sortOrder,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "remoteID": FirestoreValue.optional(remoteID),
        ]
    }

    @MainActor
    func model(note: Note) -> ParsedNoteItem {
        let item = ParsedNoteItem(
            rawText: rawText,
            title: title,
            itemType: ParsedNoteItemType(rawValue: itemTypeRaw) ?? .reference,
            status: ParsedNoteItemStatus(rawValue: statusRaw) ?? .open,
            confidence: confidence,
            sourceLineIndex: sourceLineIndex,
            dueHint: dueHint,
            project: project,
            people: people,
            bucketId: bucketId,
            bucketReason: bucketReason,
            acceptedAt: acceptedAt,
            rejectedAt: rejectedAt,
            completedAt: completedAt,
            archivedAt: archivedAt,
            reviewStatus: ParsedNoteItemReviewStatus(rawValue: reviewStatusRaw) ?? .pending,
            userEdited: userEdited,
            sortOrder: sortOrder,
            note: note
        )
        item.id = UUID(uuidString: id) ?? item.id
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.remoteID = remoteID
        return item
    }
}

struct FirestoreNoteVersionDocument: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var reason: String
    var createdAt: Date

    init(version: NoteVersion) {
        self.id = version.id.uuidString
        self.title = version.title
        self.body = version.body
        self.reason = version.reason
        self.createdAt = version.createdAt
    }

    init?(data: [String: Any]) {
        guard let title = data["title"] as? String,
              let body = data["body"] as? String else { return nil }
        self.id = data["id"] as? String ?? UUID().uuidString
        self.title = title
        self.body = body
        self.reason = data["reason"] as? String ?? "edit"
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
    }

    var firestoreData: [String: Any] {
        ["id": id, "title": title, "body": body, "reason": reason, "createdAt": createdAt]
    }

    @MainActor
    func model(note: Note) -> NoteVersion {
        let version = NoteVersion(title: title, body: body, reason: reason, note: note)
        version.id = UUID(uuidString: id) ?? version.id
        version.createdAt = createdAt
        return version
    }
}

struct FirestoreNoteShareDocument: Codable, Equatable, Sendable {
    var id: String
    var email: String
    var roleRaw: String
    var remoteID: String?
    var createdAt: Date

    init(share: NoteShare) {
        self.id = share.id.uuidString
        self.email = share.email
        self.roleRaw = share.roleRaw
        self.remoteID = share.remoteID
        self.createdAt = share.createdAt
    }

    init?(data: [String: Any]) {
        guard let email = data["email"] as? String else { return nil }
        self.id = data["id"] as? String ?? UUID().uuidString
        self.email = email
        self.roleRaw = data["roleRaw"] as? String ?? NoteShareRole.viewer.rawValue
        self.remoteID = data["remoteID"] as? String
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
    }

    var firestoreData: [String: Any] {
        ["id": id, "email": email, "roleRaw": roleRaw, "remoteID": FirestoreValue.optional(remoteID), "createdAt": createdAt]
    }

    @MainActor
    func model(note: Note) -> NoteShare {
        let share = NoteShare(email: email, role: NoteShareRole(rawValue: roleRaw) ?? .viewer, note: note)
        share.id = UUID(uuidString: id) ?? share.id
        share.remoteID = remoteID
        share.createdAt = createdAt
        return share
    }
}

struct FirestorePublishedNoteDocument: Codable, Equatable, Sendable {
    var id: String
    var slug: String
    var isPublic: Bool
    var publishedAt: Date?
    var remoteURL: String?

    init(publication: PublishedNote) {
        self.id = publication.id.uuidString
        self.slug = publication.slug
        self.isPublic = publication.isPublic
        self.publishedAt = publication.publishedAt
        self.remoteURL = publication.remoteURL
    }

    init?(data: [String: Any]) {
        guard let slug = data["slug"] as? String else { return nil }
        self.id = data["id"] as? String ?? UUID().uuidString
        self.slug = slug
        self.isPublic = data["isPublic"] as? Bool ?? false
        self.publishedAt = FirestoreValue.date(data["publishedAt"])
        self.remoteURL = data["remoteURL"] as? String
    }

    var firestoreData: [String: Any] {
        ["id": id, "slug": slug, "isPublic": isPublic, "publishedAt": FirestoreValue.optional(publishedAt), "remoteURL": FirestoreValue.optional(remoteURL)]
    }

    @MainActor
    func model(note: Note) -> PublishedNote {
        let publication = PublishedNote(slug: slug, isPublic: isPublic, note: note)
        publication.id = UUID(uuidString: id) ?? publication.id
        publication.publishedAt = publishedAt
        publication.remoteURL = remoteURL
        return publication
    }
}

struct FirestoreNoteAttachmentDocument: Codable, Equatable, Sendable {
    var id: String
    var storagePath: String?
    var fileName: String
    var contentType: String
    var originalWidth: Int
    var originalHeight: Int
    var storedWidth: Int
    var storedHeight: Int
    var byteSize: Int
    var altText: String
    var displayWidth: Double?
    var alignmentRaw: String
    var isPreviewVisible: Bool
    var isAltTextUserProvided: Bool
    var isFileNameUserProvided: Bool
    var uploadStatusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var lastError: String?

    init(attachment: NoteAttachment) {
        self.id = attachment.id.uuidString
        self.storagePath = attachment.storagePath
        self.fileName = attachment.fileName
        self.contentType = attachment.contentType
        self.originalWidth = attachment.originalWidth
        self.originalHeight = attachment.originalHeight
        self.storedWidth = attachment.storedWidth
        self.storedHeight = attachment.storedHeight
        self.byteSize = attachment.byteSize
        self.altText = attachment.altText
        self.displayWidth = attachment.displayWidth
        self.alignmentRaw = attachment.alignmentRaw
        self.isPreviewVisible = attachment.isPreviewVisible
        self.isAltTextUserProvided = attachment.isAltTextUserProvided
        self.isFileNameUserProvided = attachment.isFileNameUserProvided
        self.uploadStatusRaw = attachment.uploadStatusRaw
        self.createdAt = attachment.createdAt
        self.updatedAt = attachment.updatedAt
        self.deletedAt = attachment.deletedAt
        self.lastError = attachment.lastError
    }

    init?(data: [String: Any]) {
        self.id = data["id"] as? String ?? UUID().uuidString
        self.storagePath = data["storagePath"] as? String
        self.fileName = data["fileName"] as? String ?? ""
        self.contentType = data["contentType"] as? String ?? "image/jpeg"
        self.originalWidth = data["originalWidth"] as? Int ?? 0
        self.originalHeight = data["originalHeight"] as? Int ?? 0
        self.storedWidth = data["storedWidth"] as? Int ?? 0
        self.storedHeight = data["storedHeight"] as? Int ?? 0
        self.byteSize = data["byteSize"] as? Int ?? 0
        self.altText = data["altText"] as? String ?? "Screenshot"
        self.displayWidth = (data["displayWidth"] as? NSNumber)?.doubleValue
        self.alignmentRaw = data["alignmentRaw"] as? String ?? NoteAttachmentAlignment.center.rawValue
        self.isPreviewVisible = data["isPreviewVisible"] as? Bool ?? true
        self.isAltTextUserProvided = data["isAltTextUserProvided"] as? Bool ?? false
        self.isFileNameUserProvided = data["isFileNameUserProvided"] as? Bool ?? false
        self.uploadStatusRaw = data["uploadStatusRaw"] as? String ?? NoteAttachmentUploadStatus.uploaded.rawValue
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
        self.updatedAt = FirestoreValue.date(data["updatedAt"]) ?? self.createdAt
        self.deletedAt = FirestoreValue.date(data["deletedAt"])
        self.lastError = data["lastError"] as? String
    }

    var firestoreData: [String: Any] {
        [
            "id": id,
            "storagePath": FirestoreValue.optional(storagePath),
            "fileName": fileName,
            "contentType": contentType,
            "originalWidth": originalWidth,
            "originalHeight": originalHeight,
            "storedWidth": storedWidth,
            "storedHeight": storedHeight,
            "byteSize": byteSize,
            "altText": altText,
            "displayWidth": FirestoreValue.optional(displayWidth),
            "alignmentRaw": alignmentRaw,
            "isPreviewVisible": isPreviewVisible,
            "isAltTextUserProvided": isAltTextUserProvided,
            "isFileNameUserProvided": isFileNameUserProvided,
            "uploadStatusRaw": uploadStatusRaw,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "deletedAt": FirestoreValue.optional(deletedAt),
            "lastError": FirestoreValue.optional(lastError),
        ]
    }

    @MainActor
    func model(note: Note) -> NoteAttachment {
        let attachment = NoteAttachment(
            storagePath: storagePath,
            fileName: fileName,
            contentType: contentType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            storedWidth: storedWidth,
            storedHeight: storedHeight,
            byteSize: byteSize,
            altText: altText,
            displayWidth: displayWidth,
            alignment: NoteAttachmentAlignment(rawValue: alignmentRaw) ?? .center,
            isPreviewVisible: isPreviewVisible,
            isAltTextUserProvided: isAltTextUserProvided,
            isFileNameUserProvided: isFileNameUserProvided,
            uploadStatus: NoteAttachmentUploadStatus(rawValue: uploadStatusRaw) ?? .uploaded,
            note: note
        )
        attachment.id = UUID(uuidString: id) ?? attachment.id
        attachment.createdAt = createdAt
        attachment.updatedAt = updatedAt
        attachment.deletedAt = deletedAt
        attachment.lastError = lastError
        return attachment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storagePath
        case fileName
        case contentType
        case originalWidth
        case originalHeight
        case storedWidth
        case storedHeight
        case byteSize
        case altText
        case displayWidth
        case alignmentRaw
        case isPreviewVisible
        case isAltTextUserProvided
        case isFileNameUserProvided
        case uploadStatusRaw
        case createdAt
        case updatedAt
        case deletedAt
        case lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.storagePath = try container.decodeIfPresent(String.self, forKey: .storagePath)
        self.fileName = try container.decode(String.self, forKey: .fileName)
        self.contentType = try container.decode(String.self, forKey: .contentType)
        self.originalWidth = try container.decode(Int.self, forKey: .originalWidth)
        self.originalHeight = try container.decode(Int.self, forKey: .originalHeight)
        self.storedWidth = try container.decode(Int.self, forKey: .storedWidth)
        self.storedHeight = try container.decode(Int.self, forKey: .storedHeight)
        self.byteSize = try container.decode(Int.self, forKey: .byteSize)
        self.altText = try container.decode(String.self, forKey: .altText)
        self.displayWidth = try container.decodeIfPresent(Double.self, forKey: .displayWidth)
        self.alignmentRaw = try container.decodeIfPresent(String.self, forKey: .alignmentRaw)
            ?? NoteAttachmentAlignment.center.rawValue
        self.isPreviewVisible = try container.decodeIfPresent(Bool.self, forKey: .isPreviewVisible) ?? true
        self.isAltTextUserProvided = try container.decodeIfPresent(Bool.self, forKey: .isAltTextUserProvided) ?? false
        self.isFileNameUserProvided = try container.decodeIfPresent(Bool.self, forKey: .isFileNameUserProvided) ?? false
        self.uploadStatusRaw = try container.decode(String.self, forKey: .uploadStatusRaw)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct FirestoreAdageDocument: Codable, Equatable, Sendable {
    var id: String
    var collectionName: String
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var lastSyncedDeviceID: String?

    init(adage: Adage, lastSyncedDeviceID: String? = nil) {
        self.id = adage.id.uuidString
        self.collectionName = adage.collectionName
        self.title = adage.title
        self.body = adage.body
        self.createdAt = adage.createdAt
        self.updatedAt = adage.updatedAt
        self.deletedAt = adage.deletedAt
        self.lastSyncedDeviceID = lastSyncedDeviceID
    }

    init?(id: String, data: [String: Any]) {
        guard let body = data["body"] as? String else { return nil }
        self.id = id
        self.collectionName = data["collectionName"] as? String ?? ""
        self.title = data["title"] as? String ?? ""
        self.body = body
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
        self.updatedAt = FirestoreValue.date(data["updatedAt"]) ?? self.createdAt
        self.deletedAt = FirestoreValue.date(data["deletedAt"])
        self.lastSyncedDeviceID = data["lastSyncedDeviceID"] as? String
    }

    var firestoreData: [String: Any] {
        [
            "collectionName": collectionName,
            "title": title,
            "body": body,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "deletedAt": FirestoreValue.optional(deletedAt),
            "lastSyncedDeviceID": FirestoreValue.optional(lastSyncedDeviceID),
        ]
    }

    @MainActor
    func apply(to adage: Adage) {
        adage.collectionName = collectionName
        adage.title = title
        adage.body = body
        adage.createdAt = createdAt
        adage.updatedAt = updatedAt
        adage.deletedAt = deletedAt
    }
}

struct FirestoreBucketDocument: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var descriptionText: String
    var examples: [String]
    var sortOrder: Int
    var isDefault: Bool
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedDeviceID: String?

    init(bucket: NoteBucket, lastSyncedDeviceID: String? = nil) {
        self.id = bucket.id.uuidString
        self.name = bucket.name
        self.descriptionText = bucket.descriptionText
        self.examples = bucket.examples
        self.sortOrder = bucket.sortOrder
        self.isDefault = bucket.isDefault
        self.archivedAt = bucket.archivedAt
        self.createdAt = bucket.createdAt
        self.updatedAt = bucket.updatedAt
        self.lastSyncedDeviceID = lastSyncedDeviceID
    }

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.descriptionText = data["descriptionText"] as? String ?? ""
        self.examples = data["examples"] as? [String] ?? []
        self.sortOrder = data["sortOrder"] as? Int ?? 0
        self.isDefault = data["isDefault"] as? Bool ?? false
        self.archivedAt = FirestoreValue.date(data["archivedAt"])
        self.createdAt = FirestoreValue.date(data["createdAt"]) ?? Date()
        self.updatedAt = FirestoreValue.date(data["updatedAt"]) ?? self.createdAt
        self.lastSyncedDeviceID = data["lastSyncedDeviceID"] as? String
    }

    var firestoreData: [String: Any] {
        [
            "name": name,
            "descriptionText": descriptionText,
            "examples": examples,
            "sortOrder": sortOrder,
            "isDefault": isDefault,
            "archivedAt": FirestoreValue.optional(archivedAt),
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "lastSyncedDeviceID": FirestoreValue.optional(lastSyncedDeviceID),
        ]
    }

    @MainActor
    func apply(to bucket: NoteBucket) {
        bucket.name = name
        bucket.descriptionText = descriptionText
        bucket.examples = examples
        bucket.sortOrder = sortOrder
        bucket.isDefault = isDefault
        bucket.archivedAt = archivedAt
        bucket.createdAt = createdAt
        bucket.updatedAt = updatedAt
    }
}

enum FirestoreValue {
    static func optional<T>(_ value: T?) -> Any {
        if let value {
            return value
        }
        return NSNull()
    }

    static func date(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }
        return value as? Date
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }
}

enum BackendMutationOperation: String, Codable, Sendable {
    case noteUpsert = "note.upsert"
    case noteDelete = "note.delete"

    var syncMutationKind: SyncMutationKind {
        switch self {
        case .noteUpsert: return .upsertNote
        case .noteDelete: return .deleteNote
        }
    }
}

enum SyncMutationWriter {
    static func enqueue(
        note: Note,
        operation: BackendMutationOperation = .noteUpsert,
        context: ModelContext
    ) throws {
        try enqueue(notes: [note], operation: operation, context: context)
    }

    static func enqueue(
        notes: [Note],
        operation: BackendMutationOperation = .noteUpsert,
        context: ModelContext
    ) throws {
        guard notes.isEmpty == false else { return }
        for note in notes {
            let payload = FirestoreNoteDocument(note: note).jsonString
            context.insert(SyncMutation(kind: operation.syncMutationKind, entityID: note.id, payloadJSON: payload))
            note.syncStatus = .queued
        }
        try context.save()
    }

    /// Deletes completed mutations (already pushed; `syncedAt != nil`) past
    /// the retention window. Rows with `syncedAt == nil` are the live retry
    /// queue and are never touched; keeping some history preserves the
    /// audit trail that diagnosed push loops.
    static func pruneCompleted(
        context: ModelContext,
        olderThan: TimeInterval = 24 * 3600
    ) throws -> Int {
        let cutoff = Date().addingTimeInterval(-olderThan)
        // Nil (pending) rows must never match, so they coalesce to a sentinel
        // far past the cutoff. Single-expression body: `#Predicate` rejects
        // statement-style bodies, and this form translates to SQL where a
        // NULL `syncedAt` compares false against the cutoff.
        let pendingSentinel = Date.distantFuture
        var descriptor = FetchDescriptor<SyncMutation>(
            predicate: #Predicate { mutation in
                (mutation.syncedAt ?? pendingSentinel) < cutoff
            }
        )
        descriptor.fetchLimit = 2_000
        let stale = try context.fetch(descriptor)
        guard stale.isEmpty == false else { return 0 }
        for mutation in stale {
            context.delete(mutation)
        }
        try context.save()
        return stale.count
    }
}

enum SyncServiceError: LocalizedError {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return "Wisk sync failed: \(message)"
        }
    }
}
