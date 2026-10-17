import AppKit

@MainActor
final class AppBadgeView: NSView {
    private let applicationPath: String
    private let diameter: CGFloat
    private var content: AppBadgeContent?
    private var baseHelp: String?

    init(applicationURL: URL, iconSize: CGFloat) {
        applicationPath = applicationURL.standardizedFileURL.resolvingSymlinksInPath().path
        diameter = min(18, max(14, iconSize * 0.32))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .plankBadgesChanged, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refresh()
    }

    override var intrinsicContentSize: NSSize {
        guard let content else { return NSSize(width: diameter, height: diameter) }
        if content.displayText.isEmpty { return NSSize(width: 8, height: 8) }
        let text = (content.displayText as NSString).size(withAttributes: [.font: font])
        return NSSize(width: max(diameter, ceil(text.width) + 7), height: diameter)
    }
    private var font: NSFont { .systemFont(ofSize: max(9, diameter - 5), weight: .semibold) }

    @objc private func refresh() {
        content = DockBadgeCenter.shared.badge(for: applicationPath)
        isHidden = content == nil
        toolTip = content?.label
        setAccessibilityElement(content != nil)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("App badge")
        setAccessibilityValue(content?.label)
        if let button = superview as? NSButton {
            button.setAccessibilityHelp(content.map { "\(baseHelp ?? "") · Badge: \($0.label)" } ?? baseHelp)
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.systemRed.setFill()
        shape.fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        guard !content.displayText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = content.displayText as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    static func attach(to button: NSButton, applicationURL: URL?, iconSize: CGFloat,
                       buttonSize: CGFloat, iconView: NSView? = nil) {
        guard let applicationURL else { return }
        let badge = AppBadgeView(applicationURL: applicationURL, iconSize: iconSize)
        badge.baseHelp = button.toolTip
        button.addSubview(badge)
        if let iconView {
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -3),
                badge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -3)
            ])
        } else {
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: max(1, (buttonSize - iconSize) / 2 - 3)),
                badge.topAnchor.constraint(equalTo: button.topAnchor, constant: max(1, (buttonSize - iconSize) / 2 - 3))
            ])
        }
    }
}
