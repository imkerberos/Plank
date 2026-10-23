import Foundation

struct PluginConfiguration: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var name: String
    var enabled = true
    var separatorStyle = "line"
    var spaceWidth = 24.0
    var expand = false
    var showSeconds = false
    // Optional fields keep configurations saved by earlier versions decodable.
    var use24HourTime: Bool?
    var clockStyle: String?
    var clockOpensCalendar: Bool?
    var taskbarStyle: String?
    var taskbarMaximumWidth: Double?
    var taskbarHideFinder: Bool?
    var taskbarHideLauncherApps: Bool?
    var launcherShowRunningIndicator: Bool?
    var imenuViewMode: String?
    var folderPath: String?
    var disksHideWhenEmpty: Bool?
    var codexHomePath: String?

    var imenuShowsIcons: Bool { imenuViewMode == "icons" }

    var taskbarShowsTitles: Bool { taskbarStyle == "iconAndTitle" }
    var clockDisplayStyle: ClockStyle { ClockStyle(rawValue: clockStyle ?? "") ?? .digital }
    var taskbarButtonMaximumWidth: Double {
        let value = taskbarMaximumWidth ?? 180
        return value.isFinite ? min(400, max(80, value)) : 180
    }
}

@MainActor
enum PluginPreferences {
    static var defaults = UserDefaults.standard
    static let available = [("taskbar", "Taskbar"), ("separator", "Separator"), ("clock", "Clock"), ("trash", "Trash"), ("launcher", "Launcher"), ("imenu", "iMenu"), ("showdesktop", "Show Desktop"), ("folder", "Folder"), ("disks", "Mounted Disks"), ("codexusage", "Codex Usage")]

    static var configurations: [PluginConfiguration] {
        get {
            if let data = defaults.data(forKey: "pluginConfigurations"),
               let saved = try? JSONDecoder().decode([PluginConfiguration].self, from: data) {
                var seen: Set<String> = []
                let legacyNames = ["taskbar": "任务栏", "separator": "分隔线", "clock": "时钟", "trash": "垃圾桶"]
                let translated = saved.map { item in
                    var item = item
                    if item.name == legacyNames[item.kind],
                       let title = available.first(where: { $0.0 == item.kind })?.1 {
                        item.name = title
                    }
                    return item
                }
                if translated != saved, let data = try? JSONEncoder().encode(translated) {
                    defaults.set(data, forKey: "pluginConfigurations")
                }
                return translated.filter { item in
                    available.contains { $0.0 == item.kind } && seen.insert(item.id).inserted
                }
            }
            // Migrate the original one-per-type configuration, including hidden plugins.
            let known = ["taskbar", "separator", "clock", "trash"]
            let hasLegacyPreferences = defaults.object(forKey: "pluginOrder") != nil
                || known.contains { defaults.object(forKey: "plugin.\($0).enabled") != nil }
            if !hasLegacyPreferences {
                return ["imenu", "separator", "showdesktop", "separator", "launcher", "separator",
                        "taskbar", "separator", "separator", "clock", "trash"].enumerated().map { index, kind in
                    let id = kind == "separator" ? "separator-\(index)" : kind
                    var configuration = PluginConfiguration(id: id, kind: kind, name: available.first { $0.0 == kind }!.1)
                    if kind == "separator", index == 7 {
                        configuration.separatorStyle = "space"
                        configuration.expand = true
                    }
                    if kind == "clock" { configuration.clockStyle = "binary" }
                    return configuration
                }
            }
            let saved = defaults.stringArray(forKey: "pluginOrder") ?? []
            var order: [String] = []
            for id in saved + known where known.contains(id) && !order.contains(id) { order.append(id) }
            return order.map { id in
                PluginConfiguration(id: id, kind: id, name: available.first { $0.0 == id }!.1,
                    enabled: defaults.object(forKey: "plugin.\(id).enabled") as? Bool ?? true)
            }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "pluginConfigurations")
            }
        }
    }

    static var order: [String] { configurations.map(\.id) }
    static func configuration(_ id: String) -> PluginConfiguration? { configurations.first { $0.id == id } }
    static func isEnabled(_ id: String) -> Bool { configuration(id)?.enabled ?? false }
    static func setEnabled(_ enabled: Bool, for id: String) {
        update(id) { $0.enabled = enabled }
    }
    static func update(_ id: String, _ change: (inout PluginConfiguration) -> Void) {
        var items = configurations
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        configurations = items
    }
    static func setOrder(_ ids: [String]) {
        let items = configurations
        var seen: Set<String> = []
        configurations = (ids + items.map(\.id)).compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return items.first { $0.id == id }
        }
    }
    @discardableResult static func add(kind: String) -> String {
        let id = UUID().uuidString
        var items = configurations
        items.append(PluginConfiguration(id: id, kind: kind, name: available.first { $0.0 == kind }!.1))
        configurations = items
        return id
    }
    static func remove(_ id: String) {
        configurations = configurations.filter { $0.id != id }
        defaults.removeObject(forKey: "plugin.\(id).launcherPaths")
    }
}
