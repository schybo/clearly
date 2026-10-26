import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS) || os(macOS)

#if os(iOS)
typealias WiskImageResizeHostView = UIView
private typealias PlatformColor = UIColor
#elseif os(macOS)
typealias WiskImageResizeHostView = NSView
private typealias PlatformColor = NSColor
#endif

final class WiskImageAttachmentResizeChrome: WiskImageResizeHostView {
    #if os(iOS)
    var hitSize: CGFloat = 24
    #else
    var hitSize: CGFloat = WiskAttachmentImageResize.macCornerHitSize
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        #if os(iOS)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityHint = "Drag the side handles to resize"
        #elseif os(macOS)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("Drag the lower-right handle to resize")
        setAccessibilityLabel("Selected image")
        setAccessibilityIdentifier("wisk.editor.imageResizeChrome")
        #endif
        isHidden = true
        #if os(iOS)
        accessibilityLabel = "Selected image"
        accessibilityIdentifier = "wisk.editor.imageResizeChrome"
        #endif
    }

    func place(over imageRect: CGRect) {
        frame = WiskAttachmentImageResize.chromeFrame(for: imageRect, hitSize: hitSize)
        #if os(iOS)
        setNeedsDisplay()
        #elseif os(macOS)
        needsDisplay = true
        #endif
    }

    #if os(macOS)
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        drawChrome()
    }
    #elseif os(iOS)
    override func draw(_ rect: CGRect) {
        drawChrome()
    }
    #endif

    private func drawChrome() {
        let imageRect = bounds.insetBy(dx: hitSize / 2, dy: hitSize / 2)
        guard imageRect.width > 1, imageRect.height > 1 else { return }

        let accent = PlatformColor.controlAccent
        let fill = PlatformColor.chromeHandleFill

        #if os(iOS)
        let visual = WiskAttachmentImageResize.handleVisualSize
        let border = UIBezierPath(roundedRect: imageRect, cornerRadius: 3)
        border.lineWidth = 1.5
        accent.setStroke()
        border.stroke()

        for handle in [WiskAttachmentImageResize.Handle.left, .right] {
            let rect = WiskAttachmentImageResize.visualHandleRect(for: handle, in: imageRect, size: visual)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 2)
            fill.setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        #elseif os(macOS)
        let rect = WiskAttachmentImageResize.visualHandleRect(
            for: .bottomRight,
            in: imageRect,
            size: WiskAttachmentImageResize.macCornerVisualSize
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        fill.setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = 1
        path.stroke()
        #endif
    }
}

@MainActor
final class WiskImageAttachmentResizeController {
    struct LiveDrag {
        var attachmentID: UUID
        var characterIndex: Int
        var width: CGFloat
        var aspectRatio: CGFloat
        var availableWidth: CGFloat
        var startWidth: CGFloat
    }

    let chrome = WiskImageAttachmentResizeChrome()

    private(set) var selectedAttachmentID: UUID?
    private(set) var selectedCharacterIndex: Int?
    private(set) var imageRect: CGRect = .null

    private struct Drag {
        var attachmentID: UUID
        var characterIndex: Int
        var handle: WiskAttachmentImageResize.Handle
        var startWidth: CGFloat
        var anchorX: CGFloat
        var aspectRatio: CGFloat
        var availableWidth: CGFloat
        var currentWidth: CGFloat
    }

    private var drag: Drag?

    var isDragging: Bool { drag != nil }
    var hasSelection: Bool { selectedAttachmentID != nil }

    private var resizeChromeKind: WiskAttachmentImageResize.ChromeKind {
        #if os(macOS)
        .bottomRightCorner
        #else
        .sidePills
        #endif
    }

    func attach(to view: WiskImageResizeHostView) {
        if chrome.superview !== view {
            chrome.removeFromSuperview()
            view.addSubview(chrome)
        }
        chrome.isHidden = true
    }

    func select(attachmentID: UUID, characterIndex: Int, imageRect: CGRect) {
        selectedAttachmentID = attachmentID
        selectedCharacterIndex = characterIndex
        updateChrome(imageRect: imageRect)
    }

    func refresh(characterIndex: Int, imageRect: CGRect) {
        selectedCharacterIndex = characterIndex
        updateChrome(imageRect: imageRect)
    }

    func updateChrome(imageRect: CGRect) {
        self.imageRect = imageRect
        guard selectedAttachmentID != nil, imageRect.width > 1, imageRect.height > 1 else {
            chrome.isHidden = true
            return
        }
        chrome.place(over: imageRect)
        chrome.isHidden = false
    }

    func clear() {
        drag = nil
        selectedAttachmentID = nil
        selectedCharacterIndex = nil
        imageRect = .null
        chrome.isHidden = true
    }

