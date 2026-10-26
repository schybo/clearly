import Foundation

/// Runtime gates for in-development features.
///
/// Plaud import is an internal prototype: it stays behind `#if DEBUG` at compile
/// time AND behind this user-defaults toggle at runtime. Release production builds
/// (App Store `Wisk` on iOS, `WiskMac`) never show Plaud UI — the Settings toggle
/// itself only exists in `#if DEBUG`, so there is no path to enable it in production.
enum WiskBetaFeatures {
    static let plaudEnabledKey = "wisk.beta.plaudEnabled"

    static func isPlaudEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: plaudEnabledKey)
    }
}
