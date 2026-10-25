import AppKit

/// Route plugin button context menus through the same presenter as panel handles.
@MainActor
class PanelMenuButton: NSButton {
    override func rightMouseDown(with event: NSEvent) {
        var source: NSView? = self
        while let view = source {
            if let menu = view.menu {
                PanelMenu.show(menu, from: self, event: event)
                return
            }
            source = view.superview
        }
        super.rightMouseDown(with: event)
    }
}

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
        PanelPopover.show(popover, from: view, event: event)
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
                let prefix = item.state == .on ? "✓  " : item.image == nil ? "    " : ""
                let button = MenuActionButton(title: prefix + item.title,
                                              target: self, action: #selector(selectItem(_:)))
                if let image = item.image?.copy() as? NSImage {
                    image.size = NSSize(width: 18, height: 18)
                    button.image = image
                    button.imagePosition = .imageLeading
                    button.imageScaling = .scaleProportionallyDown
                }
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
}

@MainActor
final class PanelContentView: NSView {
    let stack = PanelStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalTo: heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }
}

@MainActor
final class PanelStackView: NSStackView {
    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }
}

/// Shared presentation for panel menus and plugin detail popovers.
@MainActor
enum PanelPopover {
    static func insetX(_ x: CGFloat, in frame: NSRect, margin: CGFloat = 32) -> CGFloat {
        let inset = min(margin, max(0, (frame.width - 1) / 2))
        return min(max(x, frame.minX + inset), frame.maxX - inset - 1)
    }

    static func show(_ popover: NSPopover, from view: NSView, event: NSEvent? = nil) {
        guard let window = view.window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let source = view.convert(view.bounds, to: content)
        var x = source.midX
        if let event, event.window === window {
            x = content.convert(event.locationInWindow, from: nil).x
        }
        // Leave room for the native arrow and rounded corner at screen edges.
        // Use the whole panel as the anchor host so narrow edge handles can
        // shift inward without AppKit clipping away the arrow.
        if let screen = window.screen {
            let visible = content.convert(window.convertFromScreen(screen.visibleFrame), from: nil)
            x = insetX(x, in: visible)
        }
        x = min(max(x, content.bounds.minX), content.bounds.maxX - 1)
        let y = content.isFlipped ? content.bounds.minY : content.bounds.maxY - 1
        let anchor = NSRect(x: x, y: y, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: content, preferredEdge: .maxY)
    }
}

@MainActor
final class PanelPopoverBackground: NSVisualEffectView {
    var arrowX: CGFloat = 32
    var pointsDown = true

    override func layout() {
        super.layout()
        let arrowHeight: CGFloat = 10
        let body = NSRect(x: bounds.minX,
                          y: bounds.minY + (pointsDown ? arrowHeight : 0),
                          width: bounds.width, height: max(0, bounds.height - arrowHeight))
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: 12, cornerHeight: 12)
        let x = PanelPopover.insetX(arrowX, in: bounds)
        let base = pointsDown ? body.minY : body.maxY
        let tip = pointsDown ? bounds.minY : bounds.maxY
        path.move(to: NSPoint(x: x - 10, y: base))
        path.addLine(to: NSPoint(x: x, y: tip))
        path.addLine(to: NSPoint(x: x + 10, y: base))
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        layer?.mask = mask
    }
}
