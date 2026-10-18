import AppKit

/// Built-in plugins own their views and resources; the panel owns their lifetime.
@MainActor
protocol PanelPlugin: AnyObject {
    init(id: String)
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent
    var id: String { get }
    var view: NSView { get }
    func setPanelHeight(_ height: CGFloat)
    func refresh()
    func stop()
    func addMenuItems(to menu: NSMenu)
}

extension PanelPlugin {
    func setPanelHeight(_ height: CGFloat) {}
    func stop() {}
    func addMenuItems(to menu: NSMenu) {}
}
