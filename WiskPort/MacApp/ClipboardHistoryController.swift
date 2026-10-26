import AppKit
import ApplicationServices
import Carbon
import Foundation
import Observation
import SwiftUI

enum ClipboardAccessibility {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func prompt() {
        let options = [promptOptionKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Matches `kAXTrustedCheckOptionPrompt` without reading that shared global.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"
}

enum ClipboardDirectPaste {
    static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

@MainActor
@Observable
final class ClipboardHistoryController {
    let store: ClipboardHistoryStore

    var searchQuery = ""
    var highlightedClipID: UUID?
    var statusMessage: String?
    var panelPresented = false

    var recordingEnabled: Bool {
        didSet {
            defaults.set(recordingEnabled, forKey: ClipboardHistoryPreferences.recordingEnabledKey)
            guard didStart else { return }
            monitor?.setRecording(recordingEnabled)
        }
    }

    var historyLimit: Int {
        didSet {
            let clamped = ClipboardHistoryPreferences.clampedLimit(historyLimit)
            if clamped != historyLimit {
                historyLimit = clamped
                return
            }
            defaults.set(historyLimit, forKey: ClipboardHistoryPreferences.historyLimitKey)
            store.setHistoryLimit(historyLimit)
        }
    }

    var pasteAsPlainText: Bool {
        didSet {
            defaults.set(pasteAsPlainText, forKey: ClipboardHistoryPreferences.pasteAsPlainTextKey)
        }
    }

    var directPaste: Bool {
        didSet {
            defaults.set(directPaste, forKey: ClipboardHistoryPreferences.directPasteKey)
            if directPaste && !oldValue {
                ClipboardAccessibility.prompt()
            }
        }
    }

    var pasteHint: String {
        if directPaste && ClipboardAccessibility.isTrusted {
            return "Return pastes into the front app."
        }
        return "Return copies. Press ⌘V to paste."
    }

    private let defaults: UserDefaults
    private let isIsolated: Bool
    private var didStart = false
    private var monitor: ClipboardPasteboardMonitor?
    private var presenter: ClipboardMenuBarPresenter?
    private var hotkey: ClipboardHotkey?
    private var pasteTarget: NSRunningApplication?
    private var lastNonWiskApp: NSRunningApplication?
    /// True when Wisk was already the front app on the last poll, before a menu-bar click can focus it.
    private var appWasActive = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let isolated = WiskModelContainer.shouldIsolateStore()
        self.isIsolated = isolated
        let limit = ClipboardHistoryPreferences.storedHistoryLimit(defaults: defaults)
        self.historyLimit = limit
        self.recordingEnabled = ClipboardHistoryPreferences.storedRecordingEnabled(defaults: defaults)
        self.pasteAsPlainText = defaults.bool(forKey: ClipboardHistoryPreferences.pasteAsPlainTextKey)
        self.directPaste = defaults.bool(forKey: ClipboardHistoryPreferences.directPasteKey)
        let fileURL = isolated ? Self.isolatedFileURL() : ClipboardHistoryPreferences.defaultFileURL()
        self.store = ClipboardHistoryStore(fileURL: fileURL, historyLimit: limit)
    }

    func start() {
        guard !isIsolated, !didStart else { return }
        didStart = true
        let monitor = ClipboardPasteboardMonitor { [weak self] capture in
            _ = self?.store.record(capture)
        }
        monitor.onTick = { [weak self] in
            self?.noteFrontApp()
        }
        monitor.setRecording(recordingEnabled)
        monitor.start()
        self.monitor = monitor

        let presenter = ClipboardMenuBarPresenter(controller: self)
        presenter.install()
        self.presenter = presenter

        let hotkey = ClipboardHotkey { [weak self] in
            self?.toggleFromHotkey()
        }
        hotkey.register()
        self.hotkey = hotkey
        noteFrontApp()
    }

    func visibleClips() -> [ClipboardClip] {
        store.search(searchQuery)
    }

    func syncHighlightToSearch() {
        let results = visibleClips()
        if let highlightedClipID, results.contains(where: { $0.id == highlightedClipID }) {
            return
        }
        highlightedClipID = results.first?.id
    }

    func moveHighlight(by delta: Int) {
        let results = visibleClips()
        guard !results.isEmpty else {
            highlightedClipID = nil
            return
        }
        guard let current = results.firstIndex(where: { $0.id == highlightedClipID }) else {
            highlightedClipID = results.first?.id
            return
        }
        let next = min(max(current + delta, 0), results.count - 1)
        highlightedClipID = results[next].id
    }

    func pasteHighlighted() {
        let results = visibleClips()
        let clip = results.first { $0.id == highlightedClipID } ?? results.first
        guard let clip else { return }
        paste(clip)
    }

