import CoreGraphics
import Foundation
import ImageIO
import Observation

#if os(iOS)
import UIKit
typealias WiskAttachmentPlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias WiskAttachmentPlatformImage = NSImage
#endif

/// Resolution phase of an attachment image for inline editor rendering.
enum WiskAttachmentImagePhase: Equatable {
    case idle
    case loading
    case loaded
    case failed

    /// Stable token for attachment render fingerprints.
    var renderToken: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed: return "failed"
        }
    }
}

/// Resolves attachment bytes for the rich markdown editor, including the async
/// Firebase Storage download path that `WiskAttachmentService.data(for:)`
/// provides. The editor used to render attachments from the synchronous local
/// cache only, so notes synced from another device showed `[Image] …` text
/// instead of the image; this store closes that gap.
///
/// The store bumps `renderGeneration` and posts
/// `resolutionDidChangeNotification` whenever a phase changes so editor views
/// can re-render the affected attachment blocks when a download completes or
/// fails. The attributed-string render pipeline is synchronous and nonisolated
/// (it runs from both editor coordinators and pure unit tests), so this store
/// is thread-safe by lock rather than actor-bound.
final class WiskAttachmentImageStore {
    static let shared = WiskAttachmentImageStore()

    /// Posted (from any thread) whenever any attachment's resolution phase
    /// changes. Editors observe this to swap placeholders for resolved images.
    static let resolutionDidChangeNotification = Notification.Name("WiskAttachmentImageStore.resolutionDidChange")

    /// Incremented whenever any attachment's phase changes.
    var renderGeneration: Int {
        get { lock.withLock { _renderGeneration } }
    }

    private let lock = NSLock()
    private var _renderGeneration = 0
    private var service: WiskAttachmentService?
    private var phases: [UUID: WiskAttachmentImagePhase] = [:]
    private var inflight: Set<UUID> = []
    /// The fetchable source (storage path / local cache) present when the
    /// attachment last failed, so a failure can be retried automatically once
    /// the source changes (e.g. a sync lands the storage path for an
    /// attachment that previously had nowhere to fetch from).
    private var failedSources: [UUID: String] = [:]
    private let imageCache = NSCache<NSUUID, WiskAttachmentPlatformImage>()
    private let dataCache = NSCache<NSUUID, NSData>()

    init() {
        imageCache.countLimit = 48
        dataCache.countLimit = 24
    }

    /// Inject the app's environment-owned attachment service. Falls back to a
    /// lazily constructed service so previews and tests keep working.
    func configure(service: WiskAttachmentService) {
        lock.lock()
        let unset = self.service == nil
        if unset { self.service = service }
        lock.unlock()
    }

    /// Drops every cached render and phase. Used when switching notes in
    /// tests and when attachment bytes change underneath the cache.
    func reset() {
        lock.lock()
        phases.removeAll()
        inflight.removeAll()
        failedSources.removeAll()
        _renderGeneration += 1
        lock.unlock()
        notifyResolutionDidChange()
        imageCache.removeAllObjects()
        dataCache.removeAllObjects()
    }

    // MARK: - Queries

    /// Current phase for an attachment. A locally available image reports
    /// `.loaded` even if async resolution never ran.
    func phase(for attachment: NoteAttachment) -> WiskAttachmentImagePhase {
        lock.lock()
        let recorded = phases[attachment.id] ?? .idle
        lock.unlock()
        if recorded == .loaded { return .loaded }
        if attachment.isImage, imageCache.object(forKey: Self.key(for: attachment.id)) != nil {
            return .loaded
        }
        if attachmentData(for: attachment) != nil {
            return .loaded
        }
        return recorded
    }

    // MARK: - Image resolution (images)

    /// Returns a display-ready, downsampled image when one is available.
    /// When `nil` is returned the store has started (or already failed) the
    /// async resolution; check `phase(for:)` to render a placeholder or a
    /// retry affordance.
    func displayImage(for attachment: NoteAttachment, displayWidth: CGFloat) -> WiskAttachmentPlatformImage? {
        guard attachment.isImage else { return nil }

        let cacheKey = Self.key(for: attachment.id)
        if let cached = imageCache.object(forKey: cacheKey) {
            if CGFloat(cached.pixelWidth) >= displayWidth || cached.pixelWidth <= Self.maxDownsamplePixel {
                return cached
            }
        }

        guard let data = attachmentData(for: attachment) else {
            startResolutionIfNeeded(for: attachment)
            return nil
        }

        let maxPixel = min(max(displayWidth * Self.screenScale, 320), CGFloat(Self.maxDownsamplePixel))
        guard let image = Self.downsampledImage(from: data, maxPixelSize: CGFloat(maxPixel)) else {
            setPhase(.failed, for: attachment.id)
            return nil
        }
        imageCache.setObject(image, forKey: cacheKey)
        setPhase(.loaded, for: attachment.id)
        return image
    }