    func handle(at point: CGPoint) -> WiskAttachmentImageResize.Handle? {
        guard selectedAttachmentID != nil, chrome.isHidden == false else { return nil }
        return WiskAttachmentImageResize.handle(
            at: point,
            in: imageRect,
            hitSize: chrome.hitSize,
            kind: resizeChromeKind
        )
    }

    @discardableResult
    func beginDrag(handle: WiskAttachmentImageResize.Handle, availableWidth: CGFloat) -> Bool {
        guard let id = selectedAttachmentID,
              let index = selectedCharacterIndex,
              imageRect.width > 1 else {
            return false
        }
        drag = Drag(
            attachmentID: id,
            characterIndex: index,
            handle: handle,
            startWidth: imageRect.width,
            anchorX: WiskAttachmentImageResize.dragAnchorX(for: handle, in: imageRect),
            aspectRatio: imageRect.height / max(imageRect.width, 1),
            availableWidth: availableWidth,
            currentWidth: imageRect.width
        )
        return true
    }

    func updateDrag(currentX: CGFloat) -> LiveDrag? {
        guard var drag else { return nil }
        drag.currentWidth = WiskAttachmentImageResize.widthByFollowingPointer(
            anchorX: drag.anchorX,
            currentX: currentX,
            handle: drag.handle,
            availableWidth: drag.availableWidth
        )
        self.drag = drag
        return LiveDrag(
            attachmentID: drag.attachmentID,
            characterIndex: drag.characterIndex,
            width: drag.currentWidth,
            aspectRatio: drag.aspectRatio,
            availableWidth: drag.availableWidth,
            startWidth: drag.startWidth
        )
    }

    func finishDrag() -> (attachmentID: UUID, persistedWidth: Double?)? {
        guard let drag else { return nil }
        let persisted = WiskAttachmentImageResize.persistedDisplayWidth(
            currentWidth: drag.currentWidth,
            availableWidth: drag.availableWidth
        )
        self.drag = nil
        return (drag.attachmentID, persisted)
    }

    func cancelDrag() -> LiveDrag? {
        guard let drag else { return nil }
        let restore = LiveDrag(
            attachmentID: drag.attachmentID,
            characterIndex: drag.characterIndex,
            width: drag.startWidth,
            aspectRatio: drag.aspectRatio,
            availableWidth: drag.availableWidth,
            startWidth: drag.startWidth
        )
        self.drag = nil
        return restore
    }
}

private extension PlatformColor {
    static var controlAccent: PlatformColor {
        #if os(iOS)
        .tintColor
        #elseif os(macOS)
        .controlAccentColor
        #endif
    }

    static var chromeHandleFill: PlatformColor {
        #if os(iOS)
        .systemBackground
        #elseif os(macOS)
        .windowBackgroundColor
        #endif
    }
}

func wiskCharacterIndex(
    ofAttachmentID id: UUID,
    in attributedString: NSAttributedString
) -> Int? {
    guard attributedString.length > 0 else { return nil }
    var found: Int?
    attributedString.enumerateAttribute(
        .wiskMarkdownAttachmentID,
        in: NSRange(location: 0, length: attributedString.length)
    ) { value, range, stop in
        guard let string = value as? String, UUID(uuidString: string) == id else { return }
        found = range.location
        stop.pointee = true
    }
    return found
}

func wiskApplyLiveAttachmentWidth(
    in storage: NSTextStorage,
    at index: Int,
    width: CGFloat,
    aspectRatio: CGFloat
) {
    guard storage.length > index, index >= 0 else { return }
    var range = NSRange(location: 0, length: 0)
    guard let attachment = storage.attribute(.attachment, at: index, effectiveRange: &range) as? NSTextAttachment else {
        return
    }
    let height = width * aspectRatio
    let size = CGSize(width: width, height: height)
    #if os(iOS)
    attachment.bounds = CGRect(origin: .zero, size: size)
    #elseif os(macOS)
    attachment.bounds = CGRect(origin: .zero, size: size)
    if let sourceImage = (attachment.attachmentCell as? NSTextAttachmentCell)?.image ?? attachment.image,
       let resized = sourceImage.copy() as? NSImage {
        resized.size = NSSize(width: width, height: height)
        attachment.image = resized
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: resized)
    }
    let editedRange = range.length > 0 ? range : NSRange(location: index, length: 1)
    storage.beginEditing()
    storage.edited(.editedAttributes, range: editedRange, changeInLength: 0)
    storage.endEditing()
    #endif
}

