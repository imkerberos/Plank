import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void
    private let heightPreset = NSPopUpButton()
    private let customHeight = NSTextField()
    private let onHeightChanged: () -> Void
    private let hideDock = NSButton(checkboxWithTitle: "Hide System Dock", target: nil, action: nil)
    private let dockStatus = NSTextField(wrappingLabelWithString: "")
    private let onDockChanged: (Bool) -> (Bool, String)
    private let onShowPlugins: () -> Void
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")

    init(percentage: Double, onChange: @escaping (Double) -> Void, onHeightChanged: @escaping () -> Void, dockEnabled: Bool, dockStatusText: String, onDockChanged: @escaping (Bool) -> (Bool, String), onShowPlugins: @escaping () -> Void) {
        self.onDockChanged = onDockChanged
        self.onHeightChanged = onHeightChanged
        self.onShowPlugins = onShowPlugins
        self.onChange = onChange
        slider = NSSlider(value: percentage, minValue: 10, maxValue: 100, target: nil, action: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 740),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Plank Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        slider.target = self
        slider.action = #selector(widthChanged)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Panel width percentage")
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .controlAccentColor
        valueLabel.stringValue = "\(Int(percentage))%"

        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let hint = NSTextField(wrappingLabelWithString: "At 100%, the panel fills the entire screen width.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        heightPreset.addItems(withTitles: PanelHeightPreset.allCases.map(\.title))
        heightPreset.selectItem(at: PanelHeightPreset.allCases.firstIndex(of: PanelPreferences.heightPreset) ?? 1)
        heightPreset.target = self
        heightPreset.action = #selector(heightChanged)
        customHeight.doubleValue = PanelPreferences.customHeight
        customHeight.isEnabled = PanelPreferences.heightPreset == .custom
        customHeight.target = self
        customHeight.action = #selector(heightChanged)
        customHeight.setAccessibilityLabel("Custom panel height, 32 to 128 pt")
        let heightRow = NSStackView(views: [heightPreset, customHeight, NSTextField(labelWithString: "pt (32–128)")])
        heightRow.spacing = 12
        customHeight.widthAnchor.constraint(equalToConstant: 64).isActive = true
        hideDock.state = dockEnabled ? .on : .off
        hideDock.target = self
        hideDock.action = #selector(dockChanged)
        dockStatus.stringValue = dockStatusText
        dockStatus.textColor = .secondaryLabelColor
        dockStatus.font = .systemFont(ofSize: 12)
        let dockHint = NSTextField(wrappingLabelWithString: "Keep maximized windows clear of Plank. The Dock is restored when this is turned off or Plank quits. Requires Accessibility access.")
        dockHint.textColor = .secondaryLabelColor
        dockHint.font = .systemFont(ofSize: 11)
        let permission = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openAccessibilitySettings))
        launchAtLogin.target = self
        launchAtLogin.action = #selector(loginChanged)
        loginStatus.textColor = .secondaryLabelColor
        loginStatus.font = .systemFont(ofSize: 12)
        reloadLoginState()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadLoginState),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        let loginSettings = NSButton(title: "Open Login Items Settings…", target: self, action: #selector(openLoginSettings))
        let widthGroup = SettingsUI.vertical([SettingsUI.row("Width", control: valueLabel), slider, hint], spacing: 8)
        let display = SettingsUI.card("Appearance", views: [widthGroup,
            SettingsUI.row("Height", control: heightRow)])
        let startup = SettingsUI.card("Startup", views: [launchAtLogin, loginStatus, SettingsUI.row("", control: loginSettings)])
        let dock = SettingsUI.card("System Dock", views: [hideDock, dockHint, dockStatus, SettingsUI.row("", control: permission)])
        let plugins = SettingsUI.card("Plugins", views: [
            SettingsUI.help("Add plugins, change their order, and customize each one."),
            SettingsUI.row("", control: NSButton(title: "Manage Plugins…", target: self, action: #selector(showPlugins)))])
        SettingsUI.install(in: window, views: [
            SettingsUI.header("Panel", subtitle: "Make Plank feel at home on your desktop.", symbol: "dock.rectangle"),
            display, startup, dock, plugins,
            SettingsUI.help("Changes are saved automatically.")])
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        reloadLoginState()
        super.showWindow(sender)
    }

    @objc private func reloadLoginState() {
        let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        launchAtLogin.isEnabled = isAppBundle
        guard isAppBundle else {
            launchAtLogin.state = .off
            loginStatus.stringValue = "Open Plank.app to configure launch at login."
            return
        }
        // The system owns this preference; reflect changes made in System Settings.
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin.state = .on
            loginStatus.stringValue = "Enabled. Plank will start automatically the next time you log in."
        case .requiresApproval:
            launchAtLogin.state = .mixed
            loginStatus.stringValue = "Approval required. Allow Plank in Login Items in System Settings."
        case .notRegistered:
            launchAtLogin.state = .off
            loginStatus.stringValue = "Launch at login is off."
        case .notFound:
            launchAtLogin.state = .off
            loginStatus.stringValue = "The system could not find this app. Move Plank.app to a permanent location and try again."
        @unknown default:
            launchAtLogin.state = .off
            loginStatus.stringValue = "Unable to read the login item status."
        }
    }

    @objc private func loginChanged() {
        // Use the real registration status rather than the checkbox's mixed-state cycle.
        let status = SMAppService.mainApp.status
        do {
            if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            reloadLoginState()
        } catch {
            reloadLoginState()
            loginStatus.stringValue = "Unable to change launch at login: \(error.localizedDescription)"
        }
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func reloadDockState(enabled: Bool, status: String) {
        hideDock.state = enabled ? .on : .off
        dockStatus.stringValue = status
    }

    @objc private func dockChanged() {
        let (enabled, status) = onDockChanged(hideDock.state == .on)
        reloadDockState(enabled: enabled, status: status)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showPlugins() { onShowPlugins() }

    @objc private func heightChanged() {
        let index = heightPreset.indexOfSelectedItem
        guard PanelHeightPreset.allCases.indices.contains(index) else { return }
        let preset = PanelHeightPreset.allCases[index]
        PanelPreferences.setHeight(preset: preset, customHeight: customHeight.doubleValue)
        customHeight.doubleValue = PanelPreferences.customHeight
        customHeight.isEnabled = preset == .custom
        onHeightChanged()
    }

    @objc private func widthChanged() {
        let percentage = slider.doubleValue.rounded()
        valueLabel.stringValue = "\(Int(percentage))%"
        onChange(percentage)
    }
}
