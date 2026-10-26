import Foundation

/// Repairs note text corrupted by a byte-swapped unicode-escape writer.
///
/// A corrupting tool escaped each UTF-16 code unit with its two bytes swapped,
/// emitting literal `\uXXXX` text: `>` (U+003E) became `\u3e00`, `<` became
/// `\u3c00`, `&` became `\u2600`, and emoji became byte-swapped surrogate
/// pairs (`👋` = `\ud83d\ude4b` → `\u3dd8\u4bdc`).
///
/// Decoding swaps the four hex digits back and accepts the result only when it
/// is provably the product of this corruption: a printable ASCII character
/// (0x20–0x7E) or a complete, valid surrogate pair forming a scalar ≥ U+10000.
/// Everything else is left untouched, so standard JSON escapes (`\u003e`,
/// `\u0026`, `\ud83d\ude00`) and lone surrogates pass through unchanged.
enum WiskByteSwappedEscapeRepair {
    /// Scans `\u` + exactly four hex digits and rewrites byte-swapped escapes
    /// back into their original characters.
    static func repaired(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard containsRepairableEscapes(text) else { return text }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"),
                  index + 6 <= bytes.count,
                  bytes[index + 1] == UInt8(ascii: "u"),
                  let hex = hexValue(bytes: bytes, start: index + 2) else {
                output.append(bytes[index])
                index += 1
                continue
            }

            let swapped = swap(hex)
            if isPrintableASCII(swapped) {
                output.append(UInt8(swapped))
                index += 6
                continue
            }
            if isHighSurrogate(swapped),
               index + 12 <= bytes.count,
               bytes[index + 6] == UInt8(ascii: "\\"),
               bytes[index + 7] == UInt8(ascii: "u"),
               let lowHex = hexValue(bytes: bytes, start: index + 8) {
                let swappedLow = swap(lowHex)
                if isLowSurrogate(swappedLow) {
                    let scalarValue = 0x10000
                        + (UInt32(swapped) - 0xD800) << 10
                        + (UInt32(swappedLow) - 0xDC00)
                    if let scalar = Unicode.Scalar(scalarValue) {
                        append(scalar, to: &output)
                        index += 12
                        continue
                    }
                }
            }
            // Not repairable: copy the six escape bytes verbatim.
            output.append(contentsOf: bytes[index..<index + 6])
            index += 6
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Cheap pre-check: true when the text contains at least one `\uXXXX`
    /// sequence whose byte-swapped value repairs to printable ASCII or a valid
    /// surrogate pair.
    static func containsRepairableEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index + 6 <= bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"),
                  bytes[index + 1] == UInt8(ascii: "u"),
                  let hex = hexValue(bytes: bytes, start: index + 2) else {
                index += 1
                continue
            }
            let swapped = swap(hex)
            if isPrintableASCII(swapped) {
                return true
            }
            if isHighSurrogate(swapped),
               index + 12 <= bytes.count,
               bytes[index + 6] == UInt8(ascii: "\\"),
               bytes[index + 7] == UInt8(ascii: "u"),
               let lowHex = hexValue(bytes: bytes, start: index + 8) {
                if isLowSurrogate(swap(lowHex)) {
                    return true
                }
            }
            index += 6
        }
        return false
    }

    // MARK: - Internals

    private static func hexValue(bytes: [UInt8], start: Int) -> UInt16? {
        guard start + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for offset in 0..<4 {
            guard let digit = hexDigitValue(bytes[start + offset]) else { return nil }
            value = value << 4 | digit
        }
        return value
    }

    private static func hexDigitValue(_ byte: UInt8) -> UInt16? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt16(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt16(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt16(byte - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    private static func swap(_ value: UInt16) -> UInt16 {
        (value << 8) | (value >> 8)
    }

    private static func isPrintableASCII(_ value: UInt16) -> Bool {
        (0x20...0x7E).contains(value)
    }

    private static func isHighSurrogate(_ value: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(value)
    }

    private static func isLowSurrogate(_ value: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(value)
    }

    private static func append(_ scalar: Unicode.Scalar, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: Array(String(scalar).utf8))
    }
}
