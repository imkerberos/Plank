import Foundation

@MainActor
enum LauncherStore {
    private static func key(_ id: String) -> String { "plugin.\(id).launcherPaths" }

    static func paths(for id: String) -> [String] {
        PluginPreferences.defaults.stringArray(forKey: key(id)) ?? []
    }

    static func applicationURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: resolved),
              let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
              ["APPL", "FNDR"].contains(packageType),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return resolved
    }

    @discardableResult
    static func add(_ urls: [URL], to id: String) -> Bool {
        guard PluginPreferences.configuration(id)?.kind == "launcher" else { return false }
        // Reject mixed drops rather than silently discarding unsupported files.
        let apps = urls.compactMap(applicationURL)
        guard !apps.isEmpty, apps.count == urls.count else { return false }
        var paths = paths(for: id)
        for app in apps where !paths.contains(app.path) { paths.append(app.path) }
        PluginPreferences.defaults.set(paths, forKey: key(id))
        return true
    }

    /// The insertion index refers to the original array, just like a gap
    /// between the on-screen icons. Moving never adds or deletes an item.
    @discardableResult
    static func move(_ path: String, to insertionIndex: Int, in id: String) -> Bool {
        guard PluginPreferences.configuration(id)?.kind == "launcher" else { return false }
        let original = paths(for: id)
        guard let source = original.firstIndex(of: path) else { return false }
        let gap = min(original.count, max(0, insertionIndex))
        var reordered = original
        reordered.remove(at: source)
        reordered.insert(path, at: gap > source ? gap - 1 : gap)
        guard reordered != original else { return false }
        PluginPreferences.defaults.set(reordered, forKey: key(id))
        return true
    }

    static func remove(_ path: String, from id: String) {
        PluginPreferences.defaults.set(paths(for: id).filter { $0 != path }, forKey: key(id))
    }

    static func clear(_ id: String) { PluginPreferences.defaults.removeObject(forKey: key(id)) }
}