    /// Retries resolution after a failure (tap-to-retry path).
    func retry(for attachment: NoteAttachment) {
        lock.lock()
        phases[attachment.id] = .idle
        inflight.remove(attachment.id)
        failedSources.removeValue(forKey: attachment.id)
        _renderGeneration += 1
        lock.unlock()
        notifyResolutionDidChange()
        imageCache.removeObject(forKey: Self.key(for: attachment.id))
        _ = displayImage(for: attachment, displayWidth: WiskAttachmentImageLayout.defaultAvailableWidth)
    }

    /// Clears cached renders when an attachment's bytes change (crop,
    /// re-upload) so stale images are never shown.
    func invalidate(for attachmentID: UUID) {
        imageCache.removeObject(forKey: Self.key(for: attachmentID))
        dataCache.removeObject(forKey: Self.key(for: attachmentID))
        lock.lock()
        failedSources.removeValue(forKey: attachmentID)
        lock.unlock()
        setPhase(.idle, for: attachmentID)
    }

    // MARK: - Data resolution (PDFs and other inline previews)

    /// Returns attachment bytes when already available locally, kicking off a
    /// download otherwise. Used for PDF thumbnails and other data-driven
    /// inline previews.
    func resolvedData(for attachment: NoteAttachment) -> Data? {
        if let data = attachmentData(for: attachment) {
            return data
        }
        startResolutionIfNeeded(for: attachment)
        return nil
    }

    // MARK: - Internals

    private func setPhase(_ phase: WiskAttachmentImagePhase, for attachmentID: UUID) {
        lock.lock()
        let changed = phases[attachmentID] != phase
        phases[attachmentID] = phase
        if changed { _renderGeneration += 1 }
        lock.unlock()
        if changed { notifyResolutionDidChange() }
    }

    private func notifyResolutionDidChange() {
        NotificationCenter.default.post(
            name: Self.resolutionDidChangeNotification,
            object: nil
        )
    }

    private func startResolutionIfNeeded(for attachment: NoteAttachment) {
        lock.lock()
        let currentPhase = phases[attachment.id] ?? .idle
        let alreadyInflight = inflight.contains(attachment.id)
        lock.unlock()
        guard !alreadyInflight, currentPhase != .loading else { return }
        // Nothing to fetch when the attachment was never uploaded and has no
        // local cache; report failed so the UI can offer retry.
        guard attachment.storagePath != nil || attachment.localCachePath != nil else {
            if currentPhase == .failed, failedSources[attachment.id] == Self.fetchSource(for: attachment) {
                return // unchanged: stay failed until an explicit retry
            }
            setPhase(.failed, for: attachment.id)
            lock.lock()
            failedSources[attachment.id] = Self.fetchSource(for: attachment)
            lock.unlock()
            return
        }
        if currentPhase == .failed, failedSources[attachment.id] == Self.fetchSource(for: attachment) {
            // The same source already failed this session; only an explicit
            // retry (or a changed source) re-attempts it.
            return
        }
        lock.lock()
        phases[attachment.id] = .loading
        inflight.insert(attachment.id)
        _renderGeneration += 1
        lock.unlock()
        notifyResolutionDidChange()
        let attachmentID = attachment.id
        let source = Self.fetchSource(for: attachment)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = await self.resolvedService()
            let data = await service.data(for: attachment)
            self.finishResolution(attachmentID: attachmentID, data: data, source: source)
        }
    }

    /// Identifies where attachment bytes would come from, so a recorded
    /// failure can be retried when that source changes.
    private static func fetchSource(for attachment: NoteAttachment) -> String {
        if let storagePath = attachment.storagePath {
            return "storage:\(storagePath)"
        }
        if let localCachePath = attachment.localCachePath {
            return "local:\(localCachePath)"
        }
        return "none"
    }

    private func finishResolution(attachmentID: UUID, data: Data?, source: String) {
        lock.lock()
        inflight.remove(attachmentID)
        if let data, !data.isEmpty {
            dataCache.setObject(data as NSData, forKey: Self.key(for: attachmentID))
            phases[attachmentID] = .loaded
            failedSources.removeValue(forKey: attachmentID)
        } else {
            phases[attachmentID] = .failed
            failedSources[attachmentID] = source
        }
        _renderGeneration += 1
        lock.unlock()
        notifyResolutionDidChange()
    }

    private func resolvedService() async -> WiskAttachmentService {
        lock.lock()
        let existing = service
        lock.unlock()
        if let existing { return existing }
        let created = await MainActor.run { WiskAttachmentService(authService: WiskAuthService()) }
        lock.lock()
        if service == nil { service = created }
        let resolved = service ?? created
        lock.unlock()
        return resolved
    }

    /// Full bytes for the attachment, from the in-memory cache or the local
    /// file cache. Never downloads.
    private func attachmentData(for attachment: NoteAttachment) -> Data? {
        if let data = dataCache.object(forKey: Self.key(for: attachment.id)) as Data? {
            return data
        }
        if let data = localFileData(for: attachment) {
            dataCache.setObject(data as NSData, forKey: Self.key(for: attachment.id))
            return data
        }
        return nil
    }

    private func localFileData(for attachment: NoteAttachment) -> Data? {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let directory = cacheRoot.appendingPathComponent("WiskAttachments", isDirectory: true)
        if let localCachePath = attachment.localCachePath,
           let data = try? Data(contentsOf: directory.appendingPathComponent(localCachePath)) {
            return data
        }
        let fallback = WiskAttachmentService.cacheFileName(for: attachment)
        return try? Data(contentsOf: directory.appendingPathComponent(fallback))
    }

    private static let maxDownsamplePixel = 2400

    private static var screenScale: CGFloat {
        #if os(iOS)
        UIScreen.main.scale
        #else
        2
        #endif
    }

    private static func key(for id: UUID) -> NSUUID {
        NSUUID(uuidString: id.uuidString) ?? NSUUID()
    }

    private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> WiskAttachmentPlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return decodeFullImage(from: data)
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        #elseif os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    private static func decodeFullImage(from data: Data) -> WiskAttachmentPlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }
}

