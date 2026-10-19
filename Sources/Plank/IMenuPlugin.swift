import AppKit

@MainActor
final class IMenuPlugin: NSObject, PanelPlugin, NSWindowDelegate {
    let id: String
    private let button = NSButton()
    private let menuPanel = ApplicationsMenuPanel(contentRect: .zero, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
    private var menuAnchor: NSRect?
    private var menuSafeFrame: NSRect?
    private var opensAbove = true
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let menuController = ApplicationsMenuController()
    private var buttonWidth: NSLayoutConstraint!
    private var buttonHeight: NSLayoutConstraint!
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "iMenu Applications Menu")
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.toolTip = "iMenu · Browse and search apps"
        button.setAccessibilityLabel("iMenu Applications Menu")
        button.target = self
        button.action = #selector(toggleMenu)
        button.translatesAutoresizingMaskIntoConstraints = false
        buttonWidth = button.widthAnchor.constraint(equalToConstant: 44)
        buttonHeight = button.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([buttonWidth, buttonHeight])
        menuPanel.isReleasedWhenClosed = false
        menuPanel.delegate = self
        menuPanel.isMovable = false
        menuPanel.isOpaque = false
        menuPanel.backgroundColor = .clear
        menuPanel.hasShadow = true
        menuPanel.level = .popUpMenu
        menuPanel.contentViewController = menuController
        NotificationCenter.default.addObserver(self, selector: #selector(closeMenu),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        menuController.onLaunch = { [weak self] application in self?.launch(application) }
        menuController.onClose = { [weak self] in self?.closeMenu() }
        menuController.onSystemAction = { [weak self] action in
            self?.closeMenu()
            action.perform()
        }
    }

