import AppKit

/// A plugin owns its controls, validation, and configuration updates.
/// The settings window retains this content and handles the shared shell.
@MainActor
class PluginSettingsContent: NSObject {
    let sectionTitle: String
    let windowHeight: CGFloat
    var options: [NSView] = []
    var onChange: (() -> Void)?

    init(sectionTitle: String, windowHeight: CGFloat) {
        self.sectionTitle = sectionTitle
        self.windowHeight = windowHeight
        super.init()
    }

    @objc final func requestSave() { onChange?() }
    func updateControls() {}
    func save(to configuration: inout PluginConfiguration) {}
}
