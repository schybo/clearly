import FirebaseStorage
import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class WiskAttachmentService {
    static let maxAttachmentByteSize = 50 * 1024 * 1024
    static let maxImageImportByteSize = 100 * 1024 * 1024
    private let authService: WiskAuthService
    private let storage: Storage
    private let fileManager: FileManager

    private(set) var lastErrorMessage: String?

    init(
        authService: WiskAuthService,
        storage: Storage = Storage.storage(),
        fileManager: FileManager = .default
    ) {
        self.authService = authService
        self.storage = storage
        self.fileManager = fileManager
    }

    func makePendingAttachment(from imageData: Data, note: Note, altText: String = "Screenshot") throws -> (attachment: NoteAttachment, normalizedImage: WiskNormalizedAttachmentImage) {
        guard imageData.count <= Self.maxImageImportByteSize else {
            throw WiskAttachmentError.fileTooLarge(maxMegabytes: Self.maxImageImportByteSize / 1_048_576)
        }
        let normalizedImage = try Self.normalizedImage(from: imageData)
        let attachment = NoteAttachment(
            fileName: "\(altText).\(normalizedImage.fileExtension)",
            contentType: normalizedImage.contentType,
            originalWidth: normalizedImage.originalWidth,
            originalHeight: normalizedImage.originalHeight,
            storedWidth: normalizedImage.storedWidth,
            storedHeight: normalizedImage.storedHeight,
            byteSize: normalizedImage.byteSize,
            altText: altText,
            uploadStatus: .pending,
            note: note
        )
        let cachePath = try cache(normalizedImage.data, attachmentID: attachment.id, fileExtension: normalizedImage.fileExtension)
        attachment.localCachePath = cachePath
        return (attachment, normalizedImage)
    }

    func makePendingFileAttachment(
        from fileData: Data,
        fileName: String,
        contentType: String,
        note: Note
    ) throws -> NoteAttachment {
        guard fileData.count <= Self.maxAttachmentByteSize else {
            throw WiskAttachmentError.fileTooLarge(maxMegabytes: Self.maxAttachmentByteSize / 1_048_576)
        }
        guard Self.isSafeContentType(contentType, fileName: fileName) else {
            throw WiskAttachmentError.unsupportedFileType
        }
        let attachment = NoteAttachment(
            fileName: fileName,
            contentType: contentType,
            byteSize: fileData.count,
            altText: fileName,
            uploadStatus: .pending,
            note: note
        )
        attachment.localCachePath = try cache(fileData, attachmentID: attachment.id, fileExtension: Self.fileExtension(for: contentType, fallbackFileName: fileName))
        return attachment
    }

    func upload(_ attachment: NoteAttachment, imageData: Data, noteID: UUID) async {
        await upload(attachment, data: imageData, noteID: noteID)
    }

    func upload(_ attachment: NoteAttachment, data: Data, noteID: UUID) async {
        guard data.count <= Self.maxAttachmentByteSize else {
            markUploadFailed(
                attachment,
                message: WiskAttachmentError.fileTooLarge(
                    maxMegabytes: Self.maxAttachmentByteSize / 1_048_576
                ).localizedDescription
            )
            return
        }
        guard let uid = authService.firebaseUID else {
            markUploadFailed(attachment, message: "Sign in before uploading attachments.")
            return
        }

        let fileExtension = Self.fileExtension(for: attachment.contentType, fallbackFileName: attachment.fileName)
        let path = "users/\(uid)/notes/\(noteID.uuidString)/attachments/\(attachment.id.uuidString).\(fileExtension)"
        let reference = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = attachment.contentType

        do {
            try await putData(data, metadata: metadata, reference: reference)
            attachment.storagePath = path
            attachment.uploadStatus = .uploaded
            attachment.updatedAt = Date()
            attachment.lastError = nil
            lastErrorMessage = nil
        } catch {
            markUploadFailed(attachment, message: error.localizedDescription)
        }
    }

    func retryUpload(_ attachment: NoteAttachment, noteID: UUID) async {
        guard let data = localData(for: attachment) else {
            markUploadFailed(attachment, message: "Wisk could not find the local attachment cache.")
            return
        }
        attachment.uploadStatus = .pending
        attachment.lastError = nil
        attachment.updatedAt = Date()
        await upload(attachment, data: data, noteID: noteID)
    }

    static let maxHealsPerLaunch = 50

    /// True when an attachment never landed in Storage and can still be
    /// uploaded from this device's local cache.
    static func isHealCandidate(_ attachment: NoteAttachment) -> Bool {
        guard attachment.storagePath == nil,
              attachment.deletedAt == nil,
              attachment.note?.deletedAt == nil else { return false }
        return attachment.uploadStatus == .pending || attachment.uploadStatus == .failed
    }

    /// Re-uploads attachments whose bytes are cached locally but which never
    /// landed in Storage. Paste uploads are fire-and-forget, so quitting the
    /// app mid-upload (or Storage being unavailable) left images stuck as
    /// device-local: the pasting device kept rendering them from cache while
    /// every other device saw a broken reference. Runs once per launch after
    /// the first sync; attachments without local bytes are skipped because
    /// they can only heal on the device that has them.
    @MainActor
    func healPendingUploads(context: ModelContext, syncService: SyncService) async {
        guard authService.firebaseUID != nil else { return }
        let pendingRaw = NoteAttachmentUploadStatus.pending.rawValue
        let failedRaw = NoteAttachmentUploadStatus.failed.rawValue
        var descriptor = FetchDescriptor<NoteAttachment>(
            predicate: #Predicate {
                $0.uploadStatusRaw == pendingRaw || $0.uploadStatusRaw == failedRaw
            }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        guard candidates.isEmpty == false else { return }

        var healedNotes: [Note] = []
        for attachment in candidates {
            guard healedNotes.count < Self.maxHealsPerLaunch else { break }
            guard Self.isHealCandidate(attachment),
                  let note = attachment.note,
                  let data = localData(for: attachment) else { continue }
            await upload(attachment, data: data, noteID: note.id)
            guard attachment.uploadStatus == .uploaded else { continue }
            note.updatedAt = Date()
            note.syncStatus = .queued
            healedNotes.append(note)
        }
        guard healedNotes.isEmpty == false else { return }
        try? context.save()
        syncService.enqueue(notes: healedNotes, context: context)
    }

    func data(for attachment: NoteAttachment) async -> Data? {
        if let data = localData(for: attachment) {
            return data
        }

        guard let storagePath = attachment.storagePath else { return nil }

        do {
            let data = try await downloadData(reference: storage.reference().child(storagePath))
            attachment.localCachePath = try cache(data, attachmentID: attachment.id, fileExtension: Self.fileExtension(for: attachment.contentType, fallbackFileName: attachment.fileName))
            return data
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func removeLocalCache(for attachment: NoteAttachment) {
        guard let localCachePath = attachment.localCachePath else { return }
        try? fileManager.removeItem(at: cacheDirectory().appendingPathComponent(localCachePath))
        attachment.localCachePath = nil
    }

    private func markUploadFailed(_ attachment: NoteAttachment, message: String) {
        attachment.uploadStatus = .failed
        attachment.lastError = message
        attachment.updatedAt = Date()
        lastErrorMessage = message
    }

    private func localData(for attachment: NoteAttachment) -> Data? {
        if let localCachePath = attachment.localCachePath,
           let data = try? Data(contentsOf: cacheDirectory().appendingPathComponent(localCachePath)) {
            return data
        }

        let fallbackPath = Self.cacheFileName(for: attachment)
        guard let data = try? Data(contentsOf: cacheDirectory().appendingPathComponent(fallbackPath)) else {
            return nil
        }
        attachment.localCachePath = fallbackPath
        return data
    }

    func replaceCroppedImage(
        _ attachment: NoteAttachment,
        croppedData: Data
    ) throws -> WiskNormalizedAttachmentImage {
        let normalizedImage = try Self.normalizedImage(from: croppedData)
        let cachePath = try cache(
            normalizedImage.data,
            attachmentID: attachment.id,
            fileExtension: normalizedImage.fileExtension
        )
        attachment.localCachePath = cachePath
        attachment.contentType = normalizedImage.contentType
        attachment.originalWidth = normalizedImage.originalWidth
        attachment.originalHeight = normalizedImage.originalHeight
        attachment.storedWidth = normalizedImage.storedWidth
        attachment.storedHeight = normalizedImage.storedHeight
        attachment.byteSize = normalizedImage.byteSize
        attachment.uploadStatus = .pending
        attachment.updatedAt = Date()
        return normalizedImage
    }

    static func crop(
        imageData: Data,
        normalizedRect: CGRect
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WiskAttachmentError.invalidImage
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { throw WiskAttachmentError.invalidImage }

        let clamped = CGRect(
            x: min(max(normalizedRect.minX, 0), 1),
            y: min(max(normalizedRect.minY, 0), 1),
            width: min(max(normalizedRect.width, 0.05), 1),
            height: min(max(normalizedRect.height, 0.05), 1)
        )
        var pixel = CGRect(
            x: (clamped.minX * width).rounded(.down),
            y: (clamped.minY * height).rounded(.down),
            width: (clamped.width * width).rounded(.up),
            height: (clamped.height * height).rounded(.up)
        )
        pixel = pixel.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard pixel.width >= 1, pixel.height >= 1 else { throw WiskAttachmentError.invalidImage }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: Int(pixel.width),
            height: Int(pixel.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw WiskAttachmentError.invalidImage
        }
        context.translateBy(x: -pixel.minX, y: -(height - pixel.maxY))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let cropped = context.makeImage(),
              let encoded = encodedData(for: cropped, contentType: UTType.png.identifier, quality: nil) else {
            throw WiskAttachmentError.invalidImage
        }
        return encoded
    }

    private func cache(_ data: Data, attachmentID: UUID, fileExtension: String) throws -> String {
        let directory = cacheDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(attachmentID.uuidString).\(fileExtension)"
        try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
        return fileName
    }

    private func cacheDirectory() -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("WiskAttachments", isDirectory: true)
    }

    nonisolated static func cacheFileName(for attachment: NoteAttachment) -> String {
        "\(attachment.id.uuidString).\(fileExtension(for: attachment.contentType, fallbackFileName: attachment.fileName))"
    }

    private func putData(_ data: Data, metadata: StorageMetadata, reference: StorageReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.putData(data, metadata: metadata) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func downloadData(reference: StorageReference) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            reference.getData(maxSize: 50 * 1024 * 1024) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WiskAttachmentError.missingImageData)
                }
            }
        }
    }

    static func normalizedImage(from data: Data, maxLongEdge: CGFloat = 2400) throws -> WiskNormalizedAttachmentImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw WiskAttachmentError.invalidImage
        }

        let originalWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let originalHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxOriginalEdge = max(originalWidth, originalHeight)
        let thumbnailMaxPixelSize = maxOriginalEdge > 0 ? min(maxOriginalEdge, Int(maxLongEdge)) : Int(maxLongEdge)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WiskAttachmentError.invalidImage
        }

        if let pngData = encodedData(for: image, contentType: UTType.png.identifier, quality: nil),
           pngData.count <= 2 * 1024 * 1024 {
            return WiskNormalizedAttachmentImage(
                data: pngData,
                contentType: UTType.png.preferredMIMEType ?? "image/png",
                fileExtension: "png",
                originalWidth: originalWidth,
                originalHeight: originalHeight,
                storedWidth: image.width,
                storedHeight: image.height
            )
        }

        guard let jpegData = encodedData(for: image, contentType: UTType.jpeg.identifier, quality: 0.86) else {
            throw WiskAttachmentError.invalidImage
        }
        return WiskNormalizedAttachmentImage(
            data: jpegData,
            contentType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
            fileExtension: "jpg",
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            storedWidth: image.width,
            storedHeight: image.height
        )
    }

    private static func encodedData(for image: CGImage, contentType: String, quality: CGFloat?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, contentType as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated static func fileExtension(for contentType: String, fallbackFileName: String = "") -> String {
        if let extensionFromName = fallbackFileName.split(separator: ".").last,
           extensionFromName != fallbackFileName {
            return String(extensionFromName).lowercased()
        }
        switch contentType {
        case "image/png":
            return "png"
        case "image/jpeg":
            return "jpg"
        case "image/heic", "image/heif":
            return "heic"
        case "image/gif":
            return "gif"
        case "application/pdf":
            return "pdf"
        case "text/plain":
            return "txt"
        case "text/markdown":
            return "md"
        default:
            return "bin"
        }
    }

    static func isSafeContentType(_ contentType: String, fileName: String) -> Bool {
        let deniedTypes: Set<String> = [
            "application/x-mach-binary",
            "application/x-executable",
            "application/x-sh",
            "application/x-shellscript",
        ]
        guard !deniedTypes.contains(contentType.lowercased()) else { return false }
        let deniedExtensions: Set<String> = ["app", "command", "dylib", "exe", "sh"]
        return !deniedExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }
}

enum WiskAttachmentImportTypes {
    static let fileTypes: [UTType] = [
        .image,
        .pdf,
        .plainText,
        .text,
        .data,
    ]

    static func contentType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }
}

struct WiskNormalizedAttachmentImage: Sendable {
    let data: Data
    let contentType: String
    let fileExtension: String
    let originalWidth: Int
    let originalHeight: Int
    let storedWidth: Int
    let storedHeight: Int

    var byteSize: Int {
        data.count
    }
}

enum WiskAttachmentError: LocalizedError {
    case invalidImage
    case missingImageData
    case fileTooLarge(maxMegabytes: Int)
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Choose a JPEG, PNG, or HEIC image."
        case .missingImageData:
            return "Wisk could not read the screenshot data."
        case .fileTooLarge(let maxMegabytes):
            return "Choose a file smaller than \(maxMegabytes) MB."
        case .unsupportedFileType:
            return "Wisk does not attach executable or shell-script files."
        }
    }
}
