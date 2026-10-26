import SwiftUI

#if os(iOS) || os(macOS)
struct WiskImageCropSheet: View {
    let imageData: Data
    var onCrop: (CGRect) -> Void
    var onCancel: () -> Void

    @State private var normalizedRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Drag the rectangle to choose the visible area.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WiskImageCropCanvas(imageData: imageData, normalizedRect: $normalizedRect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button("Reset") {
                        normalizedRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                    }
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button("Crop") {
                        onCrop(normalizedRect)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .accessibilityIdentifier("wisk.imageCrop.sheet")
            #if os(iOS)
            .navigationTitle("Crop Image")
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

private struct WiskImageCropCanvas: View {
    let imageData: Data
    @Binding var normalizedRect: CGRect

    var body: some View {
        GeometryReader { geometry in
            let imageSize = displaySize(in: geometry.size)
            let origin = CGPoint(
                x: (geometry.size.width - imageSize.width) / 2,
                y: (geometry.size.height - imageSize.height) / 2
            )
            ZStack {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .position(
                            x: origin.x + imageSize.width / 2,
                            y: origin.y + imageSize.height / 2
                        )
                }

                cropOverlay(imageOrigin: origin, imageSize: imageSize)
            }
            .contentShape(Rectangle())
            .gesture(drag(imageOrigin: origin, imageSize: imageSize))
        }
        .background(.black.opacity(0.35))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image crop canvas")
        .accessibilityValue("Crop width \(Int(normalizedRect.width * 100)) percent")
    }

    private var image: Image? {
        #if os(iOS)
        guard let uiImage = UIImage(data: imageData) else { return nil }
        return Image(uiImage: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(data: imageData) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }

    private func displaySize(in bounds: CGSize) -> CGSize {
        #if os(iOS)
        guard let uiImage = UIImage(data: imageData) else { return bounds }
        let imageSize = uiImage.size
        #elseif os(macOS)
        guard let nsImage = NSImage(data: imageData) else { return bounds }
        let imageSize = nsImage.size
        #else
        let imageSize = bounds
        #endif
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func cropOverlay(imageOrigin: CGPoint, imageSize: CGSize) -> some View {
        let rect = CGRect(
            x: imageOrigin.x + normalizedRect.minX * imageSize.width,
            y: imageOrigin.y + normalizedRect.minY * imageSize.height,
            width: normalizedRect.width * imageSize.width,
            height: normalizedRect.height * imageSize.height
        )
        return ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
            RoundedRectangle(cornerRadius: 2)
                .fill(.clear)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .blendMode(.destinationOut)
            RoundedRectangle(cornerRadius: 2)
                .stroke(.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .compositingGroup()
    }

    private func drag(imageOrigin: CGPoint, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard imageSize.width > 0, imageSize.height > 0 else { return }
                let x = min(max((value.location.x - imageOrigin.x) / imageSize.width, 0), 1)
                let y = min(max((value.location.y - imageOrigin.y) / imageSize.height, 0), 1)
                let startX = min(max((value.startLocation.x - imageOrigin.x) / imageSize.width, 0), 1)
                let startY = min(max((value.startLocation.y - imageOrigin.y) / imageSize.height, 0), 1)
                let originX = min(startX, x)
                let originY = min(startY, y)
                normalizedRect = CGRect(
                    x: originX,
                    y: originY,
                    width: max(abs(x - startX), 0.08),
                    height: max(abs(y - startY), 0.08)
                )
            }
    }
}
#endif