extension WiskAttachmentPlatformImage {
    /// Width in pixels, normalized across UIImage/NSImage.
    var pixelWidth: Int {
        #if os(iOS)
        Int(size.width * scale)
        #else
        Int(size.width)
        #endif
    }

    /// Height in pixels, normalized across UIImage/NSImage.
    var pixelHeight: Int {
        #if os(iOS)
        Int(size.height * scale)
        #else
        Int(size.height)
        #endif
    }
}

#if os(iOS)
import UIKit
#endif

/// Rounded-rect placeholder shown while an attachment resolves (or after a
/// failure with retry), preserving the attachment's aspect ratio.
enum WiskAttachmentPlaceholder {
    static func image(
        for attachment: NoteAttachment,
        displayWidth: CGFloat,
        state: WiskAttachmentImagePhase
    ) -> WiskAttachmentPlatformImage? {
        let width = max(displayWidth, 40)
        let height = width / aspectRatio(for: attachment)
        #if os(iOS)
        let scale = UIScreen.main.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        // Renderer size is in points; `format.scale` supplies the pixel
        // density. Never multiply the point size by the scale here — that
        // double-scales the bitmap and shrinks the drawn label by 1/scale.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            drawPlaceholder(in: context.cgContext, size: CGSize(width: width, height: height), state: state)
        }
        #elseif os(macOS)
        return NSImage(size: CGSize(width: width, height: height), flipped: false) { _ in
            if let context = NSGraphicsContext.current?.cgContext {
                drawPlaceholder(in: context, size: CGSize(width: width, height: height), state: state)
            }
            return true
        }
        #endif
    }

    static func aspectRatio(for attachment: NoteAttachment) -> CGFloat {
        let storedWidth = CGFloat(attachment.storedWidth)
        let storedHeight = CGFloat(attachment.storedHeight)
        if storedWidth > 0, storedHeight > 0 {
            return storedWidth / storedHeight
        }
        return 4 / 3
    }

    private static func drawPlaceholder(in context: CGContext, size: CGSize, state: WiskAttachmentImagePhase) {
        let fill = state == .failed
            ? CGColor(red: 0.94, green: 0.90, blue: 0.87, alpha: 1)
            : CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1)
        context.setFillColor(fill)
        let rect = CGRect(origin: .zero, size: size)
        let corner = max(size.width * 0.02, 6)
        let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.addPath(path)
        context.fillPath()

        let label = state == .failed ? "Tap to retry" : "Loading…"
        let text = NSAttributedString(string: label, attributes: placeholderAttributes)
        let textSize = text.size()
        text.draw(at: CGPoint(
            x: size.width / 2 - textSize.width / 2,
            y: size.height / 2 - textSize.height / 2
        ))
    }

    private static var placeholderAttributes: [NSAttributedString.Key: Any] {
        // The placeholder fills are fixed light colors, so use a fixed dark
        // label color rather than a dynamic label color — in light mode
        // `.secondaryLabel` all but disappears against the beige/blue-gray
        // fill, and in dark mode the fill stays light anyway.
        #if os(iOS)
        [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: UIColor(white: 0.32, alpha: 1),
        ]
        #else
        [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 0.32, alpha: 1),
        ]
        #endif
    }
}