    func paste(_ clip: ClipboardClip) {
        highlightedClipID = clip.id
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteAsPlainText, let rtfData = clip.rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        pasteboard.setString(clip.plainText, forType: .string)
        monitor?.acknowledgeCurrentChangeCount()

        if directPaste, ClipboardAccessibility.isTrusted {
            statusMessage = nil
            presenter?.closeAndPaste(into: pasteTarget)
            return
        }
        statusMessage = "Copied. Press ⌘V to paste."
    }

    func togglePinned(_ id: UUID) {
        guard let clip = store.clips.first(where: { $0.id == id }) else { return }
        store.setPinned(!clip.pinned, id: id)
    }

    func deleteHighlighted() {
        guard searchQuery.isEmpty, let highlightedClipID else { return }
        store.delete(id: highlightedClipID)
        syncHighlightToSearch()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func toggleFromHotkey() {
        guard let presenter else { return }
        if presenter.isShown {
            presenter.close()
            return
        }
        capturePasteTargetFromHotkey()
        presenter.show()
    }

    func toggleFromStatusItem() {
        guard let presenter else { return }
        if presenter.isShown {
            presenter.close()
            return
        }
        capturePasteTargetFromStatusItem()
        presenter.show()
    }

    func showPanel() {
        guard let presenter else { return }
        if presenter.isShown { return }
        capturePasteTargetFromStatusItem()
        presenter.show()
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let presenter, presenter.isShown else { return false }
        guard presenter.isKeyWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        switch event.keyCode {
        case 126:
            moveHighlight(by: -1)
            return true
        case 125:
            moveHighlight(by: 1)
            return true
        case 36, 76:
            pasteHighlighted()
            return true
        case 51:
            guard searchQuery.isEmpty else { return false }
            deleteHighlighted()
            return true
        default:
            return false
        }
    }

    private func noteFrontApp() {
        guard presenter?.isShown != true else { return }
        appWasActive = NSApp.isActive
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return
        }
        lastNonWiskApp = front
    }

    private func capturePasteTargetFromHotkey() {
        if !NSApp.isActive,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            lastNonWiskApp = front
            pasteTarget = front
            return
        }
        pasteTarget = NSRunningApplication.current
    }

    private func capturePasteTargetFromStatusItem() {
        if appWasActive {
            pasteTarget = NSRunningApplication.current
            return
        }
        if !NSApp.isActive,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            lastNonWiskApp = front
            pasteTarget = front
            return
        }
        pasteTarget = lastNonWiskApp ?? NSRunningApplication.current
    }

    private static func isolatedFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wisk-clipboard-isolated", isDirectory: true)
            .appendingPathComponent(ClipboardHistoryPreferences.fileName)
    }
}

@MainActor
private final class ClipboardMenuBarPresenter: NSObject, NSPopoverDelegate {
    private weak var controller: ClipboardHistoryController?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var keyMonitor: Any?

    var isShown: Bool { popover.isShown }

    var isKeyWindow: Bool {
        popover.contentViewController?.view.window?.isKeyWindow == true
    }

    init(controller: ClipboardHistoryController) {
        self.controller = controller
        super.init()
    }

    func install() {
        if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard History") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "Clips"
        statusItem.button?.toolTip = "Clipboard History"
        statusItem.button?.setAccessibilityLabel("Clipboard History")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseDown])

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 520)
        if let controller {
            let root = ClipboardHistoryPanel()
                .environment(controller)
                .frame(width: 380, height: 520)
            let hosting = NSHostingController(rootView: root)
            hosting.view.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
            popover.contentViewController = hosting
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.controller?.handleKeyDown(event) ?? false
            }
            return handled ? nil : event
        }
    }

    func show() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate()
    }

    func close() {
        popover.performClose(nil)
    }

    func closeAndPaste(into target: NSRunningApplication?) {
        popover.performClose(nil)
        if let target, target.processIdentifier != NSRunningApplication.current.processIdentifier {
            _ = target.activate(from: NSRunningApplication.current, options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            ClipboardDirectPaste.postCommandV()
        }
    }

    @objc private func statusItemClicked() {
        controller?.toggleFromStatusItem()
    }

    func popoverDidShow(_ notification: Notification) {
        controller?.panelPresented = true
    }

    func popoverDidClose(_ notification: Notification) {
        controller?.panelPresented = false
    }
}

private final class ClipboardHotkey: @unchecked Sendable {
    private let onPress: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    func register() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotkeyPressed,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        let hotKeyID = EventHotKeyID(signature: fourCharCode("WISK"), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    fileprivate func fire() {
        // Carbon delivers hotkey events on the main thread.
        MainActor.assumeIsolated {
            onPress()
        }
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }
}

private func clipboardHotkeyPressed(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    Unmanaged<ClipboardHotkey>.fromOpaque(userData).takeUnretainedValue().fire()
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) + OSType($1) }
}
