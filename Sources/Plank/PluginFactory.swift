import AppKit

@MainActor
func makePluginSettings(_ config: PluginConfiguration) -> PluginSettingsContent {
    pluginType(for: config.kind).makeSettings(configuration: config)
}

@MainActor
func makePlugin(_ config: PluginConfiguration) -> any PanelPlugin {
    pluginType(for: config.kind).init(id: config.id)
}

@MainActor
private func pluginType(for kind: String) -> any PanelPlugin.Type {
    switch kind {
    case "taskbar": TaskbarPlugin.self
    case "separator": SeparatorPlugin.self
    case "clock": ClockPlugin.self
    case "launcher": LauncherPlugin.self
    case "imenu": IMenuPlugin.self
    case "showdesktop": ShowDesktopPlugin.self
    case "folder": FolderPlugin.self
    case "disks": DisksPlugin.self
    default: TrashPlugin.self
    }
}
