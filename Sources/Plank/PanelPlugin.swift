import AppKit

/// Built-in plugins own their views and resources; the panel owns their lifetime.
@MainActor
protocol PanelPlugin: AnyObject {
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

@MainActor
final class TaskbarPlugin: PanelPlugin {
    let id: String
    private let stack = NSStackView()
    private var buttonSize: CGFloat = 44
    var view: NSView { stack }

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
        let applications = TaskbarWindowOrder.shared.sorted(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        let config = PluginPreferences.configuration(id)
        for application in applications {
            stack.addArrangedSubview(ApplicationButton(
                application: application,
                showsTitle: config?.taskbarShowsTitles ?? false,
                maximumWidth: config?.taskbarButtonMaximumWidth ?? 180,
                buttonSize: buttonSize
            ))
        }
    }
}

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
final class TrashPlugin: NSObject, PanelPlugin {
    let id: String
    private let button = TrashButton()
    private var buttonWidth: NSLayoutConstraint!
    private var buttonHeight: NSLayoutConstraint!
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Open Trash")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Open Trash in Finder"
        button.target = self
        button.action = #selector(openTrash)
        button.onContextMenu = { [weak self] event in
            guard let self else { return }
            let menu = NSMenu()
            self.addMenuItems(to: menu)
            menu.removeItem(at: menu.items.count - 1)
            PanelMenu.show(menu, from: self.button, event: event)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        buttonWidth = button.widthAnchor.constraint(equalToConstant: 44)
        buttonHeight = button.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([buttonWidth, buttonHeight])
    }

    func setPanelHeight(_ height: CGFloat) {
        buttonWidth.constant = PanelMetrics.buttonSize(for: height)
        buttonHeight.constant = buttonWidth.constant
    }

    func refresh() {}

    func addMenuItems(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Open Trash", action: #selector(openTrash), keyEquivalent: "")
        item.target = self
        let empty = menu.addItem(withTitle: "Empty Trash…", action: #selector(emptyTrash), keyEquivalent: "")
        empty.target = self
        menu.addItem(.separator())
    }

    @objc private func emptyTrash() {
        NSApp.activate(ignoringOtherApps: true)
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Empty Trash?"
        confirmation.informativeText = "All items in the Trash will be permanently deleted. This cannot be undone."
        confirmation.addButton(withTitle: "Cancel")
        confirmation.addButton(withTitle: "Empty Trash")
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }
        guard let script = NSAppleScript(source: "tell application \"Finder\" to empty trash") else {
            showTrashError("Unable to prepare the Finder command.", title: "Unable to Empty Trash")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            // Finder cancellation is a normal outcome, not an error to display.
            guard (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue != -128 else { return }
            var message = error[NSAppleScript.errorMessage] as? String ?? "Finder could not empty the Trash."
            if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743 {
                message += "\n\nAllow Plank to control Finder in Privacy & Security > Automation."
            }
            showTrashError(message, title: "Unable to Empty Trash")
        }
    }

    @objc private func openTrash() {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            showTrashError("Finder could not be found.")
            return
        }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([trash], withApplicationAt: finder, configuration: configuration) { [weak self] _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.showTrashError(message) }
            }
        }
    }

    private func showTrashError(_ message: String, title: String = "Unable to Open Trash") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
private final class TrashButton: NSButton {
    var onContextMenu: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}

@MainActor
func makePlugin(_ config: PluginConfiguration) -> any PanelPlugin {
    switch config.kind {
    case "taskbar": TaskbarPlugin(id: config.id)
    case "separator": SeparatorPlugin(id: config.id)
    case "clock": ClockPlugin(id: config.id)
    case "launcher": LauncherPlugin(id: config.id)
    case "imenu": IMenuPlugin(id: config.id)
    default: TrashPlugin(id: config.id)
    }
}
