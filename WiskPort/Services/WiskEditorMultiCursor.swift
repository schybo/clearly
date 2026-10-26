import Foundation

enum WiskEditorMultiCursor {
    static let maxOccurrenceCount = 500

    enum Command {
        case splitIntoLines
        case selectNextOccurrence
        case selectAllOccurrences
    }

    enum CaretMove {
        case left
        case right
        case up
        case down
        case wordLeft
        case wordRight
        case lineStart
        case lineEnd
    }

    enum CaretDelete {
        case backward
        case forward
    }

    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    static func normalizedSelectionRanges(_ ranges: [NSRange], textLength: Int? = nil) -> [NSRange] {
        var cleaned: [NSRange] = []
        for range in ranges where range.location != NSNotFound && range.location >= 0 && range.length >= 0 {
            if let textLength {
                if range.location > textLength { continue }
                let length = min(range.length, textLength - range.location)
                cleaned.append(NSRange(location: range.location, length: max(length, 0)))
            } else {
                cleaned.append(range)
            }
        }
        cleaned.sort { lhs, rhs in
            if lhs.location == rhs.location {
                return lhs.length < rhs.length
            }
            return lhs.location < rhs.location
        }
        var disjoint: [NSRange] = []
        for range in cleaned {
            if let last = disjoint.last, NSMaxRange(last) > range.location {
                continue
            }
            disjoint.append(range)
        }
        return disjoint
    }

    /// One zero-length caret at the start of each selected line.
    /// Prefers hard newlines; `fragmentRanges` covers a single wrapped paragraph.
    static func splitIntoLines(
        selection: NSRange,
        in text: String,
        fragmentRanges: [NSRange] = []
    ) -> [NSRange]? {
        if let hardLines = splitHardLines(selection: selection, in: text) {
            return hardLines
        }
        return splitFragmentLines(
            selection: selection,
            fragmentRanges: fragmentRanges,
            textLength: (text as NSString).length
        )
    }

    private static func splitHardLines(selection: NSRange, in text: String) -> [NSRange]? {
        guard selection.location != NSNotFound, selection.length > 0 else { return nil }
        let ns = text as NSString
        let selectionEnd = NSMaxRange(selection)
        guard selection.location <= ns.length, selectionEnd <= ns.length else { return nil }

        var ranges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, contentRange, enclosingRange, _ in
            guard selection.location < enclosingRange.upperBound,
                  selectionEnd > enclosingRange.location else {
                return
            }
            let start = max(selection.location, contentRange.location)
            if start <= contentRange.upperBound {
                ranges.append(NSRange(location: start, length: 0))
            }
        }

