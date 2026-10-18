import AppKit

@MainActor
final class SeparatorPlugin: PanelPlugin {
    let id: String
    let view: NSView = SeparatorView(frame: .zero)

    init(id: String) { self.id = id }

    func setPanelHeight(_ height: CGFloat) { (view as? SeparatorView)?.setPanelHeight(height) }

    func refresh() {
        guard let config = PluginPreferences.configuration(id), let separator = view as? SeparatorView else { return }
        separator.configure(style: config.separatorStyle, width: config.spaceWidth, expand: config.expand)
    }
}

@MainActor
extension SeparatorPlugin {
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        SeparatorSettings(configuration: configuration)
    }
}

@MainActor
private final class SeparatorSettings: PluginSettingsContent {
    private let style = NSPopUpButton()
    private let width = NSTextField()
    private let expand = NSButton(checkboxWithTitle: "Expand to fill remaining panel space", target: nil, action: nil)

    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "Layout", windowHeight: 560)
        style.addItems(withTitles: ["Line", "Space"])
        style.selectItem(at: configuration.separatorStyle == "space" ? 1 : 0)
        style.target = self
        style.action = #selector(requestSave)
        style.widthAnchor.constraint(equalToConstant: 160).isActive = true
        width.doubleValue = configuration.spaceWidth
        width.target = self
        width.action = #selector(requestSave)
        width.widthAnchor.constraint(equalToConstant: 80).isActive = true
        width.setAccessibilityLabel("Fixed space width")
        let size = NSStackView(views: [width, SettingsUI.help("pt")])
        size.spacing = 6
        expand.state = configuration.expand ? .on : .off
        expand.target = self
        expand.action = #selector(requestSave)
        options = [SettingsUI.row("Display as", control: style),
                   SettingsUI.row("Fixed width", control: size), expand,
                   SettingsUI.help("Line fills the panel height. Space adds 8–400 pt of blank space, or expands to fill the remaining width.")]
    }

    override func updateControls() {
        expand.isEnabled = style.indexOfSelectedItem == 1
        width.isEnabled = expand.isEnabled && expand.state != .on
    }

    override func save(to config: inout PluginConfiguration) {
        config.separatorStyle = style.indexOfSelectedItem == 1 ? "space" : "line"
        let value = width.doubleValue
        config.spaceWidth = value.isFinite ? min(400, max(8, value)) : 24
        width.doubleValue = config.spaceWidth
        config.expand = expand.state == .on
    }
}
