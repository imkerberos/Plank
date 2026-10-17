import AppKit

@MainActor
final class IMenuPlugin: NSObject, PanelPlugin {
    let id: String
    private let button = NSButton()
    private let menuPanel = ApplicationsMenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
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

    func refresh() {}

    @objc private func toggleMenu() {
        if menuPanel.isVisible { closeMenu(); return }
        guard let window = button.window, let screen = window.screen else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let anchor = NSRect(x: buttonFrame.minX, y: window.frame.minY,
                            width: buttonFrame.width, height: window.frame.height)
        let safe = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let above = max(0, safe.maxY - anchor.maxY)
        let below = max(0, anchor.minY - safe.minY)
        let size = NSSize(width: min(400, safe.width),
                          height: min(480, max(200, max(above, below)), safe.height))
        let x = min(max(anchor.minX, safe.minX), safe.maxX - size.width)
        let preferredY = above >= below ? anchor.maxY : anchor.minY - size.height
        let y = min(max(preferredY, safe.minY), safe.maxY - size.height)
        menuController.preferredContentSize = size
        menuPanel.setContentSize(size)
        menuPanel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        menuPanel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
        menuController.beginSearch()
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
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
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
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.toolTip = action == .lock ? "Lock Screen" : action.title
            button.setAccessibilityLabel(button.toolTip!)
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            actions.addArrangedSubview(button)
        }
        let content = NSStackView(views: [header, search, scroll, actions])
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
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
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

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !filtered.isEmpty else { return true }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            view.window?.makeFirstResponder(table)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { launchSelected(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        return false
    }

    private func applyFilter() {
        filtered = CatalogApplication.matching(search.stringValue, in: applications)
        table.reloadData()
        if !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
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

    @objc private func launchClicked() {
        guard filtered.indices.contains(table.clickedRow) else { return }
        onLaunch?(filtered[table.clickedRow])
    }

    private func launchSelected() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        onLaunch?(filtered[table.selectedRow])
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
