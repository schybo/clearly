import Foundation

enum WiskMarkdownTableAlignment: Sendable, Equatable {
    case none
    case leading
    case trailing
    case center
}

struct WiskMarkdownTableCell: Sendable, Equatable {
    let sourceRange: NSRange
    let text: String
}

struct WiskMarkdownTableRow: Sendable, Equatable {
    let sourceRange: NSRange
    let contentRange: NSRange
    let newlineRange: NSRange
    let isDivider: Bool
    let isHeader: Bool
    let cells: [WiskMarkdownTableCell]
    let rawSource: String
}

struct WiskMarkdownTable: Sendable, Equatable {
    let sourceRange: NSRange
    let alignments: [WiskMarkdownTableAlignment]
    let rows: [WiskMarkdownTableRow]

    var columnCount: Int {
        max(rows.map(\.cells.count).max() ?? 0, alignments.count)
    }

    var headerRow: WiskMarkdownTableRow? {
        rows.first { $0.isHeader }
    }

    var bodyRows: [WiskMarkdownTableRow] {
        rows.filter { $0.isDivider == false && $0.isHeader == false }
    }

    func rowIndex(containingSource location: Int) -> Int? {
        rows.firstIndex { location >= $0.sourceRange.location && location <= $0.sourceRange.upperBound }
    }

    func cell(containingSource location: Int) -> (row: Int, column: Int, cell: WiskMarkdownTableCell)? {
        guard let rowIndex = rowIndex(containingSource: location) else { return nil }
        let row = rows[rowIndex]
        if let column = row.cells.firstIndex(where: {
            location >= $0.sourceRange.location && location <= $0.sourceRange.upperBound
        }) {
            return (rowIndex, column, row.cells[column])
        }
        if let last = row.cells.last, location >= last.sourceRange.upperBound {
            return (rowIndex, row.cells.count - 1, last)
        }
        if let first = row.cells.first {
            return (rowIndex, 0, first)
        }
        return nil
    }
}

enum WiskMarkdownTableSyntax {
    static func tables(in document: WiskMarkdownDocument) -> [WiskMarkdownTable] {
        var tables: [WiskMarkdownTable] = []
        var index = 0
        let lines = WiskMarkdownDocumentEngine.sourceLines(document.source)
        while index < lines.count {
            if let table = table(startingAt: index, lines: lines, source: document.source) {
                tables.append(table)
                index += table.rows.count
            } else {
                index += 1
            }
        }
        return tables
    }

    static func table(
        startingAt lineIndex: Int,
        lines: [WiskMarkdownDocumentEngine.SourceLine],
        source: String
    ) -> WiskMarkdownTable? {
        guard lineIndex < lines.count else { return nil }
        let firstBody = WiskMarkdownDocumentEngine.substring(source, range: lines[lineIndex].contentRange)
        guard WiskMarkdownDocumentEngine.isTableRow(firstBody)
                || WiskMarkdownDocumentEngine.isTableDivider(firstBody) else {
            return nil
        }

        var end = lineIndex
        while end < lines.count {
            let body = WiskMarkdownDocumentEngine.substring(source, range: lines[end].contentRange)
            if WiskMarkdownDocumentEngine.isTableRow(body) || WiskMarkdownDocumentEngine.isTableDivider(body) {
                end += 1
            } else {
                break
            }
        }
        let grouped = Array(lines[lineIndex..<end])
        guard grouped.count >= 2 else { return nil }

        let parsedRows: [WiskMarkdownTableRow] = grouped.enumerated().compactMap { offset, line in
            let body = WiskMarkdownDocumentEngine.substring(source, range: line.contentRange)
            let isDivider = WiskMarkdownDocumentEngine.isTableDivider(body)
            guard isDivider || WiskMarkdownDocumentEngine.isTableRow(body) else { return nil }
            return WiskMarkdownTableRow(
                sourceRange: line.fullRange,
                contentRange: line.contentRange,
                newlineRange: line.newlineRange,
                isDivider: isDivider,
                isHeader: offset == 0 && isDivider == false,
                cells: cells(in: body, baseLocation: line.contentRange.location),
                rawSource: WiskMarkdownDocumentEngine.substring(source, range: line.fullRange)
            )
        }
        guard parsedRows.count == grouped.count,
              parsedRows.contains(where: \.isDivider),
              parsedRows.first?.isDivider == false else {
            return nil
        }

        let divider = parsedRows.first(where: \.isDivider)
        let alignments = (divider?.cells ?? []).map(alignment(from:))
        let start = grouped.first?.fullRange.location ?? 0
        let endLocation = grouped.last?.fullRange.upperBound ?? start
        return WiskMarkdownTable(
            sourceRange: NSRange(location: start, length: endLocation - start),
            alignments: alignments,
            rows: parsedRows
        )
    }

