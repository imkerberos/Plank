import AppKit

/// A compact menu presenter that is not confined to the nonactivating panel's
/// short window bounds. NSMenu remains the action/checkmark model.
@MainActor
enum PanelMenu {
    private static var current: NSPopover?

    static func show(_ menu: NSMenu, from view: NSView, event: NSEvent? = nil) {
        guard view.window != nil else { return }
        current?.performClose(nil)
        menu.update()
        let controller = PanelMenuController(menu: menu)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        current = popover
        controller.onClose = { [weak popover] in popover?.performClose(nil) }
        var anchor = view.bounds
        if let event {
            let point = view.convert(event.locationInWindow, from: nil)
            anchor = NSRect(x: max(view.bounds.minX, min(point.x, view.bounds.maxX - 1)),
                            y: view.bounds.midY, width: 1, height: 1)
        }
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        NSApp.activate(ignoringOtherApps: true)
        controller.focusMenu()
    }
}

@MainActor
private final class PanelMenuController: NSViewController {
    let menuModel: NSMenu
    var onClose: (() -> Void)?
    private var buttons: [MenuActionButton] = []
    private var selectedIndex = -1

    init(menu: NSMenu) {
        self.menuModel = menu
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = MenuKeyboardView()
        root.onKey = { [weak self] event in self?.handleKey(event) }
        view = root
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let width = max(220, min(360, menuModel.size.width + 32))
        var height: CGFloat = 16
        for (index, item) in menuModel.items.enumerated() {
            if item.isSeparatorItem {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                line.heightAnchor.constraint(equalToConstant: 7).isActive = true
                height += 9
            } else {
                let button = MenuActionButton(title: (item.state == .on ? "✓  " : "    ") + item.title,
                                              target: self, action: #selector(selectItem(_:)))
                button.tag = index
                button.isEnabled = item.isEnabled && item.action != nil
                button.alignment = .left
                button.isBordered = false
                button.font = .menuFont(ofSize: 13)
                button.setAccessibilityLabel(item.title)
                stack.addArrangedSubview(button)
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    button.heightAnchor.constraint(equalToConstant: 28)
                ])
                if button.isEnabled { buttons.append(button) }
                height += 30
            }
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        preferredContentSize = NSSize(width: width, height: height)
        view.setFrameSize(preferredContentSize)
    }

    func focusMenu() { view.window?.makeKey(); view.window?.makeFirstResponder(view) }

    private func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()
        case 125, 126:
            guard !buttons.isEmpty else { return }
            if selectedIndex < 0 { selectedIndex = event.keyCode == 125 ? 0 : buttons.count - 1 }
            else { selectedIndex = (selectedIndex + (event.keyCode == 125 ? 1 : buttons.count - 1)) % buttons.count }
            for (index, button) in buttons.enumerated() { button.showHighlight(index == selectedIndex) }
        case 36, 76:
            if buttons.indices.contains(selectedIndex) { selectItem(buttons[selectedIndex]) }
        default: break
        }
    }

    @objc private func selectItem(_ sender: NSButton) {
        let item = menuModel.items[sender.tag]
        guard item.isEnabled, let action = item.action else { return }
        onClose?()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

@MainActor
private final class MenuKeyboardView: NSView {
    var onKey: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

@MainActor
private final class MenuActionButton: NSButton {
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    func showHighlight(_ highlighted: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = highlighted && isEnabled ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor : nil
    }
    override func mouseEntered(with event: NSEvent) { showHighlight(true) }
    override func mouseExited(with event: NSEvent) { showHighlight(false) }
}

@MainActor
final class PanelBackgroundView: NSVisualEffectView {
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        // The panel never becomes key. Cursor rectangles alone therefore do
        // not reliably replace the cursor left behind by another application.
        // activeAlways does not deliver cursorUpdate, so use entry/move events.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { updatePointer(with: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(with: event) }

    private func updatePointer(with event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        var target = hitTest(point)
        while let view = target {
            if let container = view as? PluginContainer, container.isMoving {
                NSCursor.openHand.set()
                return
            }
            target = view.superview
        }
        NSCursor.arrow.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }

    // The panel is a fixed surface. Do not let a mouse wheel move its content
    // horizontally or vertically when plugin content exceeds the panel width.
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor
final class PanelScrollView: NSScrollView {
    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }

    // Keep scroll views available for layout overflow, but never scroll the
    // panel in response to mouse-wheel or trackpad scrolling.
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor
final class PanelStackView: NSStackView {
    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }
}
