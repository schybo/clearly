import Foundation
import CoreGraphics
import SwiftData

enum NoteKind: String, Codable, CaseIterable, Sendable {
    case daily
    case general
    case list
    case structured
    case tracker
}

@Model
final class Note {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var kindRaw: String = NoteKind.general.rawValue
    var pinned: Bool = false
    var archivedAt: Date? = nil
    var deletedAt: Date? = nil
    var lastOrganizedAt: Date? = nil
    var dailyDate: Date? = nil
    var remoteID: String? = nil
    var syncRevision: Int = 0
    var syncStatusRaw: String = SyncStatus.local.rawValue
    var markdownEnabled: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \NoteVersion.note)
    var versions: [NoteVersion] = []

    @Relationship(deleteRule: .cascade, inverse: \NoteTag.note)
    var tags: [NoteTag] = []

    @Relationship(deleteRule: .cascade, inverse: \NoteProject.note)
    var projects: [NoteProject] = []

    @Relationship(deleteRule: .cascade, inverse: \ParsedNoteItem.note)
    var parsedItems: [ParsedNoteItem] = []

    @Relationship(deleteRule: .cascade, inverse: \NoteShare.note)
    var shares: [NoteShare] = []

    @Relationship(deleteRule: .cascade, inverse: \PublishedNote.note)
    var publications: [PublishedNote] = []

    @Relationship(deleteRule: .cascade, inverse: \NoteAttachment.note)
    var attachments: [NoteAttachment] = []

    var kind: NoteKind {
        get { NoteKind(rawValue: kindRaw) ?? .general }
        set { kindRaw = newValue.rawValue }
    }

    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .local }
        set { syncStatusRaw = newValue.rawValue }
    }

    init(
        title: String = "",
        body: String = "",
        kind: NoteKind = .general,
        dailyDate: Date? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.kindRaw = kind.rawValue
        self.dailyDate = dailyDate
        self.markdownEnabled = kind != .list && kind != .tracker
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    func snapshotIfNeeded(reason: String) {
        let latest = latestVersion()
        guard latest?.body != body || latest?.title != title else { return }
        versions.append(NoteVersion(title: title, body: body, reason: reason, note: self))
    }

    private func latestVersion() -> NoteVersion? {
        let noteID = id
        if let context = modelContext {
            var descriptor = FetchDescriptor<NoteVersion>(
                predicate: #Predicate { $0.note?.id == noteID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let fetched = try? context.fetch(descriptor).first {
                return fetched
            }
        }
        return versions.max(by: { $0.createdAt < $1.createdAt })
    }

    @discardableResult
    func addTagIfNeeded(_ name: String, suggestedByAI: Bool = false) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard tags.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) == false else {
            return false
        }

        tags.append(NoteTag(name: trimmed, suggestedByAI: suggestedByAI, note: self))
        return true
    }

    func replaceSuggestedTags(with names: [String], suggestedByAI: Bool) {
        let manualTags = tags.filter { !$0.suggestedByAIRaw }
        let manualTagNames = Set(manualTags.map { $0.name.lowercased() })
        let suggestedTags = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, name in
                guard result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) == false,
                      manualTagNames.contains(name.lowercased()) == false else { return }
                result.append(name)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { NoteTag(name: $0, suggestedByAI: suggestedByAI, note: self) }

        tags = manualTags + suggestedTags
    }

    func duplicated(titleSuffix: String = " Copy") -> Note {
        let duplicate = Note(
            title: title + titleSuffix,
            body: body,
            kind: kind,
            dailyDate: dailyDate
        )
        duplicate.pinned = pinned
        duplicate.markdownEnabled = markdownEnabled
        duplicate.tags = tags.map { tag in
            NoteTag(name: tag.name, suggestedByAI: tag.suggestedByAIRaw, note: duplicate)
        }
        duplicate.projects = projects.map { project in
            NoteProject(name: project.name, suggestedByAI: project.suggestedByAI, note: duplicate)
        }
        duplicate.parsedItems = parsedItems
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { item in
                let copiedItem = ParsedNoteItem(
                    rawText: item.rawText,
                    title: item.title,
                    itemType: item.itemType,
                    status: item.status,
                    confidence: item.confidence,
                    sourceLineIndex: item.sourceLineIndex,
                    dueHint: item.dueHint,
                    project: item.project,
                    people: item.people,
                    bucketId: item.bucketId,
                    bucketReason: item.bucketReason,
                    acceptedAt: item.acceptedAt,
                    rejectedAt: item.rejectedAt,
                    completedAt: item.completedAt,
                    archivedAt: item.archivedAt,
                    reviewStatus: item.reviewStatus,
                    userEdited: item.userEdited,
                    sortOrder: item.sortOrder,
                    note: duplicate
                )
                copiedItem.correctionJSON = item.correctionJSON
                return copiedItem
            }
        duplicate.attachments = attachments.map { attachment in
            attachment.duplicated(note: duplicate)
        }
        return duplicate
    }
}

