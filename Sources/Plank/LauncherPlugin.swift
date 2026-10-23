import AppKit

@MainActor
final class LauncherPlugin: NSObject, PanelPlugin {
    let id: String
    private let dropView = LauncherDropView()
    var view: NSView { dropView }
    private var buttonSize: CGFloat = 44
    var onChange: (() -> Void)?

    init(id: String) {
        self.id = id
        super.init()
        dropView.onDrop = { [weak self] urls in
            guard let self, LauncherStore.add(urls, to: self.id) else { return false }
            // Finish the native drop before the panel rebuilds its layout.
            Task { @MainActor [weak self] in self?.onChange?() }
            return true
        }
    }

    func setPanelHeight(_ height: CGFloat) {
        buttonSize = PanelMetrics.buttonSize(for: height)
        dropView.setHeight(buttonSize)
    }

    func refresh() {
        dropView.clearReorderPreview()
        for child in dropView.arrangedSubviews {
            dropView.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let paths = LauncherStore.paths(for: id)
        let showRunning = PluginPreferences.configuration(id)?.launcherShowRunningIndicator == true
        let runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
        })
        if paths.isEmpty {
            let hint = NSTextField(labelWithString: "＋ Drop Apps Here")
            hint.textColor = .secondaryLabelColor
            hint.setAccessibilityLabel("Drag apps here from Finder or Taskbar to add shortcuts")
            dropView.addArrangedSubview(hint)
        }
        for path in paths {
            let button = LauncherButton(path: path, size: buttonSize)
            button.includesApplicationMenu = showRunning
            button.showsRunningIndicator = showRunning && runningPaths.contains(
                URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)
            button.onOpen = { [weak self] in self?.openApplication(path) }
            button.onDragPreview = { [weak self] point in self?.dropView.previewReorder(at: point) }
            button.onDragFinished = { [weak self] point in
                guard let self else { return }
                self.dropView.clearReorderPreview()
                guard !PanelPreferences.isLocked, let point,
                      let content = self.dropView.window?.contentView else { return }
                if !content.bounds.contains(content.convert(point, from: nil)) {
                    // Removing a launcher entry only edits its saved shortcut
                    // list. Never move, delete, or quit the application itself.
                    LauncherStore.remove(path, from: self.id)
                    Task { @MainActor [weak self] in self?.onChange?() }
                    return
                }
                guard let gap = self.dropView.insertionIndex(at: point),
                      LauncherStore.move(path, to: gap, in: self.id) else { return }
                Task { @MainActor [weak self] in self?.onChange?() }
            }
            let menu = NSMenu()
            let remove = menu.addItem(withTitle: "Remove Shortcut", action: #selector(removeItem(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = path
            button.menu = menu
            dropView.addArrangedSubview(button)
        }
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        LauncherStore.remove(path, from: id)
        onChange?()
    }

