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
        if paths.isEmpty {
            let hint = NSTextField(labelWithString: "＋ Drop Apps Here")
            hint.textColor = .secondaryLabelColor
            hint.setAccessibilityLabel("Drag apps here from Finder or Taskbar to add shortcuts")
            dropView.addArrangedSubview(hint)
        }
        for path in paths {
            let button = LauncherButton(path: path, size: buttonSize)
            button.onOpen = { [weak self] in self?.openApplication(path) }
            button.onDragPreview = { [weak self] point in self?.dropView.previewReorder(at: point) }
            button.onDragFinished = { [weak self] point in
                guard let self else { return }
                self.dropView.clearReorderPreview()
                guard !PanelPreferences.isLocked, let point,
                      let gap = self.dropView.insertionIndex(at: point),
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
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.showError(message) }
            }
        }
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
    var onOpen: (() -> Void)?
    var onDragPreview: ((NSPoint) -> Void)?
    var onDragFinished: ((NSPoint?) -> Void)?
    private var pressOrigin: NSPoint?
    private var isReordering = false
    private var feedbackTask: Task<Void, Never>?

    init(path: String, size: CGFloat) {
        super.init(frame: .zero)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: max(24, size - 8), height: max(24, size - 8))
        image = icon
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        wantsLayer = true
        let name = FileManager.default.displayName(atPath: path)
        toolTip = "\(name) · Drag to reorder; right-click to remove shortcut"
        setAccessibilityLabel("Launch \(name)")
        target = self
        action = #selector(openApplication)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { nil }
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
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }

    private func setPressedFeedback(_ pressed: Bool) {
        layer?.backgroundColor = pressed ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        layer?.borderWidth = pressed ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    }

    @objc private func openApplication() {
        feedbackTask?.cancel()
        setPressedFeedback(true)
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.setPressedFeedback(false)
        }
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