enum NoteAttachmentUploadStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case uploaded
    case failed
}

enum NoteAttachmentAlignment: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

enum WiskAttachmentImageLayout {
    static let minimumWidth: CGFloat = 120
    static let smallWidth: Double = 240
    static let mediumWidth: Double = 480
    static let largeWidth: Double = 720
    static let defaultAvailableWidth: CGFloat = 680
}

enum WiskAttachmentImageSizeOption: String, CaseIterable, Identifiable, Sendable {
    case fitToNote
    case small
    case medium
    case large
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitToNote: "Fit to Note"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .original: "Original Size"
        }
    }

    func displayWidth(for attachment: NoteAttachment) -> Double? {
        switch self {
        case .fitToNote:
            nil
        case .small:
            WiskAttachmentImageLayout.smallWidth
        case .medium:
            WiskAttachmentImageLayout.mediumWidth
        case .large:
            WiskAttachmentImageLayout.largeWidth
        case .original:
            Double(max(attachment.intrinsicPixelWidth, Int(WiskAttachmentImageLayout.minimumWidth)))
        }
    }

    func isSelected(for attachment: NoteAttachment) -> Bool {
        switch self {
        case .fitToNote:
            return attachment.displayWidth == nil
        case .small, .medium, .large:
            return attachment.displayWidth == displayWidth(for: attachment)
                && attachment.displayWidth != Double(attachment.intrinsicPixelWidth)
        case .original:
            guard let displayWidth = attachment.displayWidth else { return false }
            return abs(displayWidth - Double(attachment.intrinsicPixelWidth)) < 0.5
        }
    }
}

@Model
final class NoteAttachment {
    var id: UUID = UUID()
    var storagePath: String? = nil
    var localCachePath: String? = nil
    var fileName: String = ""
    var contentType: String = "image/jpeg"
    var originalWidth: Int = 0
    var originalHeight: Int = 0
    var storedWidth: Int = 0
    var storedHeight: Int = 0
    var byteSize: Int = 0
    var altText: String = "Screenshot"
    var displayWidth: Double? = nil
    var alignmentRaw: String = NoteAttachmentAlignment.center.rawValue
    var isPreviewVisible: Bool = true
    var isAltTextUserProvided: Bool = false
    var isFileNameUserProvided: Bool = false
    var uploadStatusRaw: String = NoteAttachmentUploadStatus.pending.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil
    var lastError: String? = nil
    var note: Note? = nil

    var uploadStatus: NoteAttachmentUploadStatus {
        get { NoteAttachmentUploadStatus(rawValue: uploadStatusRaw) ?? .pending }
        set { uploadStatusRaw = newValue.rawValue }
    }

    var alignment: NoteAttachmentAlignment {
        get { NoteAttachmentAlignment(rawValue: alignmentRaw) ?? .center }
        set { alignmentRaw = newValue.rawValue }
    }

    init(
        storagePath: String? = nil,
        localCachePath: String? = nil,
        fileName: String = "",
        contentType: String = "image/jpeg",
        originalWidth: Int = 0,
        originalHeight: Int = 0,
        storedWidth: Int = 0,
        storedHeight: Int = 0,
        byteSize: Int = 0,
        altText: String = "Screenshot",
        displayWidth: Double? = nil,
        alignment: NoteAttachmentAlignment = .center,
        isPreviewVisible: Bool = true,
        isAltTextUserProvided: Bool = false,
        isFileNameUserProvided: Bool = false,
        uploadStatus: NoteAttachmentUploadStatus = .pending,
        note: Note? = nil
    ) {
        self.id = UUID()
        self.storagePath = storagePath
        self.localCachePath = localCachePath
        self.fileName = fileName
        self.contentType = contentType
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.storedWidth = storedWidth
        self.storedHeight = storedHeight
        self.byteSize = byteSize
        self.altText = altText
        self.displayWidth = displayWidth
        self.alignmentRaw = alignment.rawValue
        self.isPreviewVisible = isPreviewVisible
        self.isAltTextUserProvided = isAltTextUserProvided
        self.isFileNameUserProvided = isFileNameUserProvided
        self.uploadStatusRaw = uploadStatus.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.note = note
    }

    func duplicated(note: Note) -> NoteAttachment {
        let copy = NoteAttachment(
            storagePath: storagePath,
            localCachePath: localCachePath,
            fileName: fileName,
            contentType: contentType,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            storedWidth: storedWidth,
            storedHeight: storedHeight,
            byteSize: byteSize,
            altText: altText,
            displayWidth: displayWidth,
            alignment: alignment,
            isPreviewVisible: isPreviewVisible,
            isAltTextUserProvided: isAltTextUserProvided,
            isFileNameUserProvided: isFileNameUserProvided,
            uploadStatus: uploadStatus,
            note: note
        )
        copy.id = id
        copy.createdAt = createdAt
        copy.updatedAt = updatedAt
        copy.deletedAt = deletedAt
        copy.lastError = lastError
        return copy
    }