func wiskAttachmentPresentationSize(in storage: NSTextStorage, at index: Int) -> CGSize? {
    guard storage.length > index, index >= 0 else { return nil }
    var range = NSRange(location: 0, length: 0)
    guard let attachment = storage.attribute(.attachment, at: index, effectiveRange: &range) as? NSTextAttachment else {
        return nil
    }
    if attachment.bounds.width > 1, attachment.bounds.height > 1 {
        return attachment.bounds.size
    }
    #if os(macOS)
    if let cell = attachment.attachmentCell {
        let size = cell.cellSize()
        if size.width > 1, size.height > 1 {
            return size
        }
    }
    if let image = attachment.image, image.size.width > 1, image.size.height > 1 {
        return image.size
    }
    #elseif os(iOS)
    if let image = attachment.image, image.size.width > 1, image.size.height > 1 {
        return image.size
    }
    #endif
    return nil
}

#if os(macOS)
func wiskGlyphRect(in textView: NSTextView, characterIndex: Int) -> CGRect? {
    guard let storage = textView.textStorage,
          characterIndex >= 0,
          storage.length > characterIndex else {
        return nil
    }
    let characterRange = NSRange(location: characterIndex, length: 1)
    let attachmentSize = wiskAttachmentPresentationSize(in: storage, at: characterIndex)
    var fragment = CGRect.null

    if let textLayoutManager = textView.textLayoutManager {
        let documentStart = textLayoutManager.documentRange.location
        if let location = textLayoutManager.location(documentStart, offsetBy: characterIndex) {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            textLayoutManager.enumerateTextSegments(
                in: NSTextRange(location: location),
                type: .standard,
                options: [.rangeNotRequired]
            ) { _, frame, _, _ in
                fragment = frame
                return false
            }
            if fragment.isNull || fragment.height < 1 {
                textLayoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { layoutFragment in
                    fragment = layoutFragment.layoutFragmentFrame
                    return false
                }
            }
        }
    }

    if fragment.isNull || fragment.width < 1,
       let layoutManager = textView.layoutManager,
       let textContainer = textView.textContainer {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        fragment = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    }

    guard fragment.isNull == false, fragment.width > 1 else { return nil }
    fragment.origin.x += textView.textContainerOrigin.x
    fragment.origin.y += textView.textContainerOrigin.y
    if let attachmentSize {
        return WiskAttachmentImageResize.presentationRect(
            fragmentRect: fragment,
            attachmentSize: attachmentSize
        )
    }
    return fragment
}

func wiskInvalidateAttachmentLayout(_ textView: NSTextView, characterIndex: Int) {
    let range = NSRange(location: characterIndex, length: 1)
    if let layoutManager = textView.layoutManager {
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: range)
        if let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
    }
    if let textLayoutManager = textView.textLayoutManager {
        let documentStart = textLayoutManager.documentRange.location
        if let location = textLayoutManager.location(documentStart, offsetBy: characterIndex),
           let end = textLayoutManager.location(location, offsetBy: 1),
           let textRange = NSTextRange(location: location, end: end) {
            textLayoutManager.invalidateLayout(for: textRange)
            textLayoutManager.ensureLayout(for: textRange)
        } else {
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }
    }
    textView.needsLayout = true
    textView.needsDisplay = true
    textView.layoutSubtreeIfNeeded()
}
#endif

#if os(iOS)
func wiskGlyphRect(in textView: UITextView, characterIndex: Int) -> CGRect? {
    guard characterIndex >= 0, textView.textStorage.length > characterIndex else { return nil }
    let storage = textView.textStorage
    let attachmentSize = wiskAttachmentPresentationSize(in: storage, at: characterIndex)
    let characterRange = NSRange(location: characterIndex, length: 1)
    var fragment = CGRect.null

    if let textLayoutManager = textView.textLayoutManager {
        let documentStart = textLayoutManager.documentRange.location
        if let location = textLayoutManager.location(documentStart, offsetBy: characterIndex) {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            textLayoutManager.enumerateTextSegments(
                in: NSTextRange(location: location),
                type: .standard,
                options: [.rangeNotRequired]
            ) { _, frame, _, _ in
                fragment = frame
                return false
            }
        }
    }

    if fragment.isNull || fragment.width < 1 {
        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        fragment = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        fragment.origin.x += textView.textContainerInset.left
        fragment.origin.y += textView.textContainerInset.top
    } else {
        fragment.origin.x += textView.textContainerInset.left
        fragment.origin.y += textView.textContainerInset.top
    }

    guard fragment.isNull == false, fragment.width > 1 else { return nil }
    if let attachmentSize {
        return WiskAttachmentImageResize.presentationRect(
            fragmentRect: fragment,
            attachmentSize: attachmentSize
        )
    }
    return fragment
}

func wiskInvalidateAttachmentLayout(_ textView: UITextView, characterIndex: Int) {
    let range = NSRange(location: characterIndex, length: 1)
    textView.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    textView.layoutManager.invalidateDisplay(forCharacterRange: range)
    textView.setNeedsLayout()
    textView.layoutIfNeeded()
}
#endif

#endif
