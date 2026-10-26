import CoreText
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class WiskFontManager {
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let googleClient: WiskGoogleFontClient

    private(set) var selection: WiskEditorFontSelection
    private(set) var availableLocalFonts: [WiskEditorFontSelection] = []
    private(set) var isWorking = false
    private(set) var statusMessage: String?

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        googleClient: WiskGoogleFontClient = WiskGoogleFontClient()
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.googleClient = googleClient
        self.selection = Self.loadSelection(userDefaults: userDefaults)
    }

    func configure() {
        try? fileManager.createDirectory(at: localFontsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: googleFontsDirectory, withIntermediateDirectories: true)
        refreshLocalFonts()
        registerCachedSelectionIfNeeded()
    }

    func selectBuiltIn(_ fontFamily: WiskEditorFontFamily) {
        setSelection(WiskEditorFontSelection(builtIn: fontFamily))
    }

    func selectLocalFont(_ selection: WiskEditorFontSelection) {
        setSelection(selection)
    }

    func importLocalFont(from sourceURL: URL) async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let selection = try copyAndRegisterFont(from: sourceURL, directory: localFontsDirectory, source: .local)
            refreshLocalFonts()
            setSelection(selection)
            statusMessage = "Imported \(selection.displayName)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installGoogleFont(_ googleFont: WiskGoogleFont) async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }

        do {
            let downloadedURL = try await googleClient.downloadFont(for: googleFont, to: googleFontsDirectory)
            let selection = try registerGoogleFont(googleFont, fileURL: downloadedURL)
            setSelection(selection)
            statusMessage = "Installed \(selection.displayName) from Google Fonts."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applySyncedGoogleFontIfAppropriate(_ googleFont: WiskGoogleFont?) async {
        guard let googleFont, selection.source != .local else { return }
        guard selection.googleFamily != googleFont.family || selection.googleVariant != googleFont.variant else { return }
        await installGoogleFont(googleFont)
    }

    func removeCustomFontSelection() {
        setSelection(.system)
        statusMessage = "Using System font."
    }

    func resolvedFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        selection.font(size: size, weight: weight)
    }

    private static func loadSelection(userDefaults: UserDefaults) -> WiskEditorFontSelection {
        if let selection = WiskEditorFontSelection.decoded(from: userDefaults.string(forKey: WiskEditorDefaults.fontSelectionKey)) {
            return selection
        }

        let legacyRawValue = userDefaults.string(forKey: WiskEditorDefaults.fontFamilyKey)
        let legacyFont = legacyRawValue.flatMap(WiskEditorFontFamily.init(rawValue:)) ?? .system
        return WiskEditorFontSelection(builtIn: legacyFont)
    }

    private func setSelection(_ selection: WiskEditorFontSelection) {
        self.selection = selection
        userDefaults.set(selection.encodedString(), forKey: WiskEditorDefaults.fontSelectionKey)
        if selection.source == .builtIn {
            userDefaults.set(selection.builtInFont.rawValue, forKey: WiskEditorDefaults.fontFamilyKey)
        }
    }

    private func registerCachedSelectionIfNeeded() {
        switch selection.source {
        case .builtIn:
            break
        case .local:
            guard let fileName = selection.localFileName else { return }
            let fileURL = localFontsDirectory.appendingPathComponent(fileName)
            do {
                try registerFont(at: fileURL)
            } catch {
                statusMessage = "Wisk could not load \(selection.displayName). Using System until it is restored."
            }
        case .google:
            guard let fileName = selection.localFileName else { return }
            let fileURL = googleFontsDirectory.appendingPathComponent(fileName)
            do {
                try registerFont(at: fileURL)
            } catch {
                statusMessage = "Wisk could not load \(selection.displayName). It will redownload from Google Fonts when selected again."
            }
        }
    }

    private func refreshLocalFonts() {
        let files = (try? fileManager.contentsOfDirectory(at: localFontsDirectory, includingPropertiesForKeys: nil)) ?? []
        availableLocalFonts = files.compactMap { url in
            guard let info = try? fontInfo(at: url) else { return nil }
            return WiskEditorFontSelection(localDisplayName: info.displayName, postScriptName: info.postScriptName, fileName: url.lastPathComponent)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func copyAndRegisterFont(from sourceURL: URL, directory: URL, source: WiskEditorFontSource) throws -> WiskEditorFontSelection {
        let ext = sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension
        let safeName = sourceURL.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = "\(UUID().uuidString)-\(safeName.isEmpty ? "font" : safeName).\(ext)"
        let destinationURL = directory.appendingPathComponent(fileName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try registerFont(at: destinationURL)
        let info = try fontInfo(at: destinationURL)

        switch source {
        case .local:
            return WiskEditorFontSelection(localDisplayName: info.displayName, postScriptName: info.postScriptName, fileName: fileName)
        case .google, .builtIn:
            return WiskEditorFontSelection(localDisplayName: info.displayName, postScriptName: info.postScriptName, fileName: fileName)
        }
    }

    private func registerGoogleFont(_ googleFont: WiskGoogleFont, fileURL: URL) throws -> WiskEditorFontSelection {
        try registerFont(at: fileURL)
        let info = try fontInfo(at: fileURL)
        return WiskEditorFontSelection(googleFont: googleFont, postScriptName: info.postScriptName, fileName: fileURL.lastPathComponent)
    }

    private func registerFont(at url: URL) throws {
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            if let error = error?.takeRetainedValue(), !Self.isAlreadyRegistered(error) {
                throw error
            }
        }
    }

    private func fontInfo(at url: URL) throws -> FontInfo {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            throw WiskFontError.unsupportedFont
        }

        let postScriptName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let postScriptName, !postScriptName.isEmpty else {
            throw WiskFontError.unsupportedFont
        }

        return FontInfo(displayName: displayName?.isEmpty == false ? displayName! : postScriptName, postScriptName: postScriptName)
    }

    private var appSupportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Wisk", isDirectory: true)
    }

    private var localFontsDirectory: URL {
        appSupportDirectory.appendingPathComponent("EditorFonts/Local", isDirectory: true)
    }

    private var googleFontsDirectory: URL {
        appSupportDirectory.appendingPathComponent("EditorFonts/Google", isDirectory: true)
    }

    private static func isAlreadyRegistered(_ error: CFError) -> Bool {
        CFErrorGetDomain(error) as String == kCTFontManagerErrorDomain as String
            && CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
    }
}

private struct FontInfo {
    let displayName: String
    let postScriptName: String
}

private enum WiskFontError: LocalizedError {
    case unsupportedFont
    case missingGoogleFontURL

    var errorDescription: String? {
        switch self {
        case .unsupportedFont:
            return "Wisk could not read that font. Try a TTF, OTF, TTC, WOFF, or WOFF2 file."
        case .missingGoogleFontURL:
            return "Wisk could not find a downloadable font file from Google Fonts."
        }
    }
}