    func setPanelHeight(_ height: CGFloat) {
        buttonWidth.constant = PanelMetrics.buttonSize(for: height)
        buttonHeight.constant = buttonWidth.constant
        let configuration = NSImage.SymbolConfiguration(pointSize: max(16, height - 16), weight: .regular)
        button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "iMenu Applications Menu")?
            .withSymbolConfiguration(configuration)
    }

    func refresh() {
        menuController.setIconView(PluginPreferences.configuration(id)?.imenuShowsIcons == true)
    }

    @objc private func toggleMenu() {
        if menuPanel.isVisible { closeMenu(); return }
        refresh()
        guard let window = button.window, let screen = window.screen else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let anchor = NSRect(x: buttonFrame.minX, y: window.frame.minY,
                            width: buttonFrame.width, height: window.frame.height)
        let safe = screen.visibleFrame
        let above = max(0, safe.maxY - anchor.maxY)
        let below = max(0, anchor.minY - safe.minY)
        let defaults = PluginPreferences.defaults
        let savedWidth = defaults.double(forKey: "plugin.\(id).menuWidth")
        let savedHeight = defaults.double(forKey: "plugin.\(id).menuHeight")
        let availableHeight = min(max(above, below), safe.height)
        let maximum = NSSize(width: safe.width, height: availableHeight)
        let minimum = NSSize(width: min(360, maximum.width), height: min(300, maximum.height))
        let size = NSSize(width: min(maximum.width, max(minimum.width, savedWidth.isFinite && savedWidth > 0 ? savedWidth : 400)),
                          height: min(maximum.height, max(minimum.height, savedHeight.isFinite && savedHeight > 0 ? savedHeight : 480)))
        menuAnchor = anchor
        menuSafeFrame = safe
        opensAbove = above >= below
        menuPanel.contentMinSize = minimum
        menuPanel.contentMaxSize = maximum
        let x = min(max(anchor.minX, safe.minX), safe.maxX - size.width)
        let preferredY = above >= below ? anchor.maxY : anchor.minY - size.height
        let y = min(max(preferredY, safe.minY), safe.maxY - size.height)
        menuPanel.setContentSize(size)
        menuPanel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        menuPanel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
        menuController.beginSearch()
    }

    func windowDidResize(_ notification: Notification) {
        guard menuPanel.inLiveResize, let anchor = menuAnchor, let safe = menuSafeFrame else { return }
        let size = menuPanel.frame.size
        let x = min(max(anchor.minX, safe.minX), safe.maxX - size.width)
        let y = opensAbove ? anchor.maxY : anchor.minY - size.height
        menuPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        PluginPreferences.defaults.set(menuPanel.frame.width, forKey: "plugin.\(id).menuWidth")
        PluginPreferences.defaults.set(menuPanel.frame.height, forKey: "plugin.\(id).menuHeight")
    }

    private func installDismissMonitors() {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Let the launcher button toggle the menu itself, without
                // dismissing on mouse-down and reopening on mouse-up.
                let onButton = event.window === self.button.window
                    && self.button.bounds.contains(self.button.convert(event.locationInWindow, from: nil))
                if event.window !== self.menuPanel && !onButton { self.closeMenu() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeMenu() }
        }
    }

    @objc private func closeMenu() {
        menuPanel.orderOut(nil)
        menuController.cancelLoading()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    func stop() { closeMenu() }

    private func launch(_ application: CatalogApplication) {
        closeMenu()
        NSWorkspace.shared.openApplication(at: application.url, configuration: .init()) { _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Unable to Launch Application"
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }
}

@MainActor
private final class ApplicationsMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ApplicationsMenuController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onLaunch: ((CatalogApplication) -> Void)?
    var onClose: (() -> Void)?
    var onSystemAction: ((SystemSessionAction) -> Void)?
    private let search = NSSearchField()
    private let table = ApplicationsTableView()
    private let grid = ApplicationsIconGrid()
    // The application catalog is a separate popup and intentionally scrollable.
    private let scroll = NSScrollView()
    private var showsIcons = false
    private let status = NSTextField(labelWithString: "Loading applications…")
    private var applications: [CatalogApplication] = []
    private var filtered: [CatalogApplication] = []
    private var loadingTask: Task<Void, Never>?

    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 480))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        view = background
        let title = NSTextField(labelWithString: "Applications")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        search.placeholderString = "Search apps…"
        search.setAccessibilityLabel("Search apps")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.width = 350
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(launchClicked)
        table.onReturn = { [weak self] in self?.launchSelected() }
        table.onEscape = { [weak self] in self?.onClose?() }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = showsIcons ? grid : table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        grid.onLaunch = { [weak self] index in
            guard let self, self.filtered.indices.contains(index) else { return }
            self.onLaunch?(self.filtered[index])
        }
        grid.onEscape = { [weak self] in self?.onClose?() }
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [title, status])
        header.alignment = .firstBaseline
        header.spacing = 10
        let actions = NSStackView()
        actions.distribution = .fillEqually
        actions.spacing = 8
        for (index, action) in SystemSessionAction.allCases.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(systemActionClicked(_:)))
            button.tag = index
            button.image = action.icon
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = true
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.toolTip = action == .lock ? "Lock Screen" : action.title
            button.setAccessibilityLabel(button.toolTip!)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            actions.addArrangedSubview(button)
        }
        let separator = NSBox()
        separator.boxType = .separator
        let systemTitle = NSTextField(labelWithString: "System")
        systemTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        systemTitle.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [separator, systemTitle, actions])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        let content = NSStackView(views: [header, search, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            search.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            separator.widthAnchor.constraint(equalTo: footer.widthAnchor),
            actions.widthAnchor.constraint(equalTo: footer.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }

    func beginSearch() {
        loadViewIfNeeded()
        search.stringValue = ""
        applyFilter()
        status.stringValue = "Loading applications…"
        view.window?.makeKey()
        view.window?.makeFirstResponder(search)
        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { ApplicationCatalog.scan() }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.applications = result
            self.applyFilter()
        }
    }

    func cancelLoading() { loadingTask?.cancel(); loadingTask = nil }

    func setIconView(_ enabled: Bool) {
        guard showsIcons != enabled else { return }
        showsIcons = enabled
        guard isViewLoaded else { return }
        scroll.documentView = enabled ? grid : table
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !filtered.isEmpty else { return true }
            if showsIcons {
                grid.select(0)
                view.window?.makeFirstResponder(grid)
            } else {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                view.window?.makeFirstResponder(table)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { launchSelected(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        return false
    }

    private func applyFilter() {
        filtered = CatalogApplication.matching(search.stringValue, in: applications)
        table.reloadData()
        if showsIcons { grid.setApplications(filtered) }
        table.deselectAll(nil)
        if !filtered.isEmpty { table.scrollRowToVisible(0) }
        status.stringValue = filtered.isEmpty ? "No matching applications" : "\(filtered.count) apps · Click to launch · Esc to close"
        status.toolTip = status.stringValue
    }

    @objc private func systemActionClicked(_ sender: NSButton) {
        guard SystemSessionAction.allCases.indices.contains(sender.tag) else { return }
        onSystemAction?(SystemSessionAction.allCases[sender.tag])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let application = filtered[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: application.url.path)
        icon.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: application.name)
        name.lineBreakMode = .byTruncatingTail
        name.font = .systemFont(ofSize: 13)
        cell.imageView = icon
        cell.textField = name
        cell.toolTip = application.url.path
        for child in [icon, name] {
            child.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ApplicationsMenuRowView()
    }

    @objc private func launchClicked() {
        guard filtered.indices.contains(table.clickedRow) else { return }
        onLaunch?(filtered[table.clickedRow])
    }

    private func launchSelected() {
        if showsIcons {
            guard filtered.indices.contains(grid.selectedIndex) else { return }
            onLaunch?(filtered[grid.selectedIndex])
            return
        }
        guard filtered.indices.contains(table.selectedRow) else { return }
        onLaunch?(filtered[table.selectedRow])
    }
}

@MainActor
private final class ApplicationsIconGrid: NSView {
    var onLaunch: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    private var buttons: [ApplicationsMenuButton] = []
    private(set) var selectedIndex = -1
    private var columns = 1
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setApplications(_ applications: [CatalogApplication]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = applications.enumerated().map { index, application in
            let button = ApplicationsMenuButton(title: application.name, target: self, action: #selector(launch(_:)))
            let icon = NSWorkspace.shared.icon(forFile: application.url.path)
            icon.size = NSSize(width: 44, height: 44)
            button.image = icon
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = "\(application.name) · \(application.url.path)"
            button.setAccessibilityLabel(application.name)
            button.tag = index
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            addSubview(button)
            return button
        }
        selectedIndex = -1
        updateSelection()
        needsLayout = true
        enclosingScrollView?.contentView.scroll(to: .zero)
    }

    override func layout() {
        super.layout()
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = clip.bounds.width
        columns = max(1, Int(width / 88))
        let cellWidth = width / CGFloat(columns)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index % columns) * cellWidth + 3,
                                  y: CGFloat(index / columns) * 88 + 3,
                                  width: max(1, cellWidth - 6), height: 82)
        }
        let height = max(clip.bounds.height, CGFloat((buttons.count + columns - 1) / columns) * 88)
        let size = NSSize(width: width, height: height)
        if frame.size != size { setFrameSize(size) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width]
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    func select(_ index: Int) {
        guard !buttons.isEmpty else { return }
        selectedIndex = min(buttons.count - 1, max(0, index))
        updateSelection()
        scrollToVisible(buttons[selectedIndex].frame)
    }

    private func updateSelection() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, button) in buttons.enumerated() {
                button.keyboardSelected = index == selectedIndex
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection()
    }

    @objc private func launch(_ sender: NSButton) { onLaunch?(sender.tag) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(selectedIndex - 1)
        case 124: select(selectedIndex + 1)
        case 125: select(selectedIndex < 0 ? 0 : selectedIndex + columns)
        case 126: select(selectedIndex - columns)
        case 36, 76: if selectedIndex >= 0 { onLaunch?(selectedIndex) }
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

// Draw interaction backgrounds ourselves so borderless icon buttons have the
// same hover and pressed feedback in both light and dark appearances.
@MainActor
private final class ApplicationsMenuButton: NSButton {
    var keyboardSelected = false { didSet { needsDisplay = true } }
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        hovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted || keyboardSelected || hovering {
            let color = isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.32)
                : keyboardSelected ? NSColor.controlAccentColor.withAlphaComponent(0.2)
                : NSColor.labelColor.withAlphaComponent(0.08)
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
private final class ApplicationsMenuRowView: NSTableRowView {
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        hovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hovering && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }
}

@MainActor
private final class ApplicationsTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
extension IMenuPlugin {
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        IMenuSettings(configuration: configuration)
    }
}

@MainActor
private final class IMenuSettings: PluginSettingsContent {
    private let imenuViewMode = NSPopUpButton()

    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "Applications Menu", windowHeight: 430)
        imenuViewMode.addItems(withTitles: ["List View", "Icon View"])
        imenuViewMode.selectItem(at: configuration.imenuShowsIcons ? 1 : 0)
        imenuViewMode.target = self
        imenuViewMode.action = #selector(requestSave)
        imenuViewMode.widthAnchor.constraint(equalToConstant: 160).isActive = true
        imenuViewMode.setAccessibilityLabel("Applications display mode")
        options = [SettingsUI.row("Display as", control: imenuViewMode),
                   SettingsUI.help("Browse and search installed apps. Click an app to launch it, or use the arrow keys and Return. Press Esc or click outside to close."),
                   SettingsUI.help("Lock, Sleep, Restart, and Shut Down are available at the bottom of the menu.")]
    }

    override func save(to config: inout PluginConfiguration) {
        config.imenuViewMode = imenuViewMode.indexOfSelectedItem == 1 ? "icons" : "list"
    }
}
