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
            screenSize: button.window?.screen?.visibleFrame.size ?? NSSize(width: 1000, height: 800),
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
    private let path = NSTextField(wrappingLabelWithString: "")

    init(configuration: PluginConfiguration) {
        folderURL = FolderPlugin.folderURL(for: configuration)
        super.init(sectionTitle: "Folder", windowHeight: 450)
        path.stringValue = folderURL.path
        path.isSelectable = true
        path.setAccessibilityLabel("Folder path")
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        options = [path, SettingsUI.row("", control: choose),
                   SettingsUI.help("Click the panel icon to browse a grid. Click folders to go inside and files to open them. Scroll to see all items; Open in Finder is always last. The preview uses at most a quarter of the screen. Each instance has its own location.")]
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
    }
}

/// A fresh directory snapshot is loaded for every navigation, including Back.
struct FolderGridContents {
    let items: [URL]
    init(folder: URL) throws {
        items = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }
}

struct FolderGridLayout {
    let columns: Int
    let size: NSSize
    let contentHeight: CGFloat

    init(itemCount: Int, messageHeight: CGFloat = 0, screenSize: NSSize) {
        // Leave room for the popover border and arrow inside the quarter-screen budget.
        let maximumSide = max(1, min(sqrt(screenSize.width * screenSize.height / 4) - 32,
                                     screenSize.width - 64, screenSize.height - 80))
        let maximumColumns = max(1, Int((maximumSide - 40) / 104))
        let count = max(1, itemCount)
        columns = min(maximumColumns, max(1, Int(ceil(sqrt(Double(count))))))
        contentHeight = messageHeight + CGFloat((count + columns - 1) / columns) * 104
        // Fit the actual columns; adding height must never widen sparse rows.
        let width = CGFloat(columns) * 104 + 40
        let maximumHeight = min(maximumSide, width + 20 + messageHeight)
        size = NSSize(width: width, height: min(contentHeight + 60, maximumHeight))
    }
}

@MainActor
final class FolderGridController: NSViewController {
    var onResize: ((NSSize) -> Void)?
    private var folder: URL
    private let screenSize: NSSize
    private let openFinder: (URL) -> Void
    private let close: () -> Void
    private var history: [URL] = []
    private var actions: [() -> Void] = []
    private var tiles: [FolderGridTile] = []
    private var selected = -1
    private var columns = 5
    private let scroll = NSScrollView()

    init(folder: URL, screenSize: NSSize, openFinder: @escaping (URL) -> Void, close: @escaping () -> Void) {
        self.folder = folder
        self.screenSize = screenSize
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
        let screen = view.window?.screen
        let available = screen?.visibleFrame.size ?? screenSize
        let document = FolderGridKeyboardView()
        var message: String?
        do {
            let contents = try FolderGridContents(folder: folder)
            for url in contents.items {
                addTile(title: FileManager.default.displayName(atPath: url.path),
                        image: NSWorkspace.shared.icon(forFile: url.path), tooltip: url.path) { [weak self] in
                    self?.open(url)
                }
            }
            if contents.items.isEmpty { message = "This folder is empty." }
        } catch {
            message = "Unable to read this folder. \(error.localizedDescription)"
        }
        addTile(title: "Open in Finder", image: FolderGridIcons.openInFinder, tooltip: "Open \(folder.path) with Finder") {
            [weak self] in self?.showFinder()
        }
        let offset: CGFloat = message == nil ? 0 : 60
        let layout = FolderGridLayout(itemCount: tiles.count, messageHeight: offset, screenSize: available)
        columns = layout.columns
        let width = layout.size.width
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
        if let message {
            let label = NSTextField(wrappingLabelWithString: message)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 12, y: 4, width: width - 48, height: 52)
            document.addSubview(label)
        }
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % columns) * 104,
                                y: offset + CGFloat(index / columns) * 104, width: 104, height: 104)
            document.addSubview(tile)
        }
        let contentHeight = layout.contentHeight
        let height = layout.size.height - 60
        document.frame = NSRect(x: 0, y: 0, width: width - 24, height: contentHeight)
        scroll.frame = NSRect(x: 12, y: 48, width: width - 24, height: height)
        if !(scroll.contentView is FolderGridClipView) {
            let clip = FolderGridClipView()
            clip.onPointerChanged = { [weak self] point in self?.updateHover(at: point) }
            clip.postsBoundsChangedNotifications = true
            scroll.contentView = clip
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = document
        view.addSubview(scroll)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        preferredContentSize = NSSize(width: width, height: height + 60)
        // Once presented, let NSPopover resize its content view. Resizing the view
        // first makes AppKit restore the previous popover size on its next layout.
        if view.window == nil { view.setFrameSize(preferredContentSize) }
        onResize?(preferredContentSize)
        updateHover()
    }

    @objc private func scrolled(_ notification: Notification) {
        // Scrolling can move another tile under a stationary pointer without a mouse event.
        updateHover()
    }

    private func updateHover(at point: NSPoint? = nil) {
        guard let window = scroll.window, window.isVisible else {
            tiles.forEach { $0.isHovered = false }
            return
        }
        let location = point ?? window.mouseLocationOutsideOfEventStream
        let clip = scroll.contentView
        let inside = clip.bounds.contains(clip.convert(location, from: nil))
        for tile in tiles {
            tile.isHovered = inside && tile.bounds.contains(tile.convert(location, from: nil))
        }
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
            for (index, tile) in tiles.enumerated() { tile.isKeyboardSelected = index == selected }
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
    var isHovered = false { didSet { if oldValue != isHovered { updateHighlight() } } }
    var isKeyboardSelected = false { didSet { if oldValue != isKeyboardSelected { updateHighlight() } } }

    override var isFlipped: Bool { true }

    init(title: String, icon: NSImage?) {
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        setAccessibilityLabel(title)
        let image = NSImageView(frame: NSRect(x: 28, y: 12, width: 48, height: 48))
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 4, y: 65, width: 96, height: 32)
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    private func updateHighlight() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = isHovered || isKeyboardSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : nil
    }
}

/// Keep short directory snapshots pinned to the leading, top edge of the viewport.
@MainActor
private final class FolderGridClipView: NSClipView {
    var onPointerChanged: ((NSPoint) -> Void)?
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerChanged?(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { onPointerChanged?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onPointerChanged?(event.locationInWindow) }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if let documentView {
            if documentView.frame.width <= result.width { result.origin.x = 0 }
            if documentView.frame.height <= result.height { result.origin.y = 0 }
        }
        return result
    }
}

@MainActor
private enum FolderGridIcons {
    static let openInFinder: NSImage = {
        let resources = Bundle(path: "/System/Library/CoreServices/Dock.app")
        let arrow = resources?.url(forResource: "openinfinder", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "arrowshape.turn.up.right.circle", accessibilityDescription: nil)
        let size = NSSize(width: 64, height: 64)
        let rect = NSRect(origin: .zero, size: size)
        let glyph = NSImage(size: size)
        glyph.lockFocus()
        arrow?.draw(in: rect)
        NSColor.gray.setFill()
        rect.fill(using: .sourceIn)
        glyph.unlockFocus()

        let tile = NSImage(size: size)
        tile.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10).fill()
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        tile.unlockFocus()
        return tile
    }()
}
