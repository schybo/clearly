import Foundation

/// Pure, cross-platform conversion utilities for moving Wisk note data across
/// process and persistence boundaries. Callers are responsible for creating
/// these value snapshots from their models and persisting imported results.
enum WiskNoteInterchange {
    static let maxMarkdownImportByteSize = 10 * 1024 * 1024
    static let maxTextBundleFileCount = 1_000
    static let maxTextBundleByteSize = 100 * 1024 * 1024
    static let maxTextBundleResourceByteSize = 50 * 1024 * 1024

    struct NoteSnapshot: Equatable, Sendable {
        let title: String
        let body: String
        let attachments: [AttachmentSnapshot]

        init(title: String, body: String, attachments: [AttachmentSnapshot] = []) {
            self.title = title
            self.body = body
            self.attachments = attachments
        }
    }

    struct AttachmentSnapshot: Equatable, Sendable {
        let id: UUID
        let fileName: String
        let contentType: String
        let data: Data
        let altText: String

        init(
            id: UUID,
            fileName: String,
            contentType: String,
            data: Data,
            altText: String = ""
        ) {
            self.id = id
            self.fileName = fileName
            self.contentType = contentType
            self.data = data
            self.altText = altText
        }
    }

    struct FileRepresentation: Equatable, Sendable {
        let relativePath: String
        let contentType: String
        let data: Data

        init(relativePath: String, contentType: String, data: Data) {
            self.relativePath = relativePath
            self.contentType = contentType
            self.data = data
        }
    }

    struct TextBundleRepresentation: Equatable, Sendable {
        /// A deterministic, filesystem-safe package name ending in `.textbundle`.
        let packageName: String
        /// Includes `info.json`, `text.md`, and zero or more files under `assets/`.
        let files: [FileRepresentation]
    }

    struct ImportedAttachmentDescriptor: Equatable, Sendable {
        let id: UUID
        let fileName: String
        let contentType: String
        let data: Data
        /// The normalized relative path used by the imported document.
        let sourcePath: String
    }

    struct ImportResult: Equatable, Sendable {
        let body: String
        let attachments: [ImportedAttachmentDescriptor]
    }

    struct PrintablePayload: Equatable, Sendable {
        /// A complete, sanitized HTML document suitable for a web/print renderer.
        let html: String
        /// RTF generated through Foundation's attributed-string importer when that
        /// facility is present on the current Apple platform.
        let rtfData: Data?
    }

    struct ExportedDocument: Equatable, Sendable {
        let fileName: String
        let contentType: String
        let data: Data
    }

    enum InterchangeError: LocalizedError, Equatable, Sendable {
        case invalidUTF8
        case missingTextBundleMarkdown
        case invalidTextBundlePath(String)
        case fileTooLarge(String)
        case textBundleTooLarge
        case tooManyTextBundleFiles

        var errorDescription: String? {
            switch self {
            case .invalidUTF8:
                return "The document is not valid UTF-8 text."
            case .missingTextBundleMarkdown:
                return "The TextBundle does not contain text.md or text.markdown."
            case let .invalidTextBundlePath(path):
                return "The TextBundle contains an unsafe path: \(path)"
            case let .fileTooLarge(path):
                return "The imported file is too large: \(path)"
            case .textBundleTooLarge:
                return "The TextBundle is larger than Wisk's 100 MB import limit."
            case .tooManyTextBundleFiles:
                return "The TextBundle contains more than \(maxTextBundleFileCount) files."
            }
        }
    }

    static func importDocument(at url: URL, fileManager: FileManager = .default) throws -> ImportResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if url.pathExtension.lowercased() == "textbundle" || url.hasDirectoryPath {
            var files: [FileRepresentation] = []
            var totalBytes = 0
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw InterchangeError.missingTextBundleMarkdown
            }

            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard files.count < maxTextBundleFileCount else {
                    throw InterchangeError.tooManyTextBundleFiles
                }

                let relativePath = String(fileURL.path.dropFirst(url.path.count + 1))
                let normalizedPath = normalizedRelativePath(relativePath) ?? relativePath
                let fileSize = values.fileSize ?? 0
                let perFileLimit = ["text.md", "text.markdown"].contains(normalizedPath.lowercased())
                    ? maxMarkdownImportByteSize
                    : maxTextBundleResourceByteSize
                guard fileSize <= perFileLimit else {
                    throw InterchangeError.fileTooLarge(relativePath)
                }
                totalBytes += fileSize
                guard totalBytes <= maxTextBundleByteSize else {
                    throw InterchangeError.textBundleTooLarge
                }

