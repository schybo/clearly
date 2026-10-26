import SwiftUI

enum AppConstants {
    static let appStoreID = "0000000000"
}

extension Color {
    static let accent = Color(red: 0.32, green: 0.48, blue: 0.88)
    static let accentGlow = Color(red: 0.32, green: 0.48, blue: 0.88).opacity(0.12)
    static let warmAction = Color(red: 1.0, green: 0.70, blue: 0.36)
    static let learningMint = Color(red: 0.24, green: 0.62, blue: 0.52)
    static let cardBackground = Color(light: Color(red: 0.98, green: 0.98, blue: 0.97), dark: Color(red: 0.12, green: 0.12, blue: 0.13))
    static let surfaceElevated = Color(light: .white, dark: Color(red: 0.17, green: 0.17, blue: 0.18))
    static let cardBorder = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.10))
    static let sheetBackground = Color(light: Color(red: 0.95, green: 0.95, blue: 0.94), dark: Color(red: 0.08, green: 0.08, blue: 0.09))
    static let wiskPrimaryText = Color(light: Color(red: 0.12, green: 0.12, blue: 0.13), dark: .white)
    static let wiskSecondaryText = Color(light: Color.black.opacity(0.58), dark: Color.white.opacity(0.62))
    static let wiskTertiaryText = Color(light: Color.black.opacity(0.42), dark: Color.white.opacity(0.46))
    static let wiskInputBackground = Color(light: .white, dark: Color.white.opacity(0.08))
    static let wiskGroupedBackground = Color(light: Color(red: 0.93, green: 0.93, blue: 0.92), dark: Color(red: 0.09, green: 0.09, blue: 0.10))
    static let macEditorBackground = Color(light: Color(red: 0.992, green: 0.99, blue: 0.985), dark: Color(red: 0.12, green: 0.12, blue: 0.13))
    static var wiskCanvasBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }
}

private extension Color {
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

extension ShapeStyle where Self == Color {
    static var accent: Color { .init(red: 0.32, green: 0.48, blue: 0.88) }
    static var cardBackground: Color { Color.cardBackground }
    static var surfaceElevated: Color { Color.surfaceElevated }
}

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 18
    static let button: CGFloat = 14
    static let glassOverlay: CGFloat = 12
}

enum AppFont {
    static let hero = Font.system(size: 34, weight: .semibold, design: .rounded)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let cardLabel = Font.caption.weight(.medium)
    static let buttonLabel = Font.system(size: 17, weight: .semibold)
}

enum AppSpring {
    struct Values {
        let response: Double
        let damping: Double
    }

    static let buttonPress = Values(response: 0.25, damping: 0.28)
    static let navTransition = Values(response: 0.4, damping: 0.7)
    static let viewTransition = Values(response: 0.5, damping: 0.8)
}

enum AppMotion {
    static let macQuick = Animation.easeOut(duration: 0.16)
    static let macSmooth = Animation.easeInOut(duration: 0.22)
    static let macSpring = Animation.spring(response: 0.28, dampingFraction: 0.86)

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    @MainActor
    static func perform(
        reduceMotion: Bool,
        animation: Animation = macSpring,
        _ updates: () -> Void
    ) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(animation, updates)
        }
    }
}

struct CardStyle: ViewModifier {
    var cornerRadius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.cardBackground)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.cardBorder, lineWidth: 0.6)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = Radius.card) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius))
    }
}

struct GlowBackground: ViewModifier {
    var color: Color = .accent
    var radius: CGFloat = 120

    func body(content: Content) -> some View {
        content
            .background(
                RadialGradient(
                    colors: [color.opacity(0.20), color.opacity(0.05), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
                .blur(radius: 24)
            )
    }
}

extension View {
    func glowBackground(color: Color = .accent, radius: CGFloat = 120) -> some View {
        modifier(GlowBackground(color: color, radius: radius))
    }

    @ViewBuilder
    func wiskRoundedButtonBorder() -> some View {
        #if os(iOS)
        self.buttonBorderShape(.roundedRectangle(radius: Radius.button))
        #else
        self
        #endif
    }
}

private struct NavInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var navInset: CGFloat {
        get { self[NavInsetKey.self] }
        set { self[NavInsetKey.self] = newValue }
    }
}

struct ReadableWidth: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    private let maxWidth: CGFloat = 720

    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
        #else
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        #endif
    }
}

extension View {
    func readableWidth() -> some View {
        modifier(ReadableWidth())
    }
}

struct WiskChromeCanvas {
    static func fillOpacity(allowsBleed _: Bool, reduceTransparency _: Bool) -> Double {
        1
    }
}

struct WiskGlassEffect<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var glass: Glass
    var shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.wiskCanvasBackground, in: shape)
                .overlay {
                    shape
                        .strokeBorder(Color.cardBorder, lineWidth: 0.6)
                        .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

struct WiskSplitColumnCanvas: ViewModifier {
    var paper: Color

    func body(content: Content) -> some View {
        content.background(paper)
    }
}

extension View {
    func wiskGlassEffect<S: InsettableShape>(
        _ glass: Glass = .regular,
        in shape: S
    ) -> some View {
        modifier(WiskGlassEffect(glass: glass, shape: shape))
    }

    func wiskNoteListCanvas() -> some View {
        modifier(WiskSplitColumnCanvas(paper: .wiskCanvasBackground))
    }

    func wiskEditorCanvas() -> some View {
        #if os(iOS)
        modifier(WiskSplitColumnCanvas(paper: Color(uiColor: .systemBackground)))
        #else
        modifier(WiskSplitColumnCanvas(paper: .macEditorBackground))
        #endif
    }
}

struct LiquidBackground: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var scale: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .regular ? 1.45 : 1
        #else
        1.45
        #endif
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.sheetBackground,
                    Color.wiskGroupedBackground,
                    Color.sheetBackground,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.accent.opacity(0.10))
                .frame(width: 260 * scale, height: 260 * scale)
                .blur(radius: 62)
                .offset(x: -130 * scale, y: -240 * scale)
            Circle()
                .fill(Color.learningMint.opacity(0.08))
                .frame(width: 220 * scale, height: 220 * scale)
                .blur(radius: 70)
                .offset(x: 130 * scale, y: 90 * scale)
            Circle()
                .fill(Color.warmAction.opacity(0.08))
                .frame(width: 190 * scale, height: 190 * scale)
                .blur(radius: 60)
                .offset(x: -80 * scale, y: 280 * scale)
        }
        .ignoresSafeArea()
    }
}
