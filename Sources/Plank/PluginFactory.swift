import AppKit

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
