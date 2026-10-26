import Foundation
import os

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum WiskEditorPerformance {
    static let sessionCapacity = 8
    static let restyleDebounceNanoseconds: UInt64 = 60_000_000
    static let rapidSelectionWindowNanoseconds: UInt64 = 160_000_000
    static let eagerStyleUTF16Window = 8_000
    static let styledCacheMaxUTF16 = 250_000
    static let widthSettleNanoseconds: UInt64 = 80_000_000
    static let widthChangeEpsilon: CGFloat = 0.5
}

enum WiskWidthCoalescerAction: Equatable {
    case unchanged
    case commitNow(CGFloat)
    case deferUntilSettled
}

/// Collapses a burst of width samples into a single commit after they stop changing.
final class WiskWidthCoalescer {
    private(set) var committedWidth: CGFloat?
    private var pendingWidth: CGFloat?

    @discardableResult
    func noteWidth(_ width: CGFloat) -> WiskWidthCoalescerAction {
        guard width > 1 else { return .unchanged }
        if let committedWidth, abs(committedWidth - width) <= WiskEditorPerformance.widthChangeEpsilon {
            pendingWidth = nil
            return .unchanged
        }
        if committedWidth == nil {
            committedWidth = width
            pendingWidth = nil
            return .commitNow(width)
        }
        pendingWidth = width
        return .deferUntilSettled
    }

    /// Applies the last pending width. Returns nil when it matches the committed width.
    @discardableResult
    func settle() -> CGFloat? {
        guard let pendingWidth else { return nil }
        self.pendingWidth = nil
        return commitIfNeeded(pendingWidth)
    }

    /// Commits `width` immediately and drops any pending sample.
    @discardableResult
    func commit(_ width: CGFloat) -> CGFloat? {
        pendingWidth = nil
        guard width > 1 else { return nil }
        return commitIfNeeded(width)
    }

    private func commitIfNeeded(_ width: CGFloat) -> CGFloat? {
        if let committedWidth, abs(committedWidth - width) <= WiskEditorPerformance.widthChangeEpsilon {
            return nil
        }
        committedWidth = width
        return width
    }
}

enum WiskEditorChromeLayout {
    static let reviewShowWidth: CGFloat = 720
    static let reviewHideWidth: CGFloat = 480
    static let compactGutterLimit: CGFloat = 720
    static let regularGutterLimit: CGFloat = 860
    static let compactGutter: CGFloat = 28
    static let regularGutter: CGFloat = 44
    static let wideGutter: CGFloat = 68
    static let reviewPanelOccupiedWidth: CGFloat = 300

    static func horizontalInset(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < compactGutterLimit {
            return compactGutter
        }
        if availableWidth < regularGutterLimit {
            return regularGutter
        }
        return wideGutter
    }

    static func showsReviewPanel(
        availableWidth: CGFloat,
        currentlyShowing: Bool,
        userEnabled: Bool
    ) -> Bool {
        guard userEnabled else { return false }
        if currentlyShowing {
            return availableWidth >= reviewHideWidth
        }
        return availableWidth >= reviewShowWidth
    }

    static func editorAvailableWidth(detailWidth: CGFloat, showsReviewPanel: Bool) -> CGFloat {
        showsReviewPanel ? max(detailWidth - reviewPanelOccupiedWidth, 0) : detailWidth
    }
}

enum WiskLibraryRecordFingerprint {
    static func hash<Record>(
        _ records: [Record],
        noteID: (Record) -> UUID,
        deletedAt: (Record) -> Date?,
        updatedAt: (Record) -> Date
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(records.count)
        for record in records {
            hasher.combine(noteID(record))
            hasher.combine(deletedAt(record))
            hasher.combine(updatedAt(record))
        }
        return hasher.finalize()
    }

    static func hash(_ records: [NoteLibraryRecord]) -> Int {
        hash(records, noteID: \.noteID, deletedAt: \.deletedAt, updatedAt: \.updatedAt)
    }
}

enum WiskListSelection {
    static func selectedIDToReveal(previousIDs: Set<UUID>, nextIDs: Set<UUID>) -> UUID? {
        guard previousIDs != nextIDs else { return nil }
        return nextIDs.first
    }
}

enum WiskEditorRestylePolicy {
    static func delayNanoseconds(sincePreviousIdentityChange previous: UInt64?, now: UInt64) -> UInt64 {
        guard let previous else { return 0 }
        let elapsed = now >= previous ? now - previous : 0
        if elapsed < WiskEditorPerformance.rapidSelectionWindowNanoseconds {
            return WiskEditorPerformance.restyleDebounceNanoseconds
        }
        return 0
    }
}

