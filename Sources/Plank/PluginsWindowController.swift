import AppKit

@MainActor
final class PluginsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let table = PluginTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var items: [PluginConfiguration] = []
    private let onChange: () -> Void
    private let onSettings: (String) -> Void

    init(onChange: @escaping () -> Void, onSettings: @escaping (String) -> Void) {
        self.onChange = onChange
        self.onSettings = onSettings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Plugins"
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin"))
        column.title = "Panel Plugins"
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.style = .inset
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.dataSource = self
        table.delegate = self
        table.onOpenRow = { [weak self] row in
            guard let self, self.items.indices.contains(row) else { return }
            self.onSettings(self.items[row].id)
        }
        table.onMoveRow = { [weak self] source, destination in self?.moveRow(source, to: destination) }
        // The plugin manager is a separate window and intentionally scrollable.
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let hint = SettingsUI.help("Drag to reorder · Double-click to customize")
        hint.textColor = .secondaryLabelColor
        let add = NSButton(title: "Add…", target: self, action: #selector(addPlugin(_:)))
        removeButton.target = self
        removeButton.action = #selector(removePlugin)
        let buttons = NSStackView(views: [add, removeButton])
        buttons.spacing = 8
        let heading = SettingsUI.header("Plugins", subtitle: "Build a panel that works for you.", symbol: "square.stack.3d.up")
        let content = NSStackView(views: [heading, hint, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        if let view = window.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
                heading.widthAnchor.constraint(equalTo: content.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
            ])
        }
        reload()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func reload() {
        let selectedID = items.indices.contains(table.selectedRow) ? items[table.selectedRow].id : nil
        items = PluginPreferences.configurations
        table.reloadData()
        if let selectedID, let row = items.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        removeButton.isEnabled = table.selectedRow >= 0
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard items.indices.contains(table.clickedRow), !items[table.clickedRow].enabled else { return }
        let item = menu.addItem(withTitle: "Show Plugin", action: #selector(showPlugin(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = items[table.clickedRow].id
    }

    @objc private func showPlugin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PluginPreferences.setEnabled(true, for: id)
        onChange()
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let kind = PluginPreferences.available.first { $0.0 == item.kind }?.1 ?? item.kind
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: SettingsUI.symbol(for: item.kind), accessibilityDescription: nil)
        icon.contentTintColor = item.enabled ? .controlAccentColor : .tertiaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let detail = SettingsUI.help(kind + (item.enabled ? "" : " · Hidden"))
        detail.font = .systemFont(ofSize: 11)
        let labels = SettingsUI.vertical([name, detail], spacing: 2)
        let grip = NSTextField(labelWithString: "≡")
        grip.widthAnchor.constraint(equalToConstant: 12).isActive = true
        grip.textColor = .tertiaryLabelColor
        let cell = NSStackView(views: [icon, labels, grip])
        cell.spacing = 12
        cell.alignment = .centerY
        labels.widthAnchor.constraint(equalTo: cell.widthAnchor, constant: -60).isActive = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    private func moveRow(_ source: Int, to row: Int) {
        guard items.indices.contains(source) else { return }
        let id = items[source].id
        var order = items.map(\.id)
        order.remove(at: source)
        order.insert(id, at: min(order.count, max(0, row > source ? row - 1 : row)))
        PluginPreferences.setOrder(order)
        onChange()
        reload()
        if let index = items.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func addPlugin(_ sender: NSButton) {
        let menu = NSMenu()
        for (kind, title) in PluginPreferences.available {
            let item = menu.addItem(withTitle: title, action: #selector(addKind(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind
        }
        PanelMenu.show(menu, from: sender)
    }

    @objc private func addKind(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let id = PluginPreferences.add(kind: kind)
        onChange()
        reload()
        if let row = items.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    @objc private func removePlugin() {
        guard items.indices.contains(table.selectedRow) else { return }
        PluginPreferences.remove(items[table.selectedRow].id)
        onChange()
        reload()
    }
}

/// Local reordering needs no pasteboard payload and works in an accessory app.
@MainActor
final class PluginTableView: NSTableView {
    var onMoveRow: ((Int, Int) -> Void)?
    var onOpenRow: ((Int) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Rows contain labels only. Route the complete mouse sequence to the
        // table so a label cannot consume the drag or its mouse-up event.
        super.hitTest(point) == nil ? nil : self
    }

    private var dragSource: Int?
    private var dragOrigin = NSPoint.zero
    private var isDraggingRow = false
    private lazy var insertionIndicator: NSView = {
        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1
        indicator.layer?.zPosition = 1_000
        indicator.isHidden = true
        addSubview(indicator, positioned: .above, relativeTo: nil)
        return indicator
    }()

    private func clearDrag() {
        dragSource = nil
        isDraggingRow = false
        insertionIndicator.isHidden = true
    }

    override func reloadData() {
        clearDrag()
        super.reloadData()
    }

    override func mouseDown(with event: NSEvent) {
        clearDrag()
        dragOrigin = convert(event.locationInWindow, from: nil)
        let source = row(at: dragOrigin)
        guard source >= 0 else { super.mouseDown(with: event); return }
        selectRowIndexes(IndexSet(integer: source), byExtendingSelection: false)
        if event.clickCount == 2 {
            dragSource = nil
            onOpenRow?(source)
        } else {
            dragSource = source
            isDraggingRow = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragSource != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.y - dragOrigin.y) > 4 || abs(point.x - dragOrigin.x) > 4 { isDraggingRow = true }
        if isDraggingRow {
            autoscroll(with: event)
            // Autoscrolling can change the table's coordinates under the pointer.
            let current = convert(event.locationInWindow, from: nil)
            guard visibleRect.contains(current) else {
                insertionIndicator.isHidden = true
                return
            }
            showInsertionIndicator(at: insertionRow(at: current))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { clearDrag() }
        guard let source = dragSource else { return }
        let point = convert(event.locationInWindow, from: nil)
        let moved = isDraggingRow || abs(point.y - dragOrigin.y) > 4 || abs(point.x - dragOrigin.x) > 4
        if moved && visibleRect.contains(point) { onMoveRow?(source, insertionRow(at: point)) }
    }

    override func cancelOperation(_ sender: Any?) { clearDrag() }

    private func showInsertionIndicator(at row: Int) {
        let y = row < numberOfRows
            ? rect(ofRow: row).minY - intercellSpacing.height / 2
            : rect(ofRow: numberOfRows - 1).maxY + intercellSpacing.height / 2
        insertionIndicator.frame = NSRect(x: visibleRect.minX + 8,
                                          y: min(visibleRect.maxY - 2, max(visibleRect.minY, y - 1)),
                                          width: max(0, visibleRect.width - 16), height: 2)
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.isHidden = false
    }

    private func insertionRow(at point: NSPoint) -> Int {
        // Include inter-row gaps as well as the blank area after the last row.
        for row in 0..<numberOfRows where point.y < rect(ofRow: row).midY { return row }
        return numberOfRows
    }
}
