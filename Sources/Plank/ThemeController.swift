import AppKit

@MainActor
enum ThemeController {
    static func apply() {
        // nil restores AppKit's live inheritance of the system appearance.
        switch PanelPreferences.theme {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}
