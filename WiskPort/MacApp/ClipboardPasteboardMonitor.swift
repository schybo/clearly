import AppKit
import Foundation

@MainActor
final class ClipboardPasteboardMonitor {
    private let pasteboard: NSPasteboard
    private let onCapture: (ClipboardCapture) -> Void
    var onTick: (() -> Void)?
    private var timer: Timer?
    private var lastChangeCount: Int
    private var isRecording = false

    init(
        pasteboard: NSPasteboard = .general,
        onCapture: @escaping (ClipboardCapture) -> Void
    ) {
        self.pasteboard = pasteboard
        self.onCapture = onCapture
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: ClipboardHistoryPreferences.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setRecording(_ enabled: Bool) {
        if enabled && !isRecording {
            lastChangeCount = pasteboard.changeCount
        }
        isRecording = enabled
    }

    func acknowledgeCurrentChangeCount() {
        lastChangeCount = pasteboard.changeCount
    }

    private func tick() {
        onTick?()
        guard isRecording else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        onCapture(Self.capture(from: pasteboard))
    }

    static func capture(from pasteboard: NSPasteboard) -> ClipboardCapture {
        let identifiers = pasteboard.types?.map(\.rawValue) ?? []
        var plainText = pasteboard.string(forType: .string) ?? ""
        let rtfData = pasteboard.data(forType: .rtf)
        if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let rtfData,
           let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            plainText = attributed.string
        }
        return ClipboardCapture(
            plainText: plainText,
            rtfData: rtfData,
            isConcealed: identifiers.contains(concealedTypeIdentifier),
            isTransient: identifiers.contains(transientTypeIdentifier),
            sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

    static let concealedTypeIdentifier = "org.nspasteboard.ConcealedType"
    static let transientTypeIdentifier = "org.nspasteboard.TransientType"
}
