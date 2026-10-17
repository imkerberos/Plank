import AppKit

enum SystemSessionAction: String, CaseIterable {
    case lock, sleep, restart, shutdown

    var title: String {
        switch self {
        case .lock: "Lock"
        case .sleep: "Sleep"
        case .restart: "Restart…"
        case .shutdown: "Shut Down…"
        }
    }

    @MainActor var icon: NSImage? {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "MaterialIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }

    @MainActor func perform() {
        NSApp.activate(ignoringOtherApps: true)
        if self == .restart || self == .shutdown {
            let alert = NSAlert()
            alert.messageText = self == .restart ? "Restart this Mac?" : "Shut down this Mac?"
            alert.informativeText = "Applications will be asked to quit. Save your work before continuing."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: self == .restart ? "Restart" : "Shut Down")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let command: String
        switch self {
        case .lock: command = "key code 12 using {control down, command down}"
        case .sleep: command = "sleep"
        case .restart: command = "restart"
        case .shutdown: command = "shut down"
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to \(command)")?.executeAndReturnError(&error)
        if let error {
            let alert = NSAlert()
            alert.messageText = "Unable to \(title.replacingOccurrences(of: "…", with: ""))"
            alert.informativeText = (error[NSAppleScript.errorMessage] as? String ?? "The system could not complete this action.")
                + "\n\nAllow Plank to control System Events in Privacy & Security > Automation. Lock Screen also requires Accessibility access."
            alert.runModal()
        }
    }
}
