import AppKit
import IOKit.pwr_mgt

private enum CaffeinateDuration: Int, CaseIterable {
    case off = 0
    case minutes15 = 15
    case minutes30 = 30
    case minutes45 = 45
    case hour1 = 60
    case hour2 = 120
    case hour3 = 180
    case forever = -1

    var title: String {
        switch self {
        case .off: "Off"
        case .minutes15: "15 minutes"
        case .minutes30: "30 minutes"
        case .minutes45: "45 minutes"
        case .hour1: "1 hour"
        case .hour2: "2 hours"
        case .hour3: "3 hours"
        case .forever: "Forever"
        }
    }
}

@MainActor
final class CaffeinatePlugin: NSObject, PanelPlugin {
    let id: String
    var onWidthChanged: (() -> Void)?
    private let button = CaffeinateButton()
    private var buttonWidth: NSLayoutConstraint!
    private var buttonHeight: NSLayoutConstraint!
    private var iconSize: CGFloat = 20
    private var duration: CaffeinateDuration = .off
    private var endDate: Date?
    private var assertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?
    private var userActivityAssertionID: IOPMAssertionID?
    private var preventsScreenLock = false
    private var timer: Timer?
    private var userActivityTimer: Timer?
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.target = self
        button.action = #selector(showDurationMenu)
        button.translatesAutoresizingMaskIntoConstraints = false
        buttonWidth = button.widthAnchor.constraint(equalToConstant: 44)
        buttonHeight = button.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([buttonWidth, buttonHeight])
        updateDisplay()
    }

    func setPanelHeight(_ height: CGFloat) {
        buttonHeight.constant = PanelMetrics.buttonSize(for: height)
        iconSize = max(12, min(26, height - 18))
        updateDisplay(notifyWidthChange: false)
    }

    func refresh() {
        updateDisplay()
        guard duration != .off, timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCountdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        userActivityTimer?.invalidate()
        userActivityTimer = nil
        releaseAssertion()
        releaseDisplayAssertion()
        releaseUserActivityAssertion()
        duration = .off
        endDate = nil
        preventsScreenLock = false
        updateDisplay(notifyWidthChange: false)
    }

    func addMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        addPreventScreenLockItem(to: menu)
        menu.addItem(.separator())
        addDurationItems(to: menu)
    }

    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        let settings = PluginSettingsContent(sectionTitle: "How It Works", windowHeight: 390)
        settings.options = [
            SettingsUI.help("Click the coffee icon to choose how long to keep your Mac awake. The countdown appears above the icon."),
            SettingsUI.help("Prevent Screen Lock keeps the display awake and avoids automatic idle locking independently of the duration choices. It stays active until toggled off, the plugin is disabled or removed, or Plank quits. Manual locking remains available."),
            SettingsUI.help("Forever keeps the Mac awake until you turn this plugin off, disable or remove it, or quit Plank."),
            SettingsUI.help("This prevents sleep caused by inactivity. It does not prevent sleep when you close a Mac laptop’s lid or choose Sleep from macOS.")
        ]
        return settings
    }

    @objc private func showDurationMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addPreventScreenLockItem(to: menu)
        menu.addItem(.separator())
        addDurationItems(to: menu)
        let event = NSApp.currentEvent.flatMap {
            $0.type == .leftMouseUp || $0.type == .leftMouseDown ? $0 : nil
        }
        PanelMenu.show(menu, from: button, event: event)
    }

    private func addPreventScreenLockItem(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Prevent Screen Lock", action: #selector(togglePreventScreenLock), keyEquivalent: "")
        item.target = self
        item.state = preventsScreenLock ? .on : .off
    }

    private func addDurationItems(to menu: NSMenu) {
        for option in CaffeinateDuration.allCases {
            let item = menu.addItem(withTitle: option.title, action: #selector(selectDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == duration ? .on : .off
        }
    }

    @objc private func togglePreventScreenLock() {
        let shouldPrevent = !preventsScreenLock
        if shouldPrevent {
            var newAssertion: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Plank Prevent Screen Lock" as CFString,
                &newAssertion
            )
            guard result == kIOReturnSuccess else {
                showError("macOS could not prevent idle screen locking (error \(result)).")
                return
            }

            var userActivityAssertion: IOPMAssertionID = 0
            let activityResult = IOPMAssertionDeclareUserActivity(
                "Plank Prevent Screen Lock" as CFString,
                kIOPMUserActiveLocal,
                &userActivityAssertion
            )
            guard activityResult == kIOReturnSuccess else {
                IOPMAssertionRelease(newAssertion)
                showError("macOS could not reset the idle activity timer (error \(activityResult)).")
                return
            }

            displayAssertionID = newAssertion
            userActivityAssertionID = userActivityAssertion
            preventsScreenLock = true
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.declareUserActivity() }
            }
            RunLoop.main.add(timer, forMode: .common)
            userActivityTimer = timer
        } else {
            userActivityTimer?.invalidate()
            userActivityTimer = nil
            releaseDisplayAssertion()
            releaseUserActivityAssertion()
            preventsScreenLock = false
        }
        updateDisplay()
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let selection = CaffeinateDuration(rawValue: rawValue) else { return }
        setDuration(selection)
    }

    private func setDuration(_ selection: CaffeinateDuration) {
        if selection == .off {
            releaseAssertion()
            duration = .off
            endDate = nil
            timer?.invalidate()
            timer = nil
            updateDisplay()
            return
        }

        if assertionID == nil {
            var newAssertion: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Plank Caffeinate" as CFString,
                &newAssertion
            )
            guard result == kIOReturnSuccess else {
                showError("macOS could not create a keep-awake request (error \(result)).")
                return
            }
            assertionID = newAssertion
        }

        duration = selection
        endDate = selection == .forever ? nil : Date().addingTimeInterval(TimeInterval(selection.rawValue * 60))
        updateDisplay()
        if timer == nil { refresh() }
    }

    private func updateCountdown() {
        guard duration != .off else { return }
        if let endDate, endDate <= Date() {
            setDuration(.off)
            return
        }
        updateDisplay()
    }

    private func updateDisplay(notifyWidthChange: Bool = true) {
        let active = duration != .off || preventsScreenLock
        let symbol = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let tint: NSColor = duration == .forever ? .systemOrange : (active ? .controlAccentColor : .tertiaryLabelColor)
        let displayText = countdownText
        let status = duration == .forever ? "Forever" : (duration == .off && preventsScreenLock ? "Preventing Screen Lock" : displayText)
        let lockStatus = preventsScreenLock ? " · Prevent Screen Lock" : ""
        button.toolTip = active ? "Keep Mac Awake · \(status)\(lockStatus) · Click to change"
            : "Keep Mac Awake · Off · Click to choose a duration"
        button.setAccessibilityLabel("Keep Mac Awake")
        button.setAccessibilityValue(active ? status : "Off")

        let titleFont = NSFont.monospacedDigitSystemFont(ofSize: buttonHeight.constant < 40 ? 9 : 11, weight: .medium)
        let textWidth: CGFloat
        if displayText.isEmpty {
            textWidth = 0
        } else {
            textWidth = ceil((displayText as NSString).size(withAttributes: [.font: titleFont]).width)
        }
        let contentWidth = max(iconSize, textWidth) + 12
        let width = max(buttonHeight.constant, ceil(contentWidth))
        let changed = abs(buttonWidth.constant - width) > 0.5
        buttonWidth.constant = width
        button.updateDisplay(text: displayText, symbol: symbol, tint: tint, iconSize: iconSize, font: titleFont)
        if changed && notifyWidthChange { onWidthChanged?() }
    }

    private var countdownText: String {
        guard duration != .off else { return "" }
        guard let endDate else { return "∞" }
        let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func releaseAssertion() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    private func releaseDisplayAssertion() {
        guard let displayAssertionID else { return }
        IOPMAssertionRelease(displayAssertionID)
        self.displayAssertionID = nil
    }

    private func declareUserActivity() {
        guard preventsScreenLock else { return }
        var assertionID = userActivityAssertionID ?? 0
        let result = IOPMAssertionDeclareUserActivity(
            "Plank Prevent Screen Lock" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        if result == kIOReturnSuccess { userActivityAssertionID = assertionID }
    }

    private func releaseUserActivityAssertion() {
        guard let userActivityAssertionID else { return }
        IOPMAssertionRelease(userActivityAssertionID)
        self.userActivityAssertionID = nil
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unable to Keep Mac Awake"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
private final class CaffeinateButton: PanelMenuButton {
    private let contentStack = NSStackView()
    private let countdownLabel = NSTextField(labelWithString: "")
    private let cupImageView = NSImageView()
    private var cupWidth: NSLayoutConstraint!
    private var cupHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        image = nil
        countdownLabel.alignment = .center
        countdownLabel.lineBreakMode = .byClipping
        countdownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countdownLabel.isHidden = true
        cupImageView.imageScaling = .scaleProportionallyDown

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 1
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(countdownLabel)
        contentStack.addArrangedSubview(cupImageView)
        addSubview(contentStack)
        cupWidth = cupImageView.widthAnchor.constraint(equalToConstant: 20)
        cupHeight = cupImageView.heightAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            cupWidth, cupHeight,
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 1),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -1)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func updateDisplay(text: String, symbol: String, tint: NSColor, iconSize: CGFloat, font: NSFont) {
        countdownLabel.stringValue = text
        countdownLabel.font = font
        countdownLabel.textColor = tint
        countdownLabel.isHidden = text.isEmpty
        cupImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Keep Mac Awake")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular))
        cupImageView.contentTintColor = tint
        cupWidth.constant = iconSize
        cupHeight.constant = iconSize
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
