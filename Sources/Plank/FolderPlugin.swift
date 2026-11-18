import AppKit

@MainActor
final class FolderPlugin: NSObject, PanelPlugin {
    let id: String
    private let button = PanelMenuButton()
    private let popover = NSPopover()
    private var buttonSize: CGFloat = 44
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(toggleGrid)
        popover.behavior = .transient
        popover.animates = false
        button.translatesAutoresizingMaskIntoConstraints = false
        width = button.widthAnchor.constraint(equalToConstant: buttonSize)
        height = button.heightAnchor.constraint(equalToConstant: buttonSize)
        NSLayoutConstraint.activate([width, height])
    }

    func setPanelHeight(_ panelHeight: CGFloat) {
        buttonSize = PanelMetrics.buttonSize(for: panelHeight)
        width.constant = buttonSize
        height.constant = buttonSize
    }

    func refresh() {
        let url = Self.folderURL(for: PluginPreferences.configuration(id))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: max(24, buttonSize - 8), height: max(24, buttonSize - 8))
        button.image = icon
        button.toolTip = "Browse Folder · \(url.path)"
        button.setAccessibilityLabel("Browse \(url.lastPathComponent)")
    }

    func addMenuItems(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Open Folder", action: #selector(openFolder), keyEquivalent: "")
        item.target = self
        menu.addItem(.separator())
    }

    func stop() { popover.close() }

    @objc private func toggleGrid() {
        if popover.isShown { popover.close(); return }
        let configuration = PluginPreferences.configuration(id)
        let controller = FolderGridController(
            folder: Self.folderURL(for: configuration),
            limit: configuration?.folderGridLimit ?? 32,
            openFinder: { [weak self] url in self?.openFolderInFinder(url) },
            close: { [weak self] in self?.popover.close() })
        popover.contentViewController = controller
        controller.onResize = { [weak self] size in self?.popover.contentSize = size }
        popover.contentSize = controller.preferredContentSize
        PanelPopover.show(popover, from: button, event: NSApp.currentEvent)
        NSApp.activate(ignoringOtherApps: true)
        controller.focusGrid()
    }

    @objc private func openFolder() {
        openFolderInFinder(Self.folderURL(for: PluginPreferences.configuration(id)))
    }

    private func openFolderInFinder(_ url: URL) {
        popover.close()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            showError("The folder is unavailable: \(url.path)\nChoose an existing folder in this plugin’s settings.")
            return
        }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            showError("Finder could not be found.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: configuration, completionHandler: nil)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unable to Open Folder"
        alert.informativeText = message
        alert.runModal()
    }

    fileprivate static func folderURL(for configuration: PluginConfiguration?) -> URL {
        guard let path = configuration?.folderPath, !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        FolderSettings(configuration: configuration)
    }
}

@MainActor
private final class FolderSettings: PluginSettingsContent {
    private var folderURL: URL
    private let maximum = NSPopUpButton()
    private var limits = [8, 16, 32, 64, 128]
    private let path = NSTextField(wrappingLabelWithString: "")

    init(configuration: PluginConfiguration) {
        folderURL = FolderPlugin.folderURL(for: configuration)
        super.init(sectionTitle: "Folder", windowHeight: 450)
        path.stringValue = folderURL.path
        path.isSelectable = true
        path.setAccessibilityLabel("Folder path")
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        if !limits.contains(configuration.folderGridLimit) {
            limits.append(configuration.folderGridLimit)
            limits.sort()
        }
        maximum.addItems(withTitles: limits.map(String.init))
        maximum.selectItem(at: limits.firstIndex(of: configuration.folderGridLimit) ?? 2)
        maximum.target = self
        maximum.action = #selector(requestSave)
        maximum.setAccessibilityLabel("Maximum items in grid")
        options = [path, SettingsUI.row("", control: choose),
                   SettingsUI.row("Maximum items in grid", control: maximum),
                   SettingsUI.help("Click the panel icon to browse a grid. Click folders to go inside and files to open them. Overflow (…) and Open with Finder open the current folder in Finder. Each instance has its own location and item limit.")]
    }

    @objc private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose Folder"
        picker.prompt = "Choose"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = folderURL
        guard picker.runModal() == .OK, let url = picker.url else { return }
        folderURL = url.standardizedFileURL
        path.stringValue = folderURL.path
        requestSave()
    }

    override func save(to configuration: inout PluginConfiguration) {
        configuration.folderPath = folderURL.path
        configuration.folderMaximumItems = limits[maximum.indexOfSelectedItem]
    }
}

/// A fresh directory snapshot is loaded for every navigation, including Back.
struct FolderGridContents {
    let items: [URL]
    let hasMore: Bool

    init(folder: URL, limit: Int) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        let count = max(1, limit)
        items = Array(urls.prefix(count))
        hasMore = urls.count > count
    }
}

@MainActor
private final class FolderGridController: NSViewController {
    var onResize: ((NSSize) -> Void)?
    private var folder: URL
    private let limit: Int
    private let openFinder: (URL) -> Void
    private let close: () -> Void
    private var history: [URL] = []
    private var actions: [() -> Void] = []
    private var tiles: [FolderGridTile] = []
    private var selected = -1
    private var columns = 5
    private let scroll = NSScrollView()

