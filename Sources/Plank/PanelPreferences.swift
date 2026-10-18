import Foundation

enum PanelTheme: String, CaseIterable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: "Follow System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

enum PanelHeightPreset: String, CaseIterable {
    case large, medium, small, tiny, custom

    var title: String {
        switch self {
        case .large: "Large (80 pt)"
        case .medium: "Medium (64 pt)"
        case .small: "Small (48 pt)"
        case .tiny: "Tiny (32 pt)"
        case .custom: "Custom"
        }
    }
}

@MainActor
enum PanelPreferences {
    static var theme: PanelTheme {
        get { PanelTheme(rawValue: PluginPreferences.defaults.string(forKey: "panelTheme") ?? "") ?? .system }
        set { PluginPreferences.defaults.set(newValue.rawValue, forKey: "panelTheme") }
    }
    static var hideSystemDock: Bool {
        get { PluginPreferences.defaults.bool(forKey: "hideSystemDock") }
        set { PluginPreferences.defaults.set(newValue, forKey: "hideSystemDock") }
    }

    static var isLocked: Bool {
        get { PluginPreferences.defaults.bool(forKey: "panelLocked") }
        set { PluginPreferences.defaults.set(newValue, forKey: "panelLocked") }
    }

    static var heightPreset: PanelHeightPreset {
        PanelHeightPreset(rawValue: PluginPreferences.defaults.string(forKey: "panelHeightPreset") ?? "") ?? .medium
    }

    static var customHeight: Double {
        let value = PluginPreferences.defaults.object(forKey: "panelCustomHeight") as? Double ?? 64
        return value.isFinite ? min(128, max(32, value)) : 64
    }

    static var height: CGFloat {
        switch heightPreset {
        case .large: 80
        case .medium: 64
        case .small: 48
        case .tiny: 32
        case .custom: CGFloat(customHeight)
        }
    }

    static func setHeight(preset: PanelHeightPreset, customHeight: Double) {
        PluginPreferences.defaults.set(preset.rawValue, forKey: "panelHeightPreset")
        let value = customHeight.isFinite ? min(128, max(32, customHeight)) : 64
        PluginPreferences.defaults.set(value.rounded(), forKey: "panelCustomHeight")
    }
}

enum PanelMetrics {
    static func buttonSize(for height: CGFloat) -> CGFloat { height }
}
