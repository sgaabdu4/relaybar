import AppKit
import RelaybarCore

struct PoolOrderEntry {
    let email: String
    let tag: PoolTagModel
    let label: String
    let session: String
    let weekly: String
}

struct PoolOrderList {
    let kind: PoolKind
    var entries: [PoolOrderEntry]
}

@MainActor
final class PoolOrderDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowType = NSPasteboard.PasteboardType("com.relaybar.order-row")
    private var lists: [PoolOrderList]
    private let live: [PoolOrderList]
    private let logos: [PoolKind: NSImage]
    private var mode: PoolOrderMode
    private var current = 0
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let note = PoolDialogs.label("", width: 384)

    private static let autoNote = "New chats use the account whose weekly limit resets soonest, while it has room."
    private static let manualNote = "Drag to change the order. The numbers show what is left."

    init(lists: [PoolOrderList], live: [PoolOrderList], mode: PoolOrderMode, logos: [PoolKind: NSImage]) {
        self.lists = lists
        self.live = live
        self.mode = mode
        self.logos = logos
    }

    private var shown: [PoolOrderList] { mode == .automatic ? live : lists }

    func run() -> (mode: PoolOrderMode, orders: [PoolKind: [String]])? {
        let alert = NSAlert()
        alert.messageText = "How should new chats pick an account?"
        alert.informativeText = "Open chats stay on their account."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        for (id, title, width) in [("order", "Order", 190), ("five", "5 hours", 64), ("seven", "7 days", 64), ("grip", "", 26)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = CGFloat(width)
            column.maxWidth = id == "order" ? 600 : CGFloat(width)
            if id == "five" || id == "seven" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = false
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let most = lists.map(\.entries.count).max() ?? 1
        let visible = CGFloat(min(most, 6))
        scroll.documentView = table
        scroll.hasVerticalScroller = most > 6
        scroll.hasHorizontalScroller = false
        scroll.borderType = .lineBorder
        scroll.frame = NSRect(x: 0, y: 0, width: 384, height: 28 + visible * 28 + 2)
        var views: [NSView] = []
        let how = NSSegmentedControl(
            labels: ["Automatic", "Use my order"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        how.selectedSegment = mode == .automatic ? 0 : 1
        how.segmentDistribution = .fillEqually
        views.append(how)
        if lists.count > 1 {
            let switcher = NSSegmentedControl(
                labels: lists.map { $0.kind == .claude ? "Claude" : "Codex" }, trackingMode: .selectOne, target: self,
                action: #selector(switched(_:)))
            switcher.selectedSegment = 0
            views.append(switcher)
        }
        views.append(scroll)
        note.stringValue = mode == .automatic ? Self.autoNote : Self.manualNote
        views.append(note)
        let stack = PoolDialogs.column(views, width: 384)
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true
        PoolDialogs.fit(stack)
        alert.accessoryView = stack
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (mode, Dictionary(uniqueKeysWithValues: lists.map { ($0.kind, $0.entries.map(\.email)) }))
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 0 ? .automatic : .manual
        note.stringValue = mode == .automatic ? Self.autoNote : Self.manualNote
        table.reloadData()
    }

    @objc private func switched(_ sender: NSSegmentedControl) {
        current = sender.selectedSegment
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown[current].entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = shown[current].entries[row]
        switch tableColumn?.identifier.rawValue {
        case "order":
            return OrderCell(number: row + 1, entry: entry, logo: logos[shown[current].kind] ?? NSImage())
        case "five": return TextCell(entry.session, font: AccountCard.valueFont, color: .secondaryLabelColor)
        case "seven": return TextCell(entry.weekly, font: AccountCard.valueFont, color: .secondaryLabelColor)
        default: return TextCell(mode == .manual ? "≡" : "", font: .systemFont(ofSize: 13), color: .tertiaryLabelColor)
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard mode == .manual else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard mode == .manual else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.rowType), let from = Int(text),
            lists[current].entries.indices.contains(from)
        else { return false }
        let entries = lists[current].entries
        let order = PoolOrder.move(entries[from].email, to: from < row ? row - 1 : row, in: entries.map(\.email))
        lists[current].entries = order.compactMap { email in entries.first { $0.email == email } }
        tableView.reloadData()
        return true
    }

    private final class TextCell: NSView {
        private let text: String
        private let attributes: [NSAttributedString.Key: Any]

        init(_ text: String, font: NSFont, color: NSColor) {
            self.text = text
            attributes = [.font: font, .foregroundColor: color]
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: bounds.maxX - size.width - 8, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private final class OrderCell: NSView {
        private let number: Int
        private let entry: PoolOrderEntry
        private let logo: NSImage

        init(number: Int, entry: PoolOrderEntry, logo: NSImage) {
            self.number = number
            self.entry = entry
            self.logo = logo
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let middle = bounds.midY
            let digits: [NSAttributedString.Key: Any] = [.font: AccountCard.valueFont, .foregroundColor: NSColor.secondaryLabelColor]
            ("\(number)" as NSString).draw(at: NSPoint(x: 10, y: middle - 8), withAttributes: digits)
            Render.tint(logo, entry.tag.color).draw(in: NSRect(x: 30, y: middle - 7, width: 14, height: 14))
            let pill = PoolTag.width(entry.tag.text)
            PoolTag.draw(entry.tag, in: NSRect(x: 52, y: middle - 7, width: pill, height: 14))
            let name: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            (entry.label as NSString).draw(at: NSPoint(x: 52 + pill + 6, y: middle - 8), withAttributes: name)
        }
    }
}
