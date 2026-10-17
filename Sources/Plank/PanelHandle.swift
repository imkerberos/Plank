import AppKit

/// A visible, keyboard-accessible menu target, separate from plugin content.
@MainActor
final class PanelHandle: NSButton {
    private var handleHeight: NSLayoutConstraint!
    init(title: String, menu: NSMenu, isPanel: Bool = false) {
        super.init(frame: .zero)
        self.menu = menu
        self.title = ""
        let dots = NSImage(size: NSSize(width: 12, height: 24), flipped: false) { _ in
            NSColor.labelColor.setFill()
            for y in [4.0, 11.0, 18.0] {
                NSBezierPath(ovalIn: NSRect(x: 4.5, y: y, width: 3, height: 3)).fill()
            }
            return true
        }
        dots.isTemplate = true
        image = dots
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = "\(title) · Right-click to open menu"
        setAccessibilityLabel("\(title) Menu")
        target = self
        action = #selector(openMenu)
        translatesAutoresizingMaskIntoConstraints = false
        handleHeight = heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: isPanel ? 24 : 18),
            handleHeight
        ])
    }

    func setPanelHeight(_ height: CGFloat) { handleHeight.constant = height }

    required init?(coder: NSCoder) { nil }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return }
        PanelMenu.show(menu, from: self, event: event)
    }

    @objc private func openMenu() {
        if let menu { PanelMenu.show(menu, from: self) }
    }
}
