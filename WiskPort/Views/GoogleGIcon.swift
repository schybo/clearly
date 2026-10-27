import SwiftUI

/// Hand-drawn Google "G" mark (official four-color geometry in a 48pt box).
///
/// Replaces the decorative `GoogleSignInButton` from GoogleSignInSwift, which
/// crashed at render time (SIGSEGV in `GoogleSignInButton.body.getter`, crash
/// report WiskNext Dev-2026-10-26-064502.ips). Pure SwiftUI — no package
/// resources involved. The functional sign-in path (`GIDSignIn` in
/// `WiskAuthService`) is unaffected and keeps the GoogleSignIn package.
struct GoogleGIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 48
            let center = CGPoint(x: 24 * s, y: 24 * s)
            ZStack {
                // Blue: right arc + horizontal bar (0° = 3 o'clock, sweeping down).
                GoogleGArcSector(center: center, outerRadius: 24 * s, innerRadius: 14.5 * s,
                                 startDegrees: 0, endDegrees: 50,
                                 color: GoogleGIcon.blue)
                Path { path in
                    path.addRect(CGRect(x: 24 * s, y: 19.75 * s,
                                        width: 23 * s, height: 9.5 * s))
                }
                .fill(GoogleGIcon.blue)
                // Green: bottom sweep.
                GoogleGArcSector(center: center, outerRadius: 24 * s, innerRadius: 14.5 * s,
                                 startDegrees: 50, endDegrees: 155,
                                 color: GoogleGIcon.green)
                // Yellow: left side.
                GoogleGArcSector(center: center, outerRadius: 24 * s, innerRadius: 14.5 * s,
                                 startDegrees: 155, endDegrees: 207,
                                 color: GoogleGIcon.yellow)
                // Red: over the top; the gap between red's end and the blue bar
                // is the G's opening on the right.
                GoogleGArcSector(center: center, outerRadius: 24 * s, innerRadius: 14.5 * s,
                                 startDegrees: 207, endDegrees: 312,
                                 color: GoogleGIcon.red)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    static let blue = Color(red: 0.259, green: 0.522, blue: 0.957)
    static let green = Color(red: 0.204, green: 0.659, blue: 0.325)
    static let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)
    static let red = Color(red: 0.918, green: 0.263, blue: 0.208)
}

/// One annular sector of the Google G. Angles use SwiftUI's screen convention:
/// 0° points right, positive degrees sweep downward (clockwise on screen).
private struct GoogleGArcSector: View {
    let center: CGPoint
    let outerRadius: CGFloat
    let innerRadius: CGFloat
    let startDegrees: Double
    let endDegrees: Double
    let color: Color

    var body: some View {
        Path { path in
            path.addArc(center: center, radius: outerRadius,
                        startAngle: .degrees(startDegrees), endAngle: .degrees(endDegrees),
                        clockwise: false)
            path.addLine(to: point(on: innerRadius, at: endDegrees))
            path.addArc(center: center, radius: innerRadius,
                        startAngle: .degrees(endDegrees), endAngle: .degrees(startDegrees),
                        clockwise: true)
            path.closeSubpath()
        }
        .fill(color)
    }

    private func point(on radius: CGFloat, at degrees: Double) -> CGPoint {
        let radians = degrees * Double.pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }
}
