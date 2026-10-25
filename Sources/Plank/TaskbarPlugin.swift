import AppKit

@MainActor
final class TaskbarPlugin: PanelPlugin {
    let id: String
    private let stack = NSStackView()
    private var buttonSize: CGFloat = 44
    var view: NSView { stack }
    var onChange: (() -> Void)?

    init(id: String) {
        self.id = id
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
    }

    func setPanelHeight(_ height: CGFloat) { buttonSize = PanelMetrics.buttonSize(for: height) }

    func refresh() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var applications = TaskbarWindowOrder.shared.sorted(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        let config = PluginPreferences.configuration(id)
        if config?.taskbarHideLauncherApps == true {
            let shortcuts = Set(PluginPreferences.configurations
                .filter { $0.kind == "launcher" && $0.enabled }
                .flatMap { LauncherStore.paths(for: $0.id) }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
            applications.removeAll { application in
                guard let url = application.bundleURL else { return false }
                return shortcuts.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        let finder = applications.filter { $0.bundleIdentifier == "com.apple.finder" }
        applications.removeAll { $0.bundleIdentifier == "com.apple.finder" }
        if config?.taskbarHideFinder != true { applications.insert(contentsOf: finder, at: 0) }
        for application in applications {
            let button = ApplicationButton(
                application: application,
                showsTitle: config?.taskbarShowsTitles ?? false,
                maximumWidth: config?.taskbarButtonMaximumWidth ?? 180,
                buttonSize: buttonSize
            )
            button.onLauncherChanged = { [weak self] in self?.onChange?() }
            stack.addArrangedSubview(button)
        }
    }
}

@MainActor
extension TaskbarPlugin {
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        TaskbarSettings(configuration: configuration)
    }
}

@MainActor
private final class TaskbarSettings: PluginSettingsContent {
    private let taskbarStyle = NSPopUpButton()
    private let taskbarWidth = NSTextField()
    private let hideFinder = NSButton(checkboxWithTitle: "Hide Finder", target: nil, action: nil)
    private let hideLauncherApps = NSButton(checkboxWithTitle: "Hide apps in Launcher", target: nil, action: nil)

    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "Application Buttons", windowHeight: 560)
        taskbarStyle.addItems(withTitles: ["Icons Only", "Icons and Titles"])
        taskbarStyle.selectItem(at: configuration.taskbarShowsTitles ? 1 : 0)
        taskbarStyle.target = self
        taskbarStyle.action = #selector(requestSave)
        taskbarStyle.widthAnchor.constraint(equalToConstant: 200).isActive = true
        taskbarWidth.doubleValue = configuration.taskbarButtonMaximumWidth
        taskbarWidth.target = self
        taskbarWidth.action = #selector(requestSave)
        taskbarWidth.widthAnchor.constraint(equalToConstant: 80).isActive = true
        taskbarWidth.setAccessibilityLabel("Maximum app button width")
        let size = NSStackView(views: [taskbarWidth, SettingsUI.help("pt")])
        size.spacing = 6
        hideFinder.state = configuration.taskbarHideFinder == true ? .on : .off
        hideFinder.target = self
        hideFinder.action = #selector(requestSave)
        hideLauncherApps.state = configuration.taskbarHideLauncherApps == true ? .on : .off
        hideLauncherApps.target = self
        hideLauncherApps.action = #selector(requestSave)
        options = [SettingsUI.row("Style", control: taskbarStyle),
                   SettingsUI.row("Maximum width", control: size),
                   SettingsUI.help("Choose a width from 80 to 400 pt. Used when titles are shown."),
                   hideFinder,
                   hideLauncherApps,
                   SettingsUI.help("Hide apps with shortcuts in any enabled Launcher on this panel."),
                   SettingsUI.help("Finder appears first unless hidden. Other apps keep their window opening order."),
                   SettingsUI.help("Click the active app to minimize its window. Click again to restore. Minimizing and Dock notification badges require Accessibility access.")]
    }

    override func updateControls() {
        taskbarWidth.isEnabled = taskbarStyle.indexOfSelectedItem == 1
    }

    override func save(to config: inout PluginConfiguration) {
        config.taskbarHideLauncherApps = hideLauncherApps.state == .on
        config.taskbarHideFinder = hideFinder.state == .on
        config.taskbarStyle = taskbarStyle.indexOfSelectedItem == 1 ? "iconAndTitle" : "icon"
        config.taskbarMaximumWidth = taskbarWidth.doubleValue
        config.taskbarMaximumWidth = config.taskbarButtonMaximumWidth
        taskbarWidth.doubleValue = config.taskbarButtonMaximumWidth
    }
}
