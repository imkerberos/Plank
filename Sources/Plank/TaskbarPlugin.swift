import AppKit

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
        var applications = TaskbarWindowOrder.shared.sorted(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        let config = PluginPreferences.configuration(id)
        if config?.taskbarHideLauncherApps == true {
            let shortcuts = Set(PluginPreferences.configurations
                .filter { $0.kind == "launcher" && $0.enabled }
                .flatMap { LauncherStore.paths(for: $0.id) }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
            applications.removeAll { application in
                guard let url = application.bundleURL else { return false }
                return shortcuts.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        let finder = applications.filter { $0.bundleIdentifier == "com.apple.finder" }
        applications.removeAll { $0.bundleIdentifier == "com.apple.finder" }
        if config?.taskbarHideFinder != true { applications.insert(contentsOf: finder, at: 0) }
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