    private func openApplication(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard LauncherStore.applicationURL(url) != nil else {
            showError("Application not found. Remove this shortcut and drag the app in again from Finder.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unable to Launch Application"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
private final class LauncherButton: NSButton {
    private let applicationURL: URL
    var includesApplicationMenu = false
    private var runningApplication: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == applicationURL && !$0.isTerminated
        }
    }
    var showsRunningIndicator = false { didSet { needsDisplay = true } }
    var onOpen: (() -> Void)?
    var onDragPreview: ((NSPoint) -> Void)?
    var onDragFinished: ((NSPoint?) -> Void)?
    private var pressOrigin: NSPoint?
    private var isReordering = false
    private var feedbackTask: Task<Void, Never>?
    private var pressedFeedback = false

    init(path: String, size: CGFloat) {
        applicationURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        super.init(frame: .zero)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: max(24, size - 8), height: max(24, size - 8))
        image = icon
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        wantsLayer = true
        let name = FileManager.default.displayName(atPath: path)
        toolTip = "\(name) · Drag to reorder or outside the panel to remove shortcut"
        setAccessibilityLabel("Launch \(name)")
        AppBadgeView.attach(to: self, applicationURL: URL(fileURLWithPath: path),
                            iconSize: max(24, size - 8), buttonSize: size)
        target = self
        action = #selector(openApplication)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsRunningIndicator else { return }
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        let diameter: CGFloat = 4
        let y = isFlipped ? bounds.maxY - diameter - 1 : bounds.minY + 1
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2, y: y,
                                  width: diameter, height: diameter)).fill()
    }
    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        isReordering = false
        feedbackTask?.cancel()
        setPressedFeedback(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let point = event.locationInWindow
        guard !PanelPreferences.isLocked else {
            setPressedFeedback(bounds.contains(convert(point, from: nil)))
            return
        }
        if abs(point.x - origin.x) > 4 || abs(point.y - origin.y) > 4 { isReordering = true }
        if isReordering {
            setPressedFeedback(false)
            alphaValue = 0.5
            autoscroll(with: event)
            onDragPreview?(point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressOrigin != nil else { return }
        defer { pressOrigin = nil; isReordering = false; alphaValue = 1 }
        if isReordering {
            setPressedFeedback(false)
            onDragFinished?(event.locationInWindow)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            openApplication()
        } else {
            setPressedFeedback(false)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu?.copy() as? NSMenu else { return }
        if includesApplicationMenu {
            menu.autoenablesItems = false
            menu.addItem(.separator())
            if let application = runningApplication {
                addApplicationItem("Show Windows", action: #selector(showWindows), to: menu)
                addApplicationItem(application.isHidden ? "Unhide" : "Hide", action: #selector(toggleHidden), to: menu)
                addApplicationItem("Show in Finder", action: #selector(revealApplication), to: menu)
                if application.bundleIdentifier != "com.apple.finder" {
                    menu.addItem(.separator())
                    addApplicationItem("Quit", action: #selector(quitApplication), to: menu)
                }
            } else {
                addApplicationItem("Open", action: #selector(openApplication), to: menu)
                addApplicationItem("Show in Finder", action: #selector(revealApplication), to: menu)
            }
        }
        PanelMenu.show(menu, from: self, event: event)
    }

    private func addApplicationItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func showWindows() {
        if let application = runningApplication { TaskbarWindowController.showWindows(of: application) }
        // A reopen event also handles running apps with no remaining windows.
        onOpen?()
    }

    @objc private func toggleHidden() {
        guard let application = runningApplication else { return }
        if application.isHidden { application.unhide(); application.activate() }
        else { application.hide() }
    }

    @objc private func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }

    @objc private func quitApplication() {
        guard let application = runningApplication, application.bundleIdentifier != "com.apple.finder" else { return }
        application.terminate()
    }

    private func setPressedFeedback(_ pressed: Bool) {
        pressedFeedback = pressed
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = pressed ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
            layer?.borderWidth = pressed ? 1 : 0
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setPressedFeedback(pressedFeedback)
    }

    @objc private func openApplication() {
        feedbackTask?.cancel()
        setPressedFeedback(true)
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.setPressedFeedback(false)
        }
        if let application = runningApplication,
           TaskbarWindowController.minimizeFocusedWindow(of: application) { return }
        onOpen?()
    }
}

@MainActor
private final class LauncherDropView: NSStackView {
    var onDrop: (([URL]) -> Bool)?
    private var dropHeight: NSLayoutConstraint!
    private let insertionMarker = CALayer()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        edgeInsets = NSEdgeInsetsZero
        wantsLayer = true
        layer?.cornerRadius = 6
        insertionMarker.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionMarker.isHidden = true
        layer?.addSublayer(insertionMarker)
        toolTip = "Drag apps from Finder or Taskbar to add shortcuts"
        registerForDraggedTypes([.fileURL])
        dropHeight = heightAnchor.constraint(equalToConstant: 52)
        dropHeight.isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func setHeight(_ height: CGFloat) { dropHeight.constant = height }

    func insertionIndex(at windowPoint: NSPoint) -> Int? {
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else { return nil }
        let buttons = arrangedSubviews.compactMap { $0 as? LauncherButton }
        return buttons.firstIndex { point.x < $0.frame.midX } ?? buttons.count
    }

    func previewReorder(at point: NSPoint) {
        guard let gap = insertionIndex(at: point) else { clearReorderPreview(); return }
        let buttons = arrangedSubviews.compactMap { $0 as? LauncherButton }
        let x = gap < buttons.count ? buttons[gap].frame.minX - 3 : (buttons.last?.frame.maxX ?? 3) + 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertionMarker.frame = CGRect(x: x, y: 4, width: 2, height: max(8, bounds.height - 8))
        insertionMarker.isHidden = false
        CATransaction.commit()
    }

    func clearReorderPreview() { insertionMarker.isHidden = true }

    private func applications(_ sender: any NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
              urls.allSatisfy({ LauncherStore.applicationURL($0) != nil }) else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = applications(sender) != nil && sender.draggingSourceOperationMask.contains(.copy)
        layer?.backgroundColor = accepted ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : nil
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { layer?.backgroundColor = nil }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { applications(sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        guard let urls = applications(sender) else { return false }
        return onDrop?(urls) ?? false
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { layer?.backgroundColor = nil }
}

@MainActor
extension LauncherPlugin {
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        LauncherSettings(configuration: configuration)
    }
}

@MainActor
private final class LauncherSettings: PluginSettingsContent {
    private let showRunningIndicator = NSButton(checkboxWithTitle: "Show running app indicator", target: nil, action: nil)

    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "How It Works", windowHeight: 430)
        showRunningIndicator.state = configuration.launcherShowRunningIndicator == true ? .on : .off
        showRunningIndicator.target = self
        showRunningIndicator.action = #selector(requestSave)
        options = [showRunningIndicator,
                   SettingsUI.help("Display a small dot below the icon while the app is running."),
                   SettingsUI.help("Drag apps from Finder or Taskbar into Launcher to add shortcuts."),
                   SettingsUI.help("Click to launch or drag to reorder. Drag outside the panel or right-click to remove a shortcut. The application itself is kept. Each Launcher has its own shortcuts."),
                   SettingsUI.help("App badges mirror the system Dock and require Accessibility access. Apps without an accessible Dock badge show no badge.")]
    }

    override func save(to config: inout PluginConfiguration) {
        config.launcherShowRunningIndicator = showRunningIndicator.state == .on
    }
}