enum WiskEditorSwitchCadence {
    static var lastIdentityChangeUptime: UInt64?
    static var lastOpenedID: UUID?
}

enum WiskEditorOpenPath {
    static func shouldPaintPlainFirst(utf16Count: Int) -> Bool {
        utf16Count > WiskEditorPerformance.eagerStyleUTF16Window
    }

    /// Full document load: identity switched, or the representable was created
    /// with an empty placeholder and the real note body arrived afterward.
    /// Coordinators must stamp `lastMarkdownText` before publishing a keystroke
    /// into the SwiftUI binding, otherwise the first character looks like hydration.
    static func isDocumentReplacement(
        previousMarkdown: String,
        nextMarkdown: String,
        identityChanged: Bool
    ) -> Bool {
        if identityChanged {
            return true
        }
        return previousMarkdown != nextMarkdown && previousMarkdown.isEmpty
    }

    /// Leaving a note before its body hydrates must not clobber a good LRU snapshot.
    static func shouldReplaceCachedSession(withSource source: String, existingSource: String?) -> Bool {
        if source.isEmpty, let existingSource, existingSource.isEmpty == false {
            return false
        }
        return true
    }
}

enum WiskEditorSignposts {
    static let signposter = OSSignposter(subsystem: "com.schybo.wisk", category: "EditorOpen")
    static let log = Logger(subsystem: "com.schybo.wisk", category: "EditorOpen")

    @discardableResult
    static func interval<T>(_ name: StaticString, perform: () -> T) -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return perform()
    }

    static func cacheHit(utf16Count: Int) {
        signposter.emitEvent("CacheHit")
        log.info("CacheHit utf16=\(utf16Count, privacy: .public)")
    }

    static func cacheMiss(utf16Count: Int, delayNanoseconds: UInt64) {
        signposter.emitEvent("CacheMiss")
        log.info("CacheMiss utf16=\(utf16Count, privacy: .public) delayNs=\(delayNanoseconds, privacy: .public)")
    }
}

struct WiskEditorSessionSnapshot {
    var source: String
    var document: WiskMarkdownDocument
    var caretUTF16: Int
    var scrollFraction: CGFloat
    var foldedLocations: Set<Int>
    var showSourceMarkers: Bool
    var styled: NSAttributedString?
}

final class WiskEditorSessionCache {
    static let shared = WiskEditorSessionCache()
    private let lock = NSLock()

    private var order: [UUID] = []
    private var items: [UUID: WiskEditorSessionSnapshot] = [:]

    func store(id: UUID, snapshot: WiskEditorSessionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        items[id] = snapshot
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > WiskEditorPerformance.sessionCapacity {
            let evicted = order.removeFirst()
            items[evicted] = nil
        }
    }

    func snapshot(id: UUID) -> WiskEditorSessionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    func document(
        id: UUID,
        source: String,
        showSourceMarkers: Bool,
        foldedLocations: Set<Int>
    ) -> WiskMarkdownDocument? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = items[id], matchesFingerprint(snapshot, source: source, showSourceMarkers: showSourceMarkers) else {
            return nil
        }
        _ = foldedLocations
        return snapshot.document
    }

    func styled(
        id: UUID,
        source: String,
        showSourceMarkers: Bool,
        foldedLocations: Set<Int>
    ) -> NSAttributedString? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = items[id], matchesFingerprint(snapshot, source: source, showSourceMarkers: showSourceMarkers) else {
            return nil
        }
        _ = foldedLocations
        return snapshot.styled
    }

    private func matchesFingerprint(
        _ snapshot: WiskEditorSessionSnapshot,
        source: String,
        showSourceMarkers: Bool
    ) -> Bool {
        snapshot.source == source && snapshot.showSourceMarkers == showSourceMarkers
    }
}

enum WiskMarkdownParseCache {
    static func document(
        for source: String,
        cachedSource: inout String?,
        cachedDocument: inout WiskMarkdownDocument?,
        dirtySourceRange: NSRange? = nil
    ) -> WiskMarkdownDocument {
        if cachedSource == source, let cachedDocument {
            return cachedDocument
        }
        let parsed: WiskMarkdownDocument
        if let previousSource = cachedSource,
           let previous = cachedDocument,
           let dirtySourceRange,
           previousSource != source {
            parsed = WiskMarkdownDocumentEngine.parse(
                source,
                previous: previous,
                dirtySourceRange: dirtySourceRange
            )
        } else {
            parsed = WiskEditorSignposts.interval("Parse") {
                WiskMarkdownDocumentEngine.parse(source)
            }
        }
        cachedSource = source
        cachedDocument = parsed
        return parsed
    }
}
