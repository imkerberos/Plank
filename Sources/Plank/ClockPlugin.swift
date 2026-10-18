import AppKit

@MainActor
final class ClockPlugin: PanelPlugin {
    let id: String
    private let display = ClockDisplayView()
    private var timer: Timer?
    var onWidthChanged: (() -> Void)?
    var view: NSView { display }

    init(id: String) { self.id = id }

    func setPanelHeight(_ height: CGFloat) { display.setHeight(height) }

    func refresh() {
        updateTime()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateTime() {
        if display.update(date: Date(), configuration: PluginPreferences.configuration(id)) {
            Task { @MainActor [weak self] in self?.onWidthChanged?() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

@MainActor
private final class ClockDisplayView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let formatter = DateFormatter()
    private var style = ClockStyle.digital
    private var time = ClockTime(hour: 0, minute: 0, second: 0)
    private var showSeconds = false
    private var use24HourTime = false
    private var panelHeight: CGFloat = 64
    private var displayWidth: NSLayoutConstraint!
    private var displayHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        displayWidth = widthAnchor.constraint(equalToConstant: 64)
        displayHeight = heightAnchor.constraint(equalToConstant: panelHeight)
        NSLayoutConstraint.activate([
            displayWidth, displayHeight,
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func setHeight(_ height: CGFloat) {
        panelHeight = height
        displayHeight.constant = height
        needsDisplay = true
    }

    @discardableResult func update(date: Date, configuration: PluginConfiguration?) -> Bool {
        style = configuration?.clockDisplayStyle ?? .digital
        showSeconds = configuration?.showSeconds ?? false
        use24HourTime = configuration?.use24HourTime ?? false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        time = ClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = use24HourTime ? (showSeconds ? "HH:mm:ss" : "HH:mm")
            : (showSeconds ? "h:mm:ss a" : "h:mm a")
        let text = formatter.string(from: date)
        label.stringValue = text
        label.isHidden = style != .digital
        let dateText = date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: "en_US")))
        toolTip = "\(dateText) · \(text)"
        setAccessibilityElement(style != .digital)
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(style.title) clock")
        setAccessibilityValue(text)
        let width: CGFloat
        switch style {
        case .digital: width = ceil(label.intrinsicContentSize.width)
        case .analog: width = panelHeight
        case .binary:
            let columns = showSeconds ? 6 : 4
            width = 12 + CGFloat(columns) * dotPitch + CGFloat(columns / 2 - 1) * 5
        }
        let changed = abs(displayWidth.constant - width) > 0.5
        displayWidth.constant = width
        needsDisplay = true
        return changed
    }

    private var dotPitch: CGFloat { min(12, max(4, (panelHeight - 14) / 4)) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch style {
        case .digital: break
        case .analog: drawAnalog()
        case .binary: drawBinary()
        }
    }

    private func drawAnalog() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(8, min(bounds.width, bounds.height) / 2 - 4)
        let face = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
        face.fill()
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        face.lineWidth = 1
        face.stroke()
        func point(_ turn: Double, _ length: CGFloat) -> NSPoint {
            let angle = turn * .pi * 2
            return NSPoint(x: center.x + sin(angle) * length, y: center.y + cos(angle) * length)
        }
        for tick in 0..<12 {
            let line = NSBezierPath()
            line.move(to: point(Double(tick) / 12, radius - 2))
            line.line(to: point(Double(tick) / 12, radius - (tick % 3 == 0 ? 5 : 3)))
            line.lineWidth = tick % 3 == 0 ? 1.5 : 1
            line.stroke()
        }
        func hand(_ turn: Double, length: CGFloat, width: CGFloat, color: NSColor) {
            let line = NSBezierPath()
            line.move(to: center)
            line.line(to: point(turn, length))
            line.lineWidth = width
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }
        let seconds = showSeconds ? Double(time.second) / 60 : 0
        let minutes = (Double(time.minute) + seconds) / 60
        hand((Double(time.hour % 12) + minutes) / 12, length: radius * 0.5, width: 2.5, color: .labelColor)
        hand(minutes, length: radius * 0.76, width: 1.8, color: .labelColor)
        if showSeconds { hand(Double(time.second) / 60, length: radius * 0.85, width: 1, color: .controlAccentColor) }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
    }

    private func drawBinary() {
        let digits = time.binaryDigits(use24HourTime: use24HourTime, showSeconds: showSeconds)
        let pitch = dotPitch
        let size = max(2, pitch - 2)
        let top = bounds.midY + 2 * pitch + 3
        for (column, digit) in digits.enumerated() {
            let x = 6 + CGFloat(column) * pitch + CGFloat(column / 2) * 5
            for row in 0..<4 {
                let on = ClockTime.bitIsSet(digit, row: row)
                (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.13)).setFill()
                let y = top - CGFloat(row + 1) * pitch
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: size, height: size), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        for group in 0..<(digits.count / 2) {
            let text = ["H", "M", "S"][group] as NSString
            let x = 6 + CGFloat(group) * (2 * pitch + 5) + pitch - text.size(withAttributes: attributes).width / 2
            text.draw(at: NSPoint(x: x, y: max(0, top - 4 * pitch - 10)), withAttributes: attributes)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { PanelMenu.show(menu, from: self, event: event) }
        else { super.rightMouseDown(with: event) }
    }
}

@MainActor
extension ClockPlugin {
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        ClockSettings(configuration: configuration)
    }
}

@MainActor
private final class ClockSettings: PluginSettingsContent {
    private let seconds = NSButton(checkboxWithTitle: "Show Seconds", target: nil, action: nil)
    private let use24HourTime = NSButton(checkboxWithTitle: "Use 24-Hour Time", target: nil, action: nil)
    private let clockStyle = NSPopUpButton()
    private let clockHint = SettingsUI.help("")

    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "Clock Display", windowHeight: 520)
        clockStyle.addItems(withTitles: ClockStyle.allCases.map(\.title))
        clockStyle.selectItem(at: ClockStyle.allCases.firstIndex(of: configuration.clockDisplayStyle) ?? 0)
        clockStyle.target = self
        clockStyle.action = #selector(requestSave)
        clockStyle.widthAnchor.constraint(equalToConstant: 160).isActive = true
        clockStyle.setAccessibilityLabel("Clock display style")
        use24HourTime.state = configuration.use24HourTime == true ? .on : .off
        use24HourTime.target = self
        use24HourTime.action = #selector(requestSave)
        seconds.state = configuration.showSeconds ? .on : .off
        seconds.target = self
        seconds.action = #selector(requestSave)
        options = [SettingsUI.row("Style", control: clockStyle), use24HourTime, seconds, clockHint,
                   SettingsUI.help("Uses your Mac’s current time zone. Hover over the clock to see the date and time.")]
    }

    override func updateControls() {
        let selected = ClockStyle.allCases.indices.contains(clockStyle.indexOfSelectedItem)
            ? ClockStyle.allCases[clockStyle.indexOfSelectedItem] : .digital
        use24HourTime.isEnabled = selected != .analog
        switch selected {
        case .digital: clockHint.stringValue = "Display the time as text in 12-hour or 24-hour format."
        case .analog: clockHint.stringValue = "A classic 12-hour dial. Show Seconds adds a second hand."
        case .binary: clockHint.stringValue = "Each column encodes one decimal digit. Read lit dots from top to bottom as 8, 4, 2, 1. Groups are hours, minutes, and optional seconds."
        }
    }

    override func save(to config: inout PluginConfiguration) {
        if ClockStyle.allCases.indices.contains(clockStyle.indexOfSelectedItem) {
            config.clockStyle = ClockStyle.allCases[clockStyle.indexOfSelectedItem].rawValue
        }
        config.showSeconds = seconds.state == .on
        config.use24HourTime = use24HourTime.state == .on
    }
}
