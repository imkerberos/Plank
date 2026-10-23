import AppKit

@MainActor
final class FolderPlugin: NSObject, PanelPlugin {
    let id: String
    private let button = NSButton()
    private var buttonSize: CGFloat = 44
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(openFolder)
        button.translatesAutoresizingMaskIntoConstraints = false
        width = button.widthAnchor.constraint(equalToConstant: buttonSize)
        height = button.heightAnchor.constraint(equalToConstant: buttonSize)
        NSLayoutConstraint.activate([width, height])
    }

    func setPanelHeight(_ panelHeight: CGFloat) {
        buttonSize = PanelMetrics.buttonSize(for: panelHeight)
        width.constant = buttonSize
        height.constant = buttonSize
    }

    func refresh() {
        let url = Self.folderURL(for: PluginPreferences.configuration(id))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: max(24, buttonSize - 8), height: max(24, buttonSize - 8))
        button.image = icon
        button.toolTip = "Open Folder · \(url.path)"
        button.setAccessibilityLabel("Open \(url.lastPathComponent)")
    }

    func addMenuItems(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Open Folder", action: #selector(openFolder), keyEquivalent: "")
        item.target = self
        menu.addItem(.separator())
    }

    @objc private func openFolder() {
        let url = Self.folderURL(for: PluginPreferences.configuration(id))
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            showError("The folder is unavailable: \(url.path)\nChoose an existing folder in this plugin’s settings.")
            return
        }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            showError("Finder could not be found.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: configuration, completionHandler: nil)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unable to Open Folder"
        alert.informativeText = message
        alert.runModal()
    }

    fileprivate static func folderURL(for configuration: PluginConfiguration?) -> URL {
        guard let path = configuration?.folderPath, !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        FolderSettings(configuration: configuration)
    }
}

@MainActor
private final class FolderSettings: PluginSettingsContent {
    private var folderURL: URL
    private let path = NSTextField(wrappingLabelWithString: "")

    init(configuration: PluginConfiguration) {
        folderURL = FolderPlugin.folderURL(for: configuration)
        super.init(sectionTitle: "Folder", windowHeight: 450)
        path.stringValue = folderURL.path
        path.isSelectable = true
        path.setAccessibilityLabel("Folder path")
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        options = [path, SettingsUI.row("", control: choose),
                   SettingsUI.help("Click the panel icon to open this folder in Finder. Each Folder plugin has its own location. New instances default to your home folder.")]
    }

    @objc private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose Folder"
        picker.prompt = "Choose"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = folderURL
        guard picker.runModal() == .OK, let url = picker.url else { return }
        folderURL = url.standardizedFileURL
        path.stringValue = folderURL.path
        requestSave()
    }

    override func save(to configuration: inout PluginConfiguration) {
        configuration.folderPath = folderURL.path
    }
}
