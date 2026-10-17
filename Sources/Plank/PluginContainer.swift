import AppKit

@MainActor
final class PluginContainer: NSStackView {
    let pluginID: String
    var isMoving = false {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.borderWidth = isMoving ? 2 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            toolTip = isMoving ? "Drag to a new position and release to finish; right-click to cancel" : nil
            resetCursorRects()
        }
    }
    var onDrop: ((NSPoint) -> Void)?

    init(id: String, views: [NSView]) {
        pluginID = id
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        for view in views { addArrangedSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Moving captures left-button drags, while right-clicks keep their
        // original target (especially taskbar application context menus).
        return isMoving && hit != nil && NSApp.currentEvent?.type != .rightMouseDown ? self : hit
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isMoving { addCursorRect(bounds, cursor: .openHand) }
    }

    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        guard isMoving else { super.mouseDown(with: event); return }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        if dragging { autoscroll(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDrop?(event.locationInWindow)
    }

}

/// A compact hit area around a thin line, without a separate handle.
@MainActor
final class SeparatorView: NSView {
    private var showsLine = true
    private var widthConstraint: NSLayoutConstraint!
    private var separatorHeight: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 6)
        separatorHeight = heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            widthConstraint,
            separatorHeight
        ])
        toolTip = "Separator · Right-click to open menu"
        setAccessibilityLabel("Separator menu")
    }

    func setPanelHeight(_ height: CGFloat) {
        separatorHeight.constant = height
        needsDisplay = true
    }

    func configure(style: String, width: Double, expand: Bool) {
        let space = style == "space"
        showsLine = !space
        needsDisplay = true
        widthConstraint.constant = space ? CGFloat(min(400, max(8, width))) : 6
        toolTip = space ? "Space · Right-click to open menu" : "Separator · Right-click to open menu"
    }

    func setExpandedWidth(_ width: CGFloat) {
        widthConstraint.constant = max(8, width)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsLine else { return }
        // Draw explicitly: NSBox.separator can lose its line when constrained
        // to a very narrow frame. Align the stroke to physical pixels.
        let scale = window?.backingScaleFactor ?? 1
        let x = floor((bounds.midX - 0.5) * scale) / scale
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        NSRect(x: x, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return }
        PanelMenu.show(menu, from: self, event: event)
    }
}