    static func cells(in line: String, baseLocation: Int) -> [WiskMarkdownTableCell] {
        let ns = line as NSString
        var cells: [WiskMarkdownTableCell] = []
        var cellStart = 0
        var index = 0
        var escaped = false
        var sawPipe = false

        func appendCell(upTo end: Int) {
            let length = max(0, end - cellStart)
            let range = NSRange(location: baseLocation + cellStart, length: length)
            let text = ns.substring(with: NSRange(location: cellStart, length: length))
            cells.append(WiskMarkdownTableCell(sourceRange: range, text: text))
        }

        while index < ns.length {
            let character = ns.substring(with: NSRange(location: index, length: 1))
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                if sawPipe || cellStart != index {
                    appendCell(upTo: index)
                }
                sawPipe = true
                cellStart = index + 1
            }
            index += 1
        }

        if sawPipe, cellStart < ns.length {
            appendCell(upTo: ns.length)
        } else if sawPipe == false, ns.length > 0 {
            appendCell(upTo: ns.length)
        }

        if cells.count >= 2,
           cells.first?.text.trimmingCharacters(in: .whitespaces).isEmpty == true,
           line.hasPrefix("|") {
            cells.removeFirst()
        }
        if cells.last?.text.trimmingCharacters(in: .whitespaces).isEmpty == true,
           line.trimmingCharacters(in: .whitespaces).hasSuffix("|"),
           cells.count > 1 {
            cells.removeLast()
        }
        return cells
    }

    static func alignment(from cell: WiskMarkdownTableCell) -> WiskMarkdownTableAlignment {
        let trimmed = cell.text.trimmingCharacters(in: .whitespaces)
        let leading = trimmed.hasPrefix(":")
        let trailing = trimmed.hasSuffix(":")
        if leading && trailing { return .center }
        if leading { return .leading }
        if trailing { return .trailing }
        return .none
    }

    static func visibleLine(for row: WiskMarkdownTableRow) -> String {
        guard row.isDivider == false else { return "" }
        return row.cells.map(\.text).joined()
    }
}

extension WiskMarkdownDocumentEngine {
    static func applyTableTab(
        in source: String,
        sourceRange: NSRange,
        reverse: Bool
    ) -> WiskMarkdownMutation? {
        guard isValidSourceRange(sourceRange, in: source) else { return nil }
        let document = parse(source)
        guard let table = document.tables.first(where: {
            sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
        }) else {
            return nil
        }
        let dataRows = table.rows.filter { $0.isDivider == false }
        guard dataRows.isEmpty == false else { return nil }
        let caret = sourceRange.location
        var rowIndex = dataRows.firstIndex { caret >= $0.sourceRange.location && caret <= $0.sourceRange.upperBound } ?? 0
        var columnIndex = 0
        if let current = table.cell(containingSource: caret),
           let mappedRow = dataRows.firstIndex(where: { $0.sourceRange == table.rows[current.row].sourceRange }) {
            rowIndex = mappedRow
            columnIndex = current.column
        }

        if reverse {
            if columnIndex > 0 {
                columnIndex -= 1
            } else if rowIndex > 0 {
                rowIndex -= 1
                columnIndex = max(dataRows[rowIndex].cells.count - 1, 0)
            } else {
                rowIndex = dataRows.count - 1
                columnIndex = max(dataRows[rowIndex].cells.count - 1, 0)
            }
        } else if columnIndex + 1 < dataRows[rowIndex].cells.count {
            columnIndex += 1
        } else if rowIndex + 1 < dataRows.count {
            rowIndex += 1
            columnIndex = 0
        } else {
            rowIndex = 0
            columnIndex = 0
        }

        let cells = dataRows[rowIndex].cells
        guard cells.isEmpty == false else { return nil }
        let target = cells[min(columnIndex, cells.count - 1)]
        return WiskMarkdownMutation(
            source: source,
            selectedSourceRange: NSRange(location: target.sourceRange.location, length: 0)
        )
    }

    static func applyTableReturn(in source: String, caret: Int) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let table = document.tables.first(where: {
            caret >= $0.sourceRange.location && caret <= $0.sourceRange.upperBound
        }) else {
            return nil
        }
        guard let rowIndex = table.rowIndex(containingSource: caret) else { return nil }
        let row = table.rows[rowIndex]
        if row.isDivider {
            return insertEmptyRow(in: source, table: table, afterRowIndex: rowIndex)
        }