                let type = contentType(for: fileURL)
                files.append(.init(
                    relativePath: relativePath,
                    contentType: type,
                    data: try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                ))
            }

            return try importTextBundle(.init(packageName: url.lastPathComponent, files: files))
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maxMarkdownImportByteSize else {
            throw InterchangeError.fileTooLarge(url.lastPathComponent)
        }
        return try importMarkdown(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    static func exportPlainText(_ note: NoteSnapshot) -> ExportedDocument {
        let portable = portableMarkdown(note).markdown
        let text = plainText(from: portable)
        return ExportedDocument(
            fileName: "\(documentBaseName(note.title)).txt",
            contentType: "text/plain",
            data: Data(text.utf8)
        )
    }

    static func exportMarkdown(_ note: NoteSnapshot) -> ExportedDocument {
        let markdown = portableMarkdown(note).markdown
        return ExportedDocument(
            fileName: "\(documentBaseName(note.title)).md",
            contentType: "text/markdown",
            data: Data(markdown.utf8)
        )
    }

    static func exportHTML(_ note: NoteSnapshot) -> ExportedDocument {
        let markdown = portableMarkdown(note).markdown
        let html = htmlDocument(title: note.title, markdown: markdown)
        return ExportedDocument(
            fileName: "\(documentBaseName(note.title)).html",
            contentType: "text/html",
            data: Data(html.utf8)
        )
    }

    static func exportRTF(_ note: NoteSnapshot) -> ExportedDocument? {
        let payload = printablePayload(note)
        guard let data = payload.rtfData else { return nil }
        return ExportedDocument(
            fileName: "\(documentBaseName(note.title)).rtf",
            contentType: "application/rtf",
            data: data
        )
    }

    static func printablePayload(_ note: NoteSnapshot) -> PrintablePayload {
        let html = htmlDocument(title: note.title, markdown: portableMarkdown(note).markdown)
        return PrintablePayload(html: html, rtfData: foundationRTF(fromHTML: html))
    }

    static func exportTextBundle(_ note: NoteSnapshot) -> TextBundleRepresentation {
        let portable = portableMarkdown(note)
        let info: [String: Any] = [
            "version": 2,
            "type": "net.daringfireball.markdown",
            "creatorIdentifier": "com.schybo.wisk",
        ]
        let infoData = (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"creatorIdentifier\":\"com.schybo.wisk\",\"type\":\"net.daringfireball.markdown\",\"version\":2}".utf8)

        var files = [
            FileRepresentation(relativePath: "info.json", contentType: "application/json", data: infoData),
            FileRepresentation(relativePath: "text.md", contentType: "text/markdown", data: Data(portable.markdown.utf8)),
        ]
        files.append(contentsOf: portable.assets.map {
            FileRepresentation(
                relativePath: "assets/\($0.fileName)",
                contentType: $0.attachment.contentType,
                data: $0.attachment.data
            )
        })

        return TextBundleRepresentation(
            packageName: "\(documentBaseName(note.title)).textbundle",
            files: files
        )
    }

    /// Imports Markdown and converts relative references matching supplied
    /// resources into Wisk's stable `wisk-attachment://<UUID>` references.
    /// Remote and unsafe URLs are never fetched.
    static func importMarkdown(
        _ markdown: String,
        resources: [FileRepresentation] = []
    ) throws -> ImportResult {
        let safeResources = try resourceLookup(resources)
        return resolveImportedAttachments(in: markdown, resources: safeResources)
    }

    static func importMarkdown(
        data: Data,
        resources: [FileRepresentation] = []
    ) throws -> ImportResult {
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw InterchangeError.invalidUTF8
        }
        return try importMarkdown(markdown, resources: resources)
    }

    static func importTextBundle(_ bundle: TextBundleRepresentation) throws -> ImportResult {
        let lookup = try resourceLookup(bundle.files)
        let markdownFile = lookup["text.md"] ?? lookup["text.markdown"]
        guard let markdownFile else {
            throw InterchangeError.missingTextBundleMarkdown
        }
        guard let markdown = String(data: markdownFile.data, encoding: .utf8) else {
            throw InterchangeError.invalidUTF8
        }
        return resolveImportedAttachments(in: markdown, resources: lookup)
    }
}

private extension WiskNoteInterchange {
    struct NamedAsset {
        let attachment: AttachmentSnapshot
        let fileName: String
    }

    struct PortableMarkdown {
        let markdown: String
        let assets: [NamedAsset]
    }

    static let attachmentPattern = #"(!?)\[([^\]]*)\]\(wisk-attachment://([0-9A-Fa-f-]{36})\)"#
    static let markdownLinkPattern = #"(!?)\[([^\]]*)\]\(([^)\s]+)(?:\s+["'][^)]*["'])?\)"#

