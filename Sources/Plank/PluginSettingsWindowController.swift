import AppKit

@MainActor
final class PluginSettingsWindowController: NSWindowController {
    let pluginID: String
    private let onChange: () -> Void
    private let nameField = NSTextField()
    private let heading = NSTextField(labelWithString: "")
    private let style = NSPopUpButton()
    private let width = NSTextField()
    private let expand = NSButton(checkboxWithTitle: "Expand to fill remaining panel space", target: nil, action: nil)
    private let taskbarStyle = NSPopUpButton()
    private let taskbarWidth = NSTextField()
    private let seconds = NSButton(checkboxWithTitle: "Show Seconds", target: nil, action: nil)
    private let use24HourTime = NSButton(checkboxWithTitle: "Use 24-Hour Time", target: nil, action: nil)

    init(configuration: PluginConfiguration, onChange: @escaping () -> Void) {
        pluginID = configuration.id
        self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: configuration.kind == "taskbar" || configuration.kind == "separator" ? 560 : 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(configuration.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        nameField.stringValue = configuration.name
        nameField.placeholderString = "Plugin name"
        nameField.target = self
        nameField.action = #selector(save)
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        nameField.setAccessibilityLabel("Plugin name")
        let identity = SettingsUI.card("General", views: [SettingsUI.row("Name", control: nameField)])
        var options: [NSView] = []
        var sectionTitle = "How It Works"
        if configuration.kind == "taskbar" {
            sectionTitle = "Application Buttons"
            taskbarStyle.addItems(withTitles: ["Icons Only", "Icons and Titles"])
            taskbarStyle.selectItem(at: configuration.taskbarShowsTitles ? 1 : 0)
            taskbarStyle.target = self
            taskbarStyle.action = #selector(save)
            taskbarStyle.widthAnchor.constraint(equalToConstant: 200).isActive = true
            taskbarWidth.doubleValue = configuration.taskbarButtonMaximumWidth
            taskbarWidth.target = self
            taskbarWidth.action = #selector(save)
            taskbarWidth.widthAnchor.constraint(equalToConstant: 80).isActive = true
            taskbarWidth.setAccessibilityLabel("Maximum app button width")
            let size = NSStackView(views: [taskbarWidth, SettingsUI.help("pt")])
            size.spacing = 6
            options = [SettingsUI.row("Style", control: taskbarStyle),
                       SettingsUI.row("Maximum width", control: size),
                       SettingsUI.help("Choose a width from 80 to 400 pt. Used when titles are shown."),
                       SettingsUI.help("Click the active app to minimize its window. Click again to restore. Minimizing requires Accessibility access.")]
        } else if configuration.kind == "separator" {
            sectionTitle = "Layout"
            style.addItems(withTitles: ["Line", "Space"])
            style.selectItem(at: configuration.separatorStyle == "space" ? 1 : 0)
            style.target = self
            style.action = #selector(save)
            style.widthAnchor.constraint(equalToConstant: 160).isActive = true
            width.doubleValue = configuration.spaceWidth
            width.target = self
            width.action = #selector(save)
            width.widthAnchor.constraint(equalToConstant: 80).isActive = true
            width.setAccessibilityLabel("Fixed space width")
            let size = NSStackView(views: [width, SettingsUI.help("pt")])
            size.spacing = 6
            expand.state = configuration.expand ? .on : .off
            expand.target = self
            expand.action = #selector(save)
            options = [SettingsUI.row("Display as", control: style),
                       SettingsUI.row("Fixed width", control: size), expand,
                       SettingsUI.help("Line fills the panel height. Space adds 8–400 pt of blank space, or expands to fill the remaining width.")]
        } else if configuration.kind == "clock" {
            sectionTitle = "Time Format"
            use24HourTime.state = configuration.use24HourTime == true ? .on : .off
            use24HourTime.target = self
            use24HourTime.action = #selector(save)
            seconds.state = configuration.showSeconds ? .on : .off
            seconds.target = self
            seconds.action = #selector(save)
            options = [use24HourTime, seconds, SettingsUI.help("Uses your Mac’s current time zone. Hover over the clock to see the full date.")]
        } else if configuration.kind == "imenu" {
            options = [SettingsUI.help("Browse and search installed apps. Click an app to launch it, or use the arrow keys and Return. Press Esc or click outside to close."),
                       SettingsUI.help("Lock, Sleep, Restart, and Shut Down are available at the bottom of the menu.")]
        } else if configuration.kind == "launcher" {
            options = [SettingsUI.help("Drag apps from Finder or Taskbar into Launcher to add shortcuts."),
                       SettingsUI.help("Click to launch, drag to reorder, or right-click to remove a shortcut. Each Launcher keeps its own shortcuts.")]
        } else {
            options = [SettingsUI.help("Click to open Trash in Finder. Right-click for Open Trash and Empty Trash."),
                       SettingsUI.help("Empty Trash asks for confirmation before permanently deleting items. Finder automation permission is required.")]
        }
        updateControls()
        let apply = NSButton(title: "Apply Changes", target: self, action: #selector(save))
        apply.bezelStyle = .rounded
        let footer = SettingsUI.row("", control: apply)
        let kind = PluginPreferences.available.first { $0.0 == configuration.kind }?.1 ?? "Plugin"
        SettingsUI.install(in: window, views: [
            SettingsUI.header(configuration.name, subtitle: "\(kind) plugin settings", symbol: SettingsUI.symbol(for: configuration.kind), titleField: heading),
            identity, SettingsUI.card(sectionTitle, views: options), footer])
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func updateControls() {
        taskbarWidth.isEnabled = taskbarStyle.indexOfSelectedItem == 1
        expand.isEnabled = style.indexOfSelectedItem == 1
        width.isEnabled = expand.isEnabled && expand.state != .on
    }

    @objc private func save() {
        PluginPreferences.update(pluginID) { config in
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { config.name = name }
            if config.kind == "separator" {
                config.separatorStyle = style.indexOfSelectedItem == 1 ? "space" : "line"
                let value = width.doubleValue
                config.spaceWidth = value.isFinite ? min(400, max(8, value)) : 24
                width.doubleValue = config.spaceWidth
                config.expand = expand.state == .on
            }
            if config.kind == "taskbar" {
                config.taskbarStyle = taskbarStyle.indexOfSelectedItem == 1 ? "iconAndTitle" : "icon"
                config.taskbarMaximumWidth = taskbarWidth.doubleValue
                config.taskbarMaximumWidth = config.taskbarButtonMaximumWidth
                taskbarWidth.doubleValue = config.taskbarButtonMaximumWidth
            }
            if config.kind == "clock" {
                config.showSeconds = seconds.state == .on
                config.use24HourTime = use24HourTime.state == .on
            }
        }
        updateControls()
        heading.stringValue = PluginPreferences.configuration(pluginID)?.name ?? "Plugin"
        window?.title = "\(PluginPreferences.configuration(pluginID)?.name ?? "Plugin") Settings"
        onChange()
    }
}