        let isLastBodyRow = table.bodyRows.last.map { $0.sourceRange == row.sourceRange } ?? false
        let isEmptyRow = row.cells.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if isLastBodyRow && isEmptyRow && row.isHeader == false {
            let replacementRange = row.sourceRange
            let insertion: String
            let selectionOffset: Int
            if table.sourceRange.upperBound >= source.utf16.count {
                insertion = "\n"
                selectionOffset = 0
            } else {
                insertion = ""
                selectionOffset = 0
            }
            return replacing(
                source,
                range: replacementRange,
                with: insertion,
                selectionOffset: selectionOffset,
                selectionLength: 0
            )
        }
        return insertEmptyRow(in: source, table: table, afterRowIndex: rowIndex)
    }

    static func insertTableRow(in source: String, sourceRange: NSRange) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let table = document.tables.first(where: {
            sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
        }) else {
            return nil
        }
        let rowIndex = table.rowIndex(containingSource: sourceRange.location) ?? (table.rows.count - 1)
        return insertEmptyRow(in: source, table: table, afterRowIndex: rowIndex)
    }

    static func deleteTableRow(in source: String, sourceRange: NSRange) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let table = document.tables.first(where: {
            sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
        }),
              let rowIndex = table.rowIndex(containingSource: sourceRange.location) else {
            return nil
        }
        let row = table.rows[rowIndex]
        if row.isDivider || row.isHeader { return nil }
        return replacing(
            source,
            range: row.sourceRange,
            with: "",
            selectionOffset: 0,
            selectionLength: 0
        )
    }

    static func insertTableColumn(in source: String, sourceRange: NSRange) -> WiskMarkdownMutation? {
        mutateTableColumns(in: source, sourceRange: sourceRange) { rows, column in
            rows.map { row in
                insertColumn(in: row, at: column + 1, isDivider: row.isDivider)
            }
        }
    }

    static func deleteTableColumn(in source: String, sourceRange: NSRange) -> WiskMarkdownMutation? {
        mutateTableColumns(in: source, sourceRange: sourceRange) { rows, column in
            guard rows.contains(where: { $0.cells.count > 1 }) else { return rows }
            return rows.map { row in
                deleteColumn(in: row, at: column)
            }
        }
    }

    static func replaceTableCell(
        in source: String,
        sourceRange: NSRange,
        with text: String
    ) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let table = document.tables.first(where: {
            sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
        }),
              let cell = table.cell(containingSource: sourceRange.location) else {
            return nil
        }
        return replaceSourceRange(in: source, sourceRange: cell.cell.sourceRange, with: text)
    }

    private static func insertEmptyRow(
        in source: String,
        table: WiskMarkdownTable,
        afterRowIndex: Int
    ) -> WiskMarkdownMutation? {
        let row = table.rows[min(max(afterRowIndex, 0), table.rows.count - 1)]
        let insertion = emptyRow(columnCount: max(table.columnCount, 1)) + "\n"
        return replacing(
            source,
            range: NSRange(location: row.sourceRange.upperBound, length: 0),
            with: insertion,
            selectionOffset: 2,
            selectionLength: 0
        )
    }

    private static func emptyRow(columnCount: Int) -> String {
        let cells = Array(repeating: "  ", count: max(columnCount, 1)).joined(separator: "|")
        return "|\(cells)|"
    }

    private static func mutateTableColumns(
        in source: String,
        sourceRange: NSRange,
        transform: ([WiskMarkdownTableRow], Int) -> [WiskMarkdownTableRow]
    ) -> WiskMarkdownMutation? {
        let document = parse(source)
        guard let table = document.tables.first(where: {
            sourceRange.location >= $0.sourceRange.location && sourceRange.location <= $0.sourceRange.upperBound
        }),
              let current = table.cell(containingSource: sourceRange.location) else {
            return nil
        }
        let updatedRows = transform(table.rows, current.column)
        let rebuilt = updatedRows.map(\.rawSource).joined()
        return replacing(
            source,
            range: table.sourceRange,
            with: rebuilt,
            selectionOffset: 0,
            selectionLength: 0
        )
    }

    private static func insertColumn(in row: WiskMarkdownTableRow, at column: Int, isDivider: Bool) -> WiskMarkdownTableRow {
        var cells = row.cells
        let insertion = isDivider ? " --- " : "  "
        let index = min(max(column, 0), cells.count)
        let location: Int
        if index < cells.count {
            location = cells[index].sourceRange.location
        } else if let last = cells.last {
            location = last.sourceRange.upperBound
        } else {
            location = row.contentRange.location
        }
        cells.insert(
            WiskMarkdownTableCell(sourceRange: NSRange(location: location, length: insertion.utf16.count), text: insertion),
            at: index
        )
        return rebuiltRow(from: cells, original: row, isDivider: isDivider)
    }

    private static func deleteColumn(in row: WiskMarkdownTableRow, at column: Int) -> WiskMarkdownTableRow {
        var cells = row.cells
        guard cells.isEmpty == false else { return row }
        let index = min(max(column, 0), cells.count - 1)
        cells.remove(at: index)
        return rebuiltRow(from: cells, original: row, isDivider: row.isDivider)
    }

    private static func rebuiltRow(
        from cells: [WiskMarkdownTableCell],
        original: WiskMarkdownTableRow,
        isDivider: Bool
    ) -> WiskMarkdownTableRow {
        let inner = cells.map(\.text).joined(separator: "|")
        let line = "|\(inner)|"
        let newline = original.newlineRange.length > 0 ? "\n" : ""
        return WiskMarkdownTableRow(
            sourceRange: original.sourceRange,
            contentRange: original.contentRange,
            newlineRange: original.newlineRange,
            isDivider: isDivider,
            isHeader: original.isHeader,
            cells: cells,
            rawSource: line + newline
        )
    }
}
