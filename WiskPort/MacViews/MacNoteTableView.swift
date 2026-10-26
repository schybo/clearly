import AppKit
import SwiftUI

final class WiskMenuHandler: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler()
    }
}

extension NSMenuItem {
    func withHandler(_ handler: @escaping () -> Void) -> NSMenuItem {
        let box = WiskMenuHandler(handler)
        target = box
        action = #selector(WiskMenuHandler.invoke(_:))
        representedObject = box
        return self
    }
}

struct MacNoteTableView: NSViewRepresentable {
    var rows: [MacNoteRowModel]
    var selectedNoteIDs: Binding<Set<UUID>>
    var contextMenu: (Set<UUID>) -> NSMenu?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        Self.pinOverlayScrollerToTrailingEdge(scrollView)

        let tableView = MacNoteNSTableView()
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = MacNoteRowModel.excerptedListRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.menuProvider = { [weak coordinator = context.coordinator] event, table in
            coordinator?.menu(for: event, tableView: table)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.documentView = tableView
        Self.makeBackgroundTransparent(scrollView, tableView: tableView)
        context.coordinator.tableView = tableView
        context.coordinator.lastRows = rows
        context.coordinator.rebuildRowIndex(for: rows)
        context.coordinator.syncSelection(from: selectedNoteIDs.wrappedValue, in: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        Self.pinOverlayScrollerToTrailingEdge(scrollView)
        let previousRows = context.coordinator.lastRows
        context.coordinator.parent = self
        context.coordinator.lastRows = rows
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        Self.makeBackgroundTransparent(scrollView, tableView: tableView)
        if Self.rowIDsMatch(previousRows, rows) == false {
            context.coordinator.rebuildRowIndex(for: rows)
            tableView.reloadData()
        } else if previousRows != rows {
            let visible = tableView.rows(in: tableView.visibleRect)
            if visible.length > 0 {
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        }
        let selectedIDs = selectedNoteIDs.wrappedValue
        context.coordinator.syncSelection(from: selectedIDs, in: tableView)
        if let selectedID = WiskListSelection.selectedIDToReveal(
            previousIDs: context.coordinator.lastSelectedIDs,
            nextIDs: selectedIDs
        ), let row = context.coordinator.rowIndexByID[selectedID] {
            tableView.scrollRowToVisible(row)
        }
        context.coordinator.lastSelectedIDs = selectedIDs
    }

    private static func rowIDsMatch(_ lhs: [MacNoteRowModel], _ rhs: [MacNoteRowModel]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices where lhs[index].id != rhs[index].id {
            return false
        }
        return true
    }

    private static func makeBackgroundTransparent(_ scrollView: NSScrollView, tableView: NSTableView) {
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        tableView.backgroundColor = .clear
    }

    private static func pinOverlayScrollerToTrailingEdge(_ scrollView: NSScrollView) {
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.scrollerStyle = .overlay
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: MacNoteTableView
        weak var tableView: NSTableView?
        var lastRows: [MacNoteRowModel] = []
        var lastSelectedIDs = Set<UUID>()
        var rowIndexByID: [UUID: Int] = [:]
        private var isApplyingSelection = false

        init(parent: MacNoteTableView) {
            self.parent = parent
        }

        func rebuildRowIndex(for rows: [MacNoteRowModel]) {
            var map = [UUID: Int](minimumCapacity: rows.count)
            for (index, row) in rows.enumerated() {
                map[row.id] = index
            }
            rowIndexByID = map
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("MacNoteCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? MacNoteTableCellView
                ?? MacNoteTableCellView(frame: .zero)
            cell.identifier = identifier
            if parent.rows.indices.contains(row) {
                cell.apply(parent.rows[row])
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard parent.rows.indices.contains(row) else { return MacNoteRowModel.excerptedListRowHeight }
            return parent.rows[row].listRowHeight
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let ids = IndexSet(tableView.selectedRowIndexes).compactMap { index -> UUID? in
                parent.rows.indices.contains(index) ? parent.rows[index].id : nil
            }
            let selected = Set(ids)
            guard selected.isEmpty == false else { return }
            parent.selectedNoteIDs.wrappedValue = selected
        }

        func menu(for event: NSEvent, tableView: NSTableView) -> NSMenu? {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            if row >= 0, tableView.selectedRowIndexes.contains(row) == false {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let ids = Set(
                tableView.selectedRowIndexes.compactMap { index -> UUID? in
                    parent.rows.indices.contains(index) ? parent.rows[index].id : nil
                }
            )
            return parent.contextMenu(ids)
        }

        func syncSelection(from selectedIDs: Set<UUID>, in tableView: NSTableView) {
            var indexes = IndexSet()
            for id in selectedIDs {
                if let index = rowIndexByID[id] {
                    indexes.insert(index)
                }
            }
            guard indexes != tableView.selectedRowIndexes else { return }
            let previousResponder = tableView.window?.firstResponder
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
            if let window = tableView.window,
               window.firstResponder === tableView,
               let previousResponder,
               previousResponder !== tableView {
                window.makeFirstResponder(previousResponder)
            }
        }
    }
}

private final class MacNoteNSTableView: NSTableView {
    var menuProvider: ((NSEvent, NSTableView) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            NotificationCenter.default.post(name: .wiskNoteListBecameFirstResponder, object: nil)
        }
        return accepted
    }

    @objc func paste(_ sender: Any?) {
        guard MacPasteSupport.hasImageContent() else { return }
        NotificationCenter.default.post(name: .wiskPasteImageIntoSelectedNote, object: nil)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return MacPasteSupport.hasImageContent()
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event, self) ?? super.menu(for: event)
    }
}

private final class MacNoteTableCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let pinView = NSImageView()
    private let kindView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        excerptLabel.font = .systemFont(ofSize: 11)
        excerptLabel.textColor = .secondaryLabelColor
        excerptLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        pinView.contentTintColor = .secondaryLabelColor
        kindView.contentTintColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleRow(), excerptLabel, metaLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(_ model: MacNoteRowModel) {
        titleLabel.stringValue = model.title
        titleLabel.setAccessibilityIdentifier("wisk.mac.noteList.row")
        setAccessibilityLabel(model.title)
        excerptLabel.stringValue = model.excerpt
        excerptLabel.isHidden = model.excerpt.isEmpty
        var meta = "Edited \(model.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        if model.deletedAt == nil {
            let tags = model.tagNames.map { "#\($0)" }.joined(separator: " ")
            if tags.isEmpty == false {
                meta += "  \(tags)"
            }
        }
        metaLabel.stringValue = meta
        pinView.isHidden = model.pinned == false
        pinView.image = model.pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") : nil
        switch model.kind {
        case .list:
            kindView.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "List")
            kindView.isHidden = false
        case .structured:
            kindView.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Structured")
            kindView.isHidden = false
        case .tracker:
            kindView.image = NSImage(systemSymbolName: "plus.forwardslash.minus", accessibilityDescription: "Tracker")
            kindView.isHidden = false
        default:
            kindView.image = nil
            kindView.isHidden = true
        }
    }

    private func titleRow() -> NSView {
        pinView.imageScaling = .scaleProportionallyDown
        kindView.imageScaling = .scaleProportionallyDown
        let row = NSStackView(views: [pinView, kindView, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        pinView.setContentHuggingPriority(.required, for: .horizontal)
        kindView.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }
}
