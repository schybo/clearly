import CoreGraphics
import Foundation

enum WiskAttachmentImageResize {
    enum Handle: String, Sendable {
        case left
        case right
        case bottomRight
    }

    enum ChromeKind: String, Sendable {
        case sidePills
        case bottomRightCorner
    }

    static let snapToFitThreshold: CGFloat = 8
    static let handleVisualSize: CGFloat = 8
    static let handleHitSize: CGFloat = 16
    static let macCornerVisualSize: CGFloat = 10
    static let macCornerHitSize: CGFloat = 20

    static func clampedWidth(_ proposed: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let minimum = WiskAttachmentImageLayout.minimumWidth
        let available = max(availableWidth, minimum)
        return min(max(proposed, minimum), available)
    }

    static func widthAfterDrag(
        startWidth: CGFloat,
        deltaX: CGFloat,
        handle: Handle,
        availableWidth: CGFloat
    ) -> CGFloat {
        let proposed: CGFloat
        switch handle {
        case .right, .bottomRight:
            proposed = startWidth + deltaX
        case .left:
            proposed = startWidth - deltaX
        }
        return clampedWidth(proposed, availableWidth: availableWidth)
    }

    /// Width that keeps the dragged edge under `currentX`, using the opposite edge captured at drag start.
    static func widthByFollowingPointer(
        anchorX: CGFloat,
        currentX: CGFloat,
        handle: Handle,
        availableWidth: CGFloat
    ) -> CGFloat {
        let proposed: CGFloat
        switch handle {
        case .right, .bottomRight:
            proposed = currentX - anchorX
        case .left:
            proposed = anchorX - currentX
        }
        return clampedWidth(proposed, availableWidth: availableWidth)
    }

    static func persistedDisplayWidth(
        currentWidth: CGFloat,
        availableWidth: CGFloat,
        snapThreshold: CGFloat = snapToFitThreshold
    ) -> Double? {
        let available = max(availableWidth, WiskAttachmentImageLayout.minimumWidth)
        let clamped = clampedWidth(currentWidth, availableWidth: available)
        if abs(clamped - available) <= snapThreshold {
            return nil
        }
        return Double(clamped)
    }

    static func handleRect(
        for handle: Handle,
        in imageRect: CGRect,
        size: CGFloat = handleHitSize
    ) -> CGRect {
        let center: CGPoint
        switch handle {
        case .left:
            center = CGPoint(x: imageRect.minX, y: imageRect.midY)
        case .right:
            center = CGPoint(x: imageRect.maxX, y: imageRect.midY)
        case .bottomRight:
            center = CGPoint(x: imageRect.maxX, y: imageRect.maxY)
        }
        return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    static func visualHandleRect(
        for handle: Handle,
        in imageRect: CGRect,
        size: CGFloat = handleVisualSize
    ) -> CGRect {
        handleRect(for: handle, in: imageRect, size: size)
    }

    static func handle(
        at point: CGPoint,
        in imageRect: CGRect,
        hitSize: CGFloat = handleHitSize,
        kind: ChromeKind = .sidePills
    ) -> Handle? {
        let handles: [Handle]
        switch kind {
        case .sidePills:
            handles = [.left, .right]
        case .bottomRightCorner:
            handles = [.bottomRight]
        }
        for handle in handles {
            if handleRect(for: handle, in: imageRect, size: hitSize).contains(point) {
                return handle
            }
        }
        return nil
    }

    static func dragAnchorX(for handle: Handle, in imageRect: CGRect) -> CGFloat {
        switch handle {
        case .left:
            imageRect.maxX
        case .right, .bottomRight:
            imageRect.minX
        }
    }

    static func chromeFrame(
        for imageRect: CGRect,
        hitSize: CGFloat = handleHitSize
    ) -> CGRect {
        imageRect.insetBy(dx: -hitSize / 2, dy: -hitSize / 2)
    }

    /// Expands a layout fragment to the drawn attachment size.
    /// Tall images sit on the fragment baseline (`maxY`) in flipped text views, which is why
    /// a screen-clipped `firstRect` only covers the bottom of a photo.
    static func presentationRect(fragmentRect: CGRect, attachmentSize: CGSize) -> CGRect {
        guard attachmentSize.width > 1, attachmentSize.height > 1, fragmentRect.width > 0 else {
            return fragmentRect
        }

        var rect = fragmentRect
        if abs(attachmentSize.width - fragmentRect.width) > 0.5 {
            rect.origin.x = fragmentRect.midX - attachmentSize.width / 2
            rect.size.width = attachmentSize.width
        }
        if attachmentSize.height > fragmentRect.height + 0.5 {
            rect.origin.y = fragmentRect.maxY - attachmentSize.height
            rect.size.height = attachmentSize.height
        } else {
            rect.size.height = max(fragmentRect.height, attachmentSize.height)
        }
        return rect
    }
}
