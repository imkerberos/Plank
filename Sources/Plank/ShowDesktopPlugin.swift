import AppKit
import Darwin

@MainActor
final class ShowDesktopPlugin: NSObject, PanelPlugin {
    let id: String
    private let button = PanelMenuButton()
    private var buttonWidth: NSLayoutConstraint!
    private var buttonHeight: NSLayoutConstraint!
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Show Desktop")
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.toolTip = "Show Desktop · Click again to restore windows"
        button.setAccessibilityLabel("Show Desktop")
        button.target = self
        button.action = #selector(toggleDesktop)
        button.translatesAutoresizingMaskIntoConstraints = false
        buttonWidth = button.widthAnchor.constraint(equalToConstant: 44)
        buttonHeight = button.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([buttonWidth, buttonHeight])
    }

    func setPanelHeight(_ height: CGFloat) {
        buttonWidth.constant = PanelMetrics.buttonSize(for: height)
        buttonHeight.constant = buttonWidth.constant
        button.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Show Desktop")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: max(16, height - 20), weight: .regular))
    }

    func refresh() {}

    @objc private func toggleDesktop() {
        do { try DesktopToggle.perform() }
        catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Unable to Show Desktop"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        let settings = PluginSettingsContent(sectionTitle: "How It Works", windowHeight: 430)
        settings.options = [
            SettingsUI.help("Click to move windows aside and show the desktop. Click again to restore them."),
            SettingsUI.help("Uses the system Dock’s Show Desktop action without changing keyboard shortcuts or minimizing windows. No Hammerspoon setup is required."),
            SettingsUI.help("This feature uses an internal macOS interface and may require an update after a system upgrade.")
        ]
        return settings
    }
}

@MainActor
private enum DesktopToggle {
    private typealias SendNotification = @convention(c) (CFString, Int32) -> Int32

    static func perform() throws {
        // Resolve this private entry point at runtime so an unavailable symbol
        // does not prevent Plank from starting on a future macOS release.
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        guard let library = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { throw Failure.unavailable }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "CoreDockSendNotification") else { throw Failure.unavailable }
        let send = unsafeBitCast(symbol, to: SendNotification.self)
        // Same action used by Hammerspoon's hs.spaces.toggleShowDesktop().
        let status = send("com.apple.showdesktop.awake" as CFString, 0)
        guard status == 0 else { throw Failure.rejected(status) }
    }

    private enum Failure: LocalizedError {
        case unavailable
        case rejected(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable: "The system Show Desktop interface is unavailable on this version of macOS."
            case .rejected(let status): "The system Dock could not toggle Show Desktop (error \(status))."
            }
        }
    }
}
