import Foundation

enum WiskAttachmentMarkdown {
    static func reference(title: String, id: UUID, isImage: Bool) -> String {
        let escapedTitle = title.replacingOccurrences(of: "]", with: "\\]")
        if isImage {
            return "![\(escapedTitle)](wisk-attachment://\(id.uuidString))"
        }
        return "[\(escapedTitle)](wisk-attachment://\(id.uuidString))"
    }

    static func inserting(_ reference: String, into body: String, utf16Range: NSRange?) -> String {
        if let utf16Range, let range = Range(utf16Range, in: body) {
            return body.replacingCharacters(in: range, with: reference)
        }
        return appending(reference, to: body)
    }

    static func appending(_ reference: String, to body: String) -> String {
        if body.isEmpty {
            return reference
        }
        if body.hasSuffix("\n\n") {
            return body + reference
        }
        if body.hasSuffix("\n") {
            return body + "\n" + reference
        }
        return body + "\n\n" + reference
    }
}
