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