    init(folder: URL, limit: Int, openFinder: @escaping (URL) -> Void, close: @escaping () -> Void) {
        self.folder = folder
        self.limit = limit
        self.openFinder = openFinder
        self.close = close
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = FolderGridKeyboardView()
        root.onKey = { [weak self] in self?.handleKey($0) }
        view = root
        render()
    }

    func focusGrid() {
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }

    private func render() {
        view.subviews.forEach { $0.removeFromSuperview() }
        tiles = []
        actions = []
        selected = -1
        let screen = view.window?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? NSSize(width: 1000, height: 800)
        columns = max(2, min(5, Int((available.width - 64) / 104)))
        // Reserve a gutter for systems configured to always show scroll bars.
        let width = CGFloat(columns) * 104 + 40
        let header = NSTextField(labelWithString: FileManager.default.displayName(atPath: folder.path))
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.lineBreakMode = .byTruncatingMiddle
        header.toolTip = folder.path
        header.frame = NSRect(x: 52, y: 14, width: width - 104, height: 22)
        header.alignment = .center
        view.addSubview(header)
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                            target: self, action: #selector(goBack))
        back.isBordered = false
        back.isEnabled = !history.isEmpty
        back.frame = NSRect(x: 12, y: 10, width: 32, height: 30)
        back.toolTip = "Back"
        view.addSubview(back)
        let document = FolderGridKeyboardView()
        var message: String?
        do {
            let contents = try FolderGridContents(folder: folder, limit: limit)
            for url in contents.items {
                addTile(title: FileManager.default.displayName(atPath: url.path),
                        image: NSWorkspace.shared.icon(forFile: url.path), tooltip: url.path) { [weak self] in
                    self?.open(url)
                }
            }
            if contents.items.isEmpty { message = "This folder is empty." }
            if contents.hasMore {
                addTile(title: "...", image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil),
                        tooltip: "Show all items in Finder") { [weak self] in self?.showFinder() }
            }
        } catch {
            message = "Unable to read this folder. \(error.localizedDescription)"
        }
        let finderIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        addTile(title: "Open with Finder", image: finderIcon, tooltip: "Open \(folder.path) with Finder") {
            [weak self] in self?.showFinder()
        }
        var offset: CGFloat = 0
        if let message {
            let label = NSTextField(wrappingLabelWithString: message)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 12, y: 4, width: width - 48, height: 52)
            document.addSubview(label)
            offset = 60
        }
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % columns) * 104,
                                y: offset + CGFloat(index / columns) * 104, width: 104, height: 104)
            document.addSubview(tile)
        }
        let contentHeight = offset + CGFloat((tiles.count + columns - 1) / columns) * 104
        let height = min(contentHeight, max(104, available.height - 180))
        document.frame = NSRect(x: 0, y: 0, width: width - 24, height: contentHeight)
        scroll.frame = NSRect(x: 12, y: 48, width: width - 24, height: height)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        view.addSubview(scroll)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        preferredContentSize = NSSize(width: width, height: height + 60)
        view.setFrameSize(preferredContentSize)
        onResize?(preferredContentSize)
    }

    private func addTile(title: String, image: NSImage?, tooltip: String, action: @escaping () -> Void) {
        let tile = FolderGridTile(title: title, icon: image)
        tile.target = self
        tile.action = #selector(choose(_:))
        tile.tag = actions.count
        tile.toolTip = tooltip
        actions.append(action)
        tiles.append(tile)
    }

    @objc private func choose(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        action()
    }

    private func open(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        // Apps and document packages open with their registered application.
        if values?.isDirectory == true && values?.isPackage != true {
            history.append(folder)
            folder = url
            render()
            focusGrid()
        } else {
            close()
            if !NSWorkspace.shared.open(url) {
                let alert = NSAlert()
                alert.messageText = "Unable to Open File"
                alert.informativeText = url.path
                alert.runModal()
            }
        }
    }

    private func showFinder() { openFinder(folder) }

    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        folder = previous
        render()
        focusGrid()
    }

    private func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53: close()
        case 51: goBack()
        case 36, 76:
            if actions.indices.contains(selected) { actions[selected]() }
        case 123, 124, 125, 126:
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
            selected = selected < 0 ? 0 : min(tiles.count - 1, max(0, selected + delta))
            for (index, tile) in tiles.enumerated() { tile.highlightCell(index == selected) }
            tiles[selected].scrollToVisible(tiles[selected].bounds)
        default: break
        }
    }
}

@MainActor
private final class FolderGridKeyboardView: NSView {
    var onKey: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if let onKey { onKey(event) } else { super.keyDown(with: event) }
    }
}

@MainActor
private final class FolderGridTile: NSButton {
    private var hoverArea: NSTrackingArea?

    init(title: String, icon: NSImage?) {
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setAccessibilityLabel(title)
        let image = NSImageView(frame: NSRect(x: 28, y: 40, width: 48, height: 48))
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 4, y: 5, width: 96, height: 32)
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    func highlightCell(_ highlighted: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : nil
    }
    override func mouseEntered(with event: NSEvent) { highlightCell(true) }
    override func mouseExited(with event: NSEvent) { highlightCell(false) }
}