        let normalized = normalizedSelectionRanges(ranges, textLength: ns.length)
        guard normalized.count >= 2 else { return nil }
        return normalized
    }

    private static func splitFragmentLines(
        selection: NSRange,
        fragmentRanges: [NSRange],
        textLength: Int
    ) -> [NSRange]? {
        guard selection.location != NSNotFound, selection.length > 0 else { return nil }
        let selectionEnd = NSMaxRange(selection)
        var ranges: [NSRange] = []
        for fragment in fragmentRanges {
            guard selection.location < fragment.upperBound,
                  selectionEnd > fragment.location else {
                continue
            }
            let start = max(selection.location, fragment.location)
            ranges.append(NSRange(location: start, length: 0))
        }
        let normalized = normalizedSelectionRanges(ranges, textLength: textLength)
        guard normalized.count >= 2 else { return nil }
        return normalized
    }

    static func wordRange(at location: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let loc = min(max(location, 0), ns.length)

        if loc < ns.length, isWordCharacter(in: ns, at: loc) {
            return extendWord(in: ns, covering: loc)
        }
        if loc > 0, isWordCharacter(in: ns, at: loc - 1) {
            return extendWord(in: ns, covering: loc - 1)
        }
        return nil
    }

    static func needle(for ranges: [NSRange], in text: String) -> String? {
        let ns = text as NSString
        let normalized = normalizedSelectionRanges(ranges, textLength: ns.length)
        guard let primary = normalized.last ?? normalized.first, primary.length > 0 else { return nil }
        guard NSMaxRange(primary) <= ns.length else { return nil }
        let value = ns.substring(with: primary)
        return value.isEmpty ? nil : value
    }

    static func selectNextOccurrence(ranges: [NSRange], in text: String, searchAfter: NSRange? = nil) -> [NSRange]? {
        let ns = text as NSString
        let current = normalizedSelectionRanges(ranges, textLength: ns.length)
        if current.count == 1, current[0].length == 0 {
            guard let word = wordRange(at: current[0].location, in: text) else { return nil }
            return [word]
        }
        guard let needle = needle(for: current, in: text) else { return nil }
        let origin = searchAfter.flatMap { range -> NSRange? in
            current.first { NSEqualRanges($0, range) } ?? range
        } ?? current.max(by: { NSMaxRange($0) < NSMaxRange($1) }) ?? current[0]
        guard let next = nextOccurrence(of: needle, in: text, after: origin, skipping: current) else {
            return nil
        }
        return normalizedSelectionRanges(current + [next], textLength: ns.length)
    }

    static func selectAllOccurrences(ranges: [NSRange], in text: String) -> [NSRange]? {
        let ns = text as NSString
        var current = normalizedSelectionRanges(ranges, textLength: ns.length)
        if current.count == 1, current[0].length == 0 {
            guard let word = wordRange(at: current[0].location, in: text) else { return nil }
            current = [word]
        }
        guard let needle = needle(for: current, in: text) else { return nil }
        let matches = allOccurrences(of: needle, in: text)
        guard matches.count >= 1 else { return nil }
        return matches
    }

    static func nextOccurrence(
        of needle: String,
        in text: String,
        after lastRange: NSRange,
        skipping selected: [NSRange]
    ) -> NSRange? {
        let ns = text as NSString
        let needleLength = (needle as NSString).length
        guard needleLength > 0 else { return nil }

        let afterStart = min(max(NSMaxRange(lastRange), 0), ns.length)
        if let found = firstOccurrence(
            of: needle,
            in: ns,
            range: NSRange(location: afterStart, length: ns.length - afterStart),
            skipping: selected
        ) {
            return found
        }
        let wrapEnd = min(max(lastRange.location, 0), ns.length)
        return firstOccurrence(
            of: needle,
            in: ns,
            range: NSRange(location: 0, length: wrapEnd),
            skipping: selected
        )
    }

    static func allOccurrences(of needle: String, in text: String, cap: Int = maxOccurrenceCount) -> [NSRange] {
        let ns = text as NSString
        let needleLength = (needle as NSString).length
        guard needleLength > 0, cap > 0 else { return [] }
        var matches: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length >= needleLength, matches.count < cap {
            let found = ns.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let nextLocation = found.location + max(found.length, 1)
            if nextLocation >= ns.length { break }
            search = NSRange(location: nextLocation, length: ns.length - nextLocation)
        }
        return matches
    }

    /// Replaces each range with the same string, walking document order so later
    /// offsets stay valid. New selections are collapsed carets after each insert.
    static func replace(
        ranges: [NSRange],
        in text: String,
        with replacement: String
    ) -> (text: String, selectedRanges: [NSRange])? {
        applyAscending(ranges: ranges, in: text) { current, range in
            let ns = current as NSString
            guard range.location != NSNotFound,
                  range.location >= 0,
                  NSMaxRange(range) <= ns.length else {
                return nil
            }
            let updated = ns.replacingCharacters(in: range, with: replacement)
            let caret = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            return (updated, caret)
        }
    }

    static func applyAscending(
        ranges: [NSRange],
        in text: String,
        mutate: (String, NSRange) -> (text: String, selectedRange: NSRange)?
    ) -> (text: String, selectedRanges: [NSRange])? {
        applyAscending(
            edits: ranges.map { (range: $0, replacement: "") },
            in: text
        ) { current, range, _ in
            mutate(current, range)
        }
    }

    static func applyAscending(
        edits: [(range: NSRange, replacement: String)],
        in text: String,
        mutate: (String, NSRange, String) -> (text: String, selectedRange: NSRange)?
    ) -> (text: String, selectedRanges: [NSRange])? {
        let sorted = edits.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
        guard !sorted.isEmpty else { return nil }
        var source = text
        var delta = 0
        var selected: [NSRange] = []
        for edit in sorted {
            let shifted = NSRange(location: edit.range.location + delta, length: edit.range.length)
            guard let mutation = mutate(source, shifted, edit.replacement) else { return nil }
            let lengthDelta = (mutation.text as NSString).length - (source as NSString).length
            source = mutation.text
            selected.append(mutation.selectedRange)
            delta += lengthDelta
        }
        return (source, selected)
    }

    static func moveCarets(_ ranges: [NSRange], in text: String, direction: CaretMove) -> [NSRange] {
        let ns = text as NSString
        var seen = Set<Int>()
        var moved: [NSRange] = []
        for range in normalizedSelectionRanges(ranges, textLength: ns.length) {
            let location = moveCaret(range.location, in: ns, direction: direction)
            if seen.insert(location).inserted {
                moved.append(NSRange(location: location, length: 0))
            }
        }
        return moved
    }

    static func deletionRanges(
        fromCarets ranges: [NSRange],
        direction: CaretDelete,
        in text: String
    ) -> [NSRange]? {
        let ns = text as NSString
        var deletions: [NSRange] = []
        for caret in normalizedSelectionRanges(ranges, textLength: ns.length) {
            switch direction {
            case .backward:
                if caret.location > 0 {
                    deletions.append(NSRange(location: caret.location - 1, length: 1))
                }
            case .forward:
                if caret.location < ns.length {
                    deletions.append(NSRange(location: caret.location, length: 1))
                }
            }
        }
        let unique = normalizedSelectionRanges(deletions, textLength: ns.length)
        guard unique.isEmpty == false else { return nil }
        return unique
    }

    static func uniqueLineRanges(_ ranges: [NSRange], in text: String) -> [NSRange] {
        let ns = text as NSString
        var seen = Set<Int>()
        var unique: [NSRange] = []
        for range in normalizedSelectionRanges(ranges, textLength: ns.length) {
            let location = min(max(range.location, 0), ns.length)
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if seen.insert(line.location).inserted {
                unique.append(range)
            }
        }
        return unique
    }

    private static func firstOccurrence(
        of needle: String,
        in ns: NSString,
        range searchRange: NSRange,
        skipping selected: [NSRange]
    ) -> NSRange? {
        guard searchRange.length > 0, searchRange.location >= 0, NSMaxRange(searchRange) <= ns.length else {
            return nil
        }
        var search = searchRange
        let needleLength = (needle as NSString).length
        while search.length >= needleLength {
            let found = ns.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { return nil }
            if selected.contains(where: { NSEqualRanges($0, found) }) == false {
                return found
            }
            let nextLocation = found.location + max(found.length, 1)
            if nextLocation >= NSMaxRange(searchRange) { return nil }
            search = NSRange(location: nextLocation, length: NSMaxRange(searchRange) - nextLocation)
        }
        return nil
    }

    private static func extendWord(in ns: NSString, covering index: Int) -> NSRange? {
        guard ns.length > 0, index >= 0, index < ns.length else { return nil }
        var start = ns.rangeOfComposedCharacterSequence(at: index).location
        var end = ns.rangeOfComposedCharacterSequence(at: index).upperBound
        while start > 0 {
            let previous = ns.rangeOfComposedCharacterSequence(at: start - 1)
            if isWordCharacter(in: ns, at: previous.location) {
                start = previous.location
            } else {
                break
            }
        }
        while end < ns.length {
            if isWordCharacter(in: ns, at: end) {
                end = ns.rangeOfComposedCharacterSequence(at: end).upperBound
            } else {
                break
            }
        }
        let length = end - start
        guard length > 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    private static func moveCaret(_ location: Int, in ns: NSString, direction: CaretMove) -> Int {
        let length = ns.length
        let loc = min(max(location, 0), length)
        switch direction {
        case .left:
            return max(loc - 1, 0)
        case .right:
            return min(loc + 1, length)
        case .up:
            return verticalCaret(from: loc, in: ns, delta: -1)
        case .down:
            return verticalCaret(from: loc, in: ns, delta: 1)
        case .lineStart:
            return lineContentRange(at: loc, in: ns).location
        case .lineEnd:
            return NSMaxRange(lineContentRange(at: loc, in: ns))
        case .wordLeft:
            return wordBoundary(from: loc, in: ns, goingLeft: true)
        case .wordRight:
            return wordBoundary(from: loc, in: ns, goingLeft: false)
        }
    }

    private static func verticalCaret(from location: Int, in ns: NSString, delta: Int) -> Int {
        let current = lineContentRange(at: location, in: ns)
        let column = max(location - current.location, 0)
        if delta < 0 {
            guard current.location > 0 else { return location }
            let previous = lineContentRange(at: current.location - 1, in: ns)
            return previous.location + min(column, previous.length)
        }
        let enclosing = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        guard NSMaxRange(enclosing) < ns.length else { return location }
        let next = lineContentRange(at: NSMaxRange(enclosing), in: ns)
        return next.location + min(column, next.length)
    }

    private static func lineContentRange(at location: Int, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let loc = min(max(location, 0), ns.length)
        let enclosing = ns.lineRange(for: NSRange(location: loc, length: 0))
        var content = enclosing
        if content.length > 0 {
            let last = ns.character(at: content.upperBound - 1)
            if last == 10 || last == 13 {
                content.length -= 1
            }
        }
        return content
    }

    private static func wordBoundary(from location: Int, in ns: NSString, goingLeft: Bool) -> Int {
        let text = ns as String
        let length = ns.length
        let loc = min(max(location, 0), length)
        if goingLeft {
            if loc == 0 { return 0 }
            if let word = wordRange(at: loc, in: text) ?? wordRange(at: loc - 1, in: text), loc > word.location {
                return word.location
            }
            var index = max(loc - 1, 0)
            while index > 0, wordRange(at: index, in: text) == nil {
                index -= 1
            }
            return wordRange(at: index, in: text)?.location ?? 0
        }
        if loc >= length { return length }
        if let word = wordRange(at: loc, in: text), loc < NSMaxRange(word) {
            return NSMaxRange(word)
        }
        var index = loc
        while index < length, wordRange(at: index, in: text) == nil {
            index += 1
        }
        return wordRange(at: index, in: text).map { NSMaxRange($0) } ?? length
    }

    private static func isWordCharacter(in ns: NSString, at index: Int) -> Bool {
        guard index >= 0, index < ns.length else { return false }
        let composed = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: index))
        return composed.unicodeScalars.isEmpty == false
            && composed.unicodeScalars.allSatisfy { wordCharacters.contains($0) }
    }
}
