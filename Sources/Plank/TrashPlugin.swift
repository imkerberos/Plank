import AppKit

@MainActor
final class TrashPlugin: NSObject, PanelPlugin {
    let id: String
    private let button = TrashButton()
    private var buttonWidth: NSLayoutConstraint!
    private var buttonHeight: NSLayoutConstraint!
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var isEmpty: Bool?
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.image = NSImage(named: NSImage.trashEmptyName)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
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

    func refresh() {
        updateTrashState()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTrashState() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
    }

    private func updateTrashState() {
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            let empty = await Task.detached(priority: .utility) { TrashStateReader.isEmpty() }.value
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            // A denied permission or an unavailable Finder is not an empty Trash.
            // Keep the last known icon until a query succeeds.
            guard let empty, self.isEmpty != empty else { return }
            self.isEmpty = empty
            self.button.image = NSImage(named: empty ? NSImage.trashEmptyName : NSImage.trashFullName)
            self.button.toolTip = empty ? "Trash is empty · Open in Finder" : "Trash contains items · Open in Finder"
            self.button.setAccessibilityLabel(empty ? "Trash (Empty)" : "Trash (Contains Items)")
        }
    }

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
        updateTrashState()
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

/// Finder reports the combined Trash, including items on mounted volumes.
/// Querying it avoids requiring Full Disk Access to inspect protected directories.
private enum TrashStateReader {
    static func isEmpty() -> Bool? {
        guard let script = NSAppleScript(source: """
            with timeout of 1 seconds
                tell application "Finder" to return not (exists item 1 of trash)
            end timeout
            """) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.booleanValue : nil
    }
}

@MainActor
private final class TrashButton: NSButton {
    var onContextMenu: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}

@MainActor
extension TrashPlugin {
    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        TrashSettings(configuration: configuration)
    }
}

@MainActor
private final class TrashSettings: PluginSettingsContent {
    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "How It Works", windowHeight: 430)
        options = [SettingsUI.help("Click to open Trash in Finder. Right-click for Open Trash and Empty Trash. The icon switches between empty and full as the contents change."),
                   SettingsUI.help("Reading Trash status requires permission for Plank to control Finder in Privacy & Security → Automation. Status updates every two seconds."),
                   SettingsUI.help("Empty Trash asks for confirmation before permanently deleting items. Finder automation permission is required.")]
    }
}
