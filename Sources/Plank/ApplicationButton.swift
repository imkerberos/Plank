import AppKit

@MainActor
final class ApplicationButton: NSButton, NSDraggingSource {
    private let application: NSRunningApplication
    private var pressOrigin: NSPoint?
    private var isDraggingApplication = false

    init(application: NSRunningApplication, showsTitle: Bool = false, maximumWidth: Double = 180, buttonSize: CGFloat = 44) {
        self.application = application
        super.init(frame: .zero)
        let name = application.localizedName ?? "Application"
        isBordered = false
        toolTip = "\(name) · Drag to Launcher to add a shortcut"
        setAccessibilityLabel(name)
        target = self
        action = #selector(toggleApplication)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.backgroundColor = application.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : (showsTitle ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil)

        let buttonWidth: CGFloat
        if showsTitle {
            title = ""
            let icon = NSImageView()
            icon.image = application.icon
            icon.imageScaling = .scaleProportionallyDown
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for view in [icon, label] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            let iconSize = min(24, buttonSize - 8)
            let naturalWidth = ceil((name as NSString).size(withAttributes: [.font: label.font!]).width) + 52
            let limit = maximumWidth.isFinite ? min(400, max(80, maximumWidth)) : 180
            buttonWidth = min(CGFloat(limit), max(80, naturalWidth))
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: iconSize),
                icon.heightAnchor.constraint(equalToConstant: iconSize),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            if let icon = application.icon?.copy() as? NSImage {
                icon.size = NSSize(width: max(24, buttonSize - 20), height: max(24, buttonSize - 20))
                image = icon
            }
            imagePosition = .imageOnly
            imageScaling = .scaleProportionallyDown
            buttonWidth = buttonSize
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: buttonWidth),
            heightAnchor.constraint(equalToConstant: buttonSize)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        isDraggingApplication = false
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingApplication, let origin = pressOrigin else { return }
        let point = event.locationInWindow
        guard abs(point.x - origin.x) > 4 || abs(point.y - origin.y) > 4 else { return }
        // Export the same file URL as Finder so every Launcher uses its existing
        // validation, duplicate detection and persistence path.
        guard let url = application.bundleURL else { return }
        isDraggingApplication = true
        highlight(false)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = min(bounds.width, bounds.height)
        let location = convert(point, from: nil)
        item.setDraggingFrame(NSRect(x: location.x - size / 2, y: location.y - size / 2,
                                     width: size, height: size), contents: application.icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldOpen = pressOrigin != nil && !isDraggingApplication
            && bounds.contains(convert(event.locationInWindow, from: nil))
        pressOrigin = nil
        highlight(false)
        if shouldOpen { toggleApplication() }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        pressOrigin = nil
        isDraggingApplication = false
        highlight(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = menu.addItem(withTitle: application.localizedName ?? "Application", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(.separator())
        addItem("Show", action: #selector(activateApplication), to: menu)
        addItem(application.isHidden ? "Unhide" : "Hide", action: #selector(toggleHidden), to: menu)
        let reveal = addItem("Show in Finder", action: #selector(revealApplication), to: menu)
        reveal.isEnabled = application.bundleURL != nil
        menu.addItem(.separator())
        // Finder manages the desktop and should not offer a normal Quit action.
        if application.bundleIdentifier != "com.apple.finder" {
            addItem("Quit", action: #selector(quitApplication), to: menu)
        }
        for item in menu.items where item.action != nil && application.isTerminated { item.isEnabled = false }
        PanelMenu.show(menu, from: self, event: event)
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleHidden() {
        if application.isHidden { application.unhide(); application.activate() }
        else { application.hide() }
    }

    @objc private func revealApplication() {
        if let url = application.bundleURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func quitApplication() { application.terminate() }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        alphaValue = flag ? 0.65 : 1
    }

    @objc private func toggleApplication() {
        if TaskbarWindowController.minimizeFocusedWindow(of: application) { return }
        activateApplication()
    }

    @objc private func activateApplication() {
        guard let url = application.bundleURL else { application.activate(); return }
        // Launch Services sends the running app its standard reopen event.
        // The app decides whether to restore an existing window or create one.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            if error != nil {
                Task { @MainActor [weak self] in self?.application.activate() }
            }
        }
    }
}
