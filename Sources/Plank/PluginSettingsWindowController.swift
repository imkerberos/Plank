import AppKit

@MainActor
final class PluginSettingsWindowController: NSWindowController {
    let pluginID: String
    private let onChange: () -> Void
    private let nameField = NSTextField()
    private let heading = NSTextField(labelWithString: "")
    private let settings: PluginSettingsContent

    init(configuration: PluginConfiguration, onChange: @escaping () -> Void) {
        pluginID = configuration.id
        self.onChange = onChange
        settings = makePluginSettings(configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: settings.windowHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(configuration.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        settings.onChange = { [weak self] in self?.save() }
        nameField.stringValue = configuration.name
        nameField.placeholderString = "Plugin name"
        nameField.target = self
        nameField.action = #selector(save)
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        nameField.setAccessibilityLabel("Plugin name")
        let identity = SettingsUI.card("General", views: [SettingsUI.row("Name", control: nameField)])
        settings.updateControls()
        let apply = NSButton(title: "Apply Changes", target: self, action: #selector(save))
        apply.bezelStyle = .rounded
        let footer = SettingsUI.row("", control: apply)
        let kind = PluginPreferences.available.first { $0.0 == configuration.kind }?.1 ?? "Plugin"
        SettingsUI.install(in: window, views: [
            SettingsUI.header(configuration.name, subtitle: "\(kind) plugin settings", symbol: SettingsUI.symbol(for: configuration.kind), titleField: heading),
            identity, SettingsUI.card(settings.sectionTitle, views: settings.options), footer])
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func save() {
        PluginPreferences.update(pluginID) { config in
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { config.name = name }
            settings.save(to: &config)
        }
        settings.updateControls()
        heading.stringValue = PluginPreferences.configuration(pluginID)?.name ?? "Plugin"
        window?.title = "\(PluginPreferences.configuration(pluginID)?.name ?? "Plugin") Settings"
        onChange()
    }
}