    var isImage: Bool {
        contentType.hasPrefix("image/")
    }

    var intrinsicPixelWidth: Int {
        max(storedWidth, originalWidth, 0)
    }

    /// `nil` display width means fit the note column. A concrete value is a user-chosen size,
    /// including original pixel width.
    func renderedDisplayWidth(availableWidth: CGFloat) -> CGFloat {
        let minimum = WiskAttachmentImageLayout.minimumWidth
        let available = max(availableWidth, minimum)
        if let displayWidth {
            return max(CGFloat(displayWidth), minimum)
        }
        let intrinsic = CGFloat(intrinsicPixelWidth)
        guard intrinsic > 0 else { return available }
        return min(max(intrinsic, minimum), available)
    }

    var displayName: String {
        if !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fileName
        }
        if !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return altText
        }
        return isImage ? "Image" : "Attachment"
    }
}

@Model
final class NoteVersion {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
    var reason: String = "edit"
    var createdAt: Date = Date()
    var note: Note? = nil

    init(title: String = "", body: String = "", reason: String = "edit", note: Note? = nil) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.reason = reason
        self.createdAt = Date()
        self.note = note
    }
}

@Model
final class NoteTag {
    var id: UUID = UUID()
    var name: String = ""
    var suggestedByAIRaw: Bool = false
    var createdAt: Date = Date()
    var note: Note? = nil

    init(name: String = "", suggestedByAI: Bool = false, note: Note? = nil) {
        self.id = UUID()
        self.name = name
        self.suggestedByAIRaw = suggestedByAI
        self.createdAt = Date()
        self.note = note
    }
}

@Model
final class NoteProject {
    var id: UUID = UUID()
    var name: String = ""
    var suggestedByAI: Bool = false
    var createdAt: Date = Date()
    var note: Note? = nil

    init(name: String = "", suggestedByAI: Bool = false, note: Note? = nil) {
        self.id = UUID()
        self.name = name
        self.suggestedByAI = suggestedByAI
        self.createdAt = Date()
        self.note = note
    }
}

enum SyncStatus: String, Codable, CaseIterable, Sendable {
    case local
    case queued
    case synced
    case conflict
}

enum SyncMutationKind: String, Codable, CaseIterable, Sendable {
    case upsertNote
    case deleteNote
    case upsertParsedItem
    case updateShare
}

@Model
final class SyncMutation {
    var id: UUID = UUID()
    var kindRaw: String = SyncMutationKind.upsertNote.rawValue
    var entityID: UUID = UUID()
    var payloadJSON: String = "{}"
    var retryCount: Int = 0
    var lastError: String? = nil
    var createdAt: Date = Date()
    var syncedAt: Date? = nil

    var kind: SyncMutationKind {
        get { SyncMutationKind(rawValue: kindRaw) ?? .upsertNote }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: SyncMutationKind = .upsertNote, entityID: UUID = UUID(), payloadJSON: String = "{}") {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.entityID = entityID
        self.payloadJSON = payloadJSON
        self.createdAt = Date()
    }
}

@Model
final class SyncConflict {
    var id: UUID = UUID()
    var entityID: UUID = UUID()
    var localJSON: String = "{}"
    var remoteJSON: String = "{}"
    var resolvedAt: Date? = nil
    var createdAt: Date = Date()

    init(entityID: UUID = UUID(), localJSON: String = "{}", remoteJSON: String = "{}") {
        self.id = UUID()
        self.entityID = entityID
        self.localJSON = localJSON
        self.remoteJSON = remoteJSON
        self.createdAt = Date()
    }
}

enum NoteShareRole: String, Codable, CaseIterable, Sendable {
    case owner
    case editor
    case viewer
}

@Model
final class NoteShare {
    var id: UUID = UUID()
    var email: String = ""
    var roleRaw: String = NoteShareRole.viewer.rawValue
    var remoteID: String? = nil
    var createdAt: Date = Date()
    var note: Note? = nil

    var role: NoteShareRole {
        get { NoteShareRole(rawValue: roleRaw) ?? .viewer }
        set { roleRaw = newValue.rawValue }
    }

    init(email: String = "", role: NoteShareRole = .viewer, note: Note? = nil) {
        self.id = UUID()
        self.email = email
        self.roleRaw = role.rawValue
        self.createdAt = Date()
        self.note = note
    }
}

@Model
final class PublishedNote {
    var id: UUID = UUID()
    var slug: String = ""
    var isPublic: Bool = false
    var publishedAt: Date? = nil
    var remoteURL: String? = nil
    var note: Note? = nil

    init(slug: String = "", isPublic: Bool = false, note: Note? = nil) {
        self.id = UUID()
        self.slug = slug
        self.isPublic = isPublic
        self.note = note
    }
}