    static func portableMarkdown(_ note: NoteSnapshot) -> PortableMarkdown {
        let assets = deterministicAssets(note.attachments)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.attachment.id, $0) })
        let expression = try? NSRegularExpression(pattern: attachmentPattern)
        let source = note.body as NSString
        let matches = expression?.matches(
            in: note.body,
            range: NSRange(location: 0, length: source.length)
        ) ?? []
        let output = NSMutableString(string: note.body)

        for match in matches.reversed() {
            guard
                let idRange = Range(match.range(at: 3), in: note.body),
                let id = UUID(uuidString: String(note.body[idRange])),
                let asset = byID[id]
            else {
                let title = substring(note.body, range: match.range(at: 2))
                output.replaceCharacters(in: match.range, with: escapedMarkdownLabel(title))
                continue
            }

            let marker = match.range(at: 1).length == 1 ? "!" : ""
            let title = substring(note.body, range: match.range(at: 2))
            let label = escapedMarkdownLabel(title.isEmpty ? asset.attachment.altText : title)
            output.replaceCharacters(
                in: match.range,
                with: "\(marker)[\(label)](assets/\(asset.fileName))"
            )
        }
        return PortableMarkdown(
            markdown: sanitizedMarkdownReferences(output as String),
            assets: assets
        )
    }

    static func deterministicAssets(_ attachments: [AttachmentSnapshot]) -> [NamedAsset] {
        var used = Set<String>()
        var result: [UUID: String] = [:]
        var seenIDs: Set<UUID> = []
        let uniqueAttachments = attachments.filter { seenIDs.insert($0.id).inserted }

        for attachment in uniqueAttachments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let proposed = safeAttachmentFileName(
                attachment.fileName,
                contentType: attachment.contentType,
                id: attachment.id
            )
            let extensionPart = (proposed as NSString).pathExtension
            let stem = (proposed as NSString).deletingPathExtension
            var candidate = proposed
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = extensionPart.isEmpty
                    ? "\(stem)-\(suffix)"
                    : "\(stem)-\(suffix).\(extensionPart)"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            result[attachment.id] = candidate
        }

        return uniqueAttachments.compactMap { attachment in
            result[attachment.id].map { NamedAsset(attachment: attachment, fileName: $0) }
        }
    }

    static func documentBaseName(_ title: String) -> String {
        let value = sanitizedStem(title)
        return value.isEmpty ? "Untitled Note" : value
    }

    static func safeAttachmentFileName(_ fileName: String, contentType: String, id: UUID) -> String {
        let lastComponent = (fileName as NSString).lastPathComponent
        var stem = sanitizedStem((lastComponent as NSString).deletingPathExtension)
        if stem.isEmpty {
            stem = "attachment-\(id.uuidString.lowercased())"
        }
        let suppliedExtension = sanitizedExtension((lastComponent as NSString).pathExtension)
        let fileExtension = suppliedExtension.isEmpty ? preferredExtension(contentType) : suppliedExtension
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    static func sanitizedStem(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(String(scalar))
            }
            return " "
        }
        let parts = String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return String(parts.joined(separator: "-").prefix(80))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
    }

    static func sanitizedExtension(_ value: String) -> String {
        String(value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12))
    }

    static func preferredExtension(_ contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/heic", "image/heif": "heic"
        case "image/webp": "webp"
        case "application/pdf": "pdf"
        case "text/plain": "txt"
        case "text/markdown": "md"
        case "application/json": "json"
        default: "bin"
        }
    }

    static func plainText(from markdown: String) -> String {
        let mutable = NSMutableString(string: markdown)
        if let links = try? NSRegularExpression(pattern: markdownLinkPattern) {
            let source = markdown as NSString
            for match in links.matches(in: markdown, range: NSRange(location: 0, length: source.length)).reversed() {
                let label = source.substring(with: match.range(at: 2))
                mutable.replaceCharacters(in: match.range, with: label)
            }
        }
        var result = mutable as String

        let transforms: [(String, String)] = [
            (#"(?m)^\s{0,3}#{1,6}\s+"#, ""),
            (#"(?m)^\s*>\s?"#, ""),
            (#"(?m)^\s*[-+*]\s+"#, "• "),
            (#"(?m)^\s*\d+\.\s+"#, ""),
            (#"(?s)```[^\n]*\n(.*?)```"#, "$1"),
            (#"`([^`\n]+)`"#, "$1"),
            (#"\*\*([^*\n]+)\*\*"#, "$1"),
            (#"__([^_\n]+)__"#, "$1"),
            (#"\*([^*\n]+)\*"#, "$1"),
            (#"_([^_\n]+)_"#, "$1"),
        ]
        for (pattern, replacement) in transforms {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    static func sanitizedMarkdownReferences(_ markdown: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: markdownLinkPattern) else {
            return markdown
        }
        let source = markdown as NSString
        let output = NSMutableString(string: markdown)
        for match in expression.matches(
            in: markdown,
            range: NSRange(location: 0, length: source.length)
        ).reversed() {
            let destination = source.substring(with: match.range(at: 3))
            guard !safeExternalReference(destination) else { continue }
            let label = source.substring(with: match.range(at: 2))
            output.replaceCharacters(in: match.range, with: escapedMarkdownLabel(label))
        }
        return output as String
    }

    static func htmlDocument(title: String, markdown: String) -> String {
        let body = htmlBody(markdown)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>
        body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:48rem;margin:2rem auto;padding:0 1rem;color:#171717}
        img{max-width:100%;height:auto}pre,code{font-family:ui-monospace,SFMono-Regular,monospace}pre{overflow:auto;padding:1rem;background:#f5f5f5;border-radius:.5rem}
        blockquote{margin-left:0;padding-left:1rem;border-left:.25rem solid #ccc;color:#555}
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    static func htmlBody(_ markdown: String) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var listKind: String?

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>\(paragraph.map(renderInline).joined(separator: "<br>"))</p>")
            paragraph.removeAll()
        }
        func closeList() {
            guard let currentListKind = listKind else { return }
            output.append("</\(currentListKind)>")
            listKind = nil
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    output.append("<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
                    codeLines.removeAll()
                    inCode = false
                } else {
                    closeParagraph()
                    closeList()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                closeParagraph()
                closeList()
                continue
            }
            if let heading = headingParts(trimmed) {
                closeParagraph()
                closeList()
                output.append("<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>")
            } else if trimmed.hasPrefix(">") {
                closeParagraph()
                closeList()
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                output.append("<blockquote>\(renderInline(text))</blockquote>")
            } else if let item = unorderedListItem(trimmed) {
                closeParagraph()
                if listKind != "ul" {
                    closeList()
                    output.append("<ul>")
                    listKind = "ul"
                }
                output.append("<li>\(renderInline(item))</li>")
            } else if let item = orderedListItem(trimmed) {
                closeParagraph()
                if listKind != "ol" {
                    closeList()
                    output.append("<ol>")
                    listKind = "ol"
                }
                output.append("<li>\(renderInline(item))</li>")
            } else {
                closeList()
                paragraph.append(rawLine)
            }
        }
        if inCode {
            output.append("<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
        }
        closeParagraph()
        closeList()
        return output.joined(separator: "\n")
    }

    static func headingParts(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else {
            return nil
        }
        return (hashes.count, String(line.dropFirst(hashes.count + 1)))
    }

    static func unorderedListItem(_ line: String) -> String? {
        guard line.count >= 2 else { return nil }
        let prefix = line.prefix(2)
        guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    static func orderedListItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        let afterDot = line.index(after: dot)
        guard !number.isEmpty, number.allSatisfy(\.isNumber), afterDot < line.endIndex, line[afterDot] == " " else {
            return nil
        }
        return String(line[line.index(after: afterDot)...])
    }

    static func renderInline(_ markdown: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: markdownLinkPattern) else {
            return escapeHTML(markdown)
        }
        let source = markdown as NSString
        let matches = expression.matches(in: markdown, range: NSRange(location: 0, length: source.length))
        var cursor = 0
        var result = ""
        for match in matches {
            if match.range.location > cursor {
                result += escapeHTML(source.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                )))
            }
            let image = match.range(at: 1).length == 1
            let label = source.substring(with: match.range(at: 2))
            let destination = source.substring(with: match.range(at: 3))
            if safeExternalReference(destination) {
                let escapedURL = escapeHTMLAttribute(destination)
                if image {
                    result += "<img src=\"\(escapedURL)\" alt=\"\(escapeHTMLAttribute(label))\">"
                } else {
                    result += "<a href=\"\(escapedURL)\" rel=\"noopener noreferrer\">\(escapeHTML(label))</a>"
                }
            } else {
                result += escapeHTML(label)
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            result += escapeHTML(source.substring(from: cursor))
        }
        return result
    }

    static func safeExternalReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return false
        }
        if trimmed.hasPrefix("#") {
            return true
        }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/") || trimmed.hasPrefix("\\") {
            return false
        }
        guard let components = URLComponents(string: trimmed) else { return false }
        if let scheme = components.scheme?.lowercased() {
            return ["https", "http", "mailto", "tel"].contains(scheme)
        }
        return normalizedRelativePath(trimmed) != nil
    }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value)
    }

    static func escapedMarkdownLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func resourceLookup(_ files: [FileRepresentation]) throws -> [String: FileRepresentation] {
        var result: [String: FileRepresentation] = [:]
        for file in files {
            guard let path = normalizedRelativePath(file.relativePath) else {
                throw InterchangeError.invalidTextBundlePath(file.relativePath)
            }
            result[path] = FileRepresentation(
                relativePath: path,
                contentType: file.contentType,
                data: file.data
            )
        }
        return result
    }

    static func resolveImportedAttachments(
        in markdown: String,
        resources: [String: FileRepresentation]
    ) -> ImportResult {
        guard let expression = try? NSRegularExpression(pattern: markdownLinkPattern) else {
            return ImportResult(body: markdown, attachments: [])
        }
        let source = markdown as NSString
        let output = NSMutableString(string: markdown)
        var descriptorsByPath: [String: ImportedAttachmentDescriptor] = [:]

        for match in expression.matches(
            in: markdown,
            range: NSRange(location: 0, length: source.length)
        ).reversed() {
            let destination = source.substring(with: match.range(at: 3))
            guard !destination.lowercased().hasPrefix("wisk-attachment://"),
                  let path = normalizedRelativePath(destination),
                  let resource = importedResource(matching: path, in: resources)
            else {
                continue
            }
            let resourcePath = resource.relativePath
            let descriptor: ImportedAttachmentDescriptor
            if let existing = descriptorsByPath[resourcePath] {
                descriptor = existing
            } else {
                descriptor = ImportedAttachmentDescriptor(
                    id: UUID(),
                    fileName: (resourcePath as NSString).lastPathComponent,
                    contentType: normalizedContentType(resource.contentType, fileName: resourcePath),
                    data: resource.data,
                    sourcePath: resourcePath
                )
                descriptorsByPath[resourcePath] = descriptor
            }
            let marker = match.range(at: 1).length == 1 ? "!" : ""
            let label = source.substring(with: match.range(at: 2))
            output.replaceCharacters(
                in: match.range,
                with: "\(marker)[\(escapedMarkdownLabel(label))](wisk-attachment://\(descriptor.id.uuidString))"
            )
        }

        let descriptors = descriptorsByPath.values.sorted { $0.sourcePath < $1.sourcePath }
        return ImportResult(body: output as String, attachments: descriptors)
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    static func importedResource(
        matching path: String,
        in resources: [String: FileRepresentation]
    ) -> FileRepresentation? {
        if let exact = resources[path] ?? resources["assets/\(path)"] {
            return exact
        }
        let fileName = (path as NSString).lastPathComponent.lowercased()
        let filenameMatches = resources.values.filter {
            ($0.relativePath as NSString).lastPathComponent.lowercased() == fileName
        }
        return filenameMatches.count == 1 ? filenameMatches[0] : nil
    }

    static func normalizedRelativePath(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let replaced = decoded.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.isEmpty,
              !replaced.hasPrefix("/"),
              !replaced.hasPrefix("~"),
              !replaced.contains("\0")
        else {
            return nil
        }
        let components = replaced.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") })
        else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func normalizedContentType(_ value: String, fileName: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("/"), !trimmed.contains("\n"), !trimmed.contains("\r") {
            return trimmed
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    static func substring(_ value: String, range: NSRange) -> String {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
            return ""
        }
        return String(value[swiftRange])
    }

    static func foundationRTF(fromHTML html: String) -> Data? {
        let withoutHead = html.replacingOccurrences(
            of: #"(?is)<head\b[^>]*>.*?</head>"#,
            with: "",
            options: .regularExpression
        )
        let plain = plainText(
            from: withoutHead
                .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)</(p|h[1-6]|li|blockquote|pre)>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        )
        var body = ""
        for unit in plain.utf16 {
            switch unit {
            case 0x005C:
                body += "\\\\"
            case 0x007B:
                body += #"\{"#
            case 0x007D:
                body += #"\}"#
            case 0x000A:
                body += #" \par "#
            case 0x000D:
                continue
            case 0x0020...0x007E:
                body.unicodeScalars.append(UnicodeScalar(unit)!)
            default:
                let signed = Int16(bitPattern: unit)
                body += "\\u\(signed)?"
            }
        }
        return Data("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}}\\f0\\fs24 \(body)}".utf8)
    }
}
