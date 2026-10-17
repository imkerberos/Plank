import Foundation
import CoreGraphics

@main
struct PluginPreferencesChecks {
    @MainActor
    static func main() {
        testMigratesExistingOrderAndHiddenState()
        testDefaultPluginOrder()
        testTaskbarWindowOrder()
        testClockStyles()
        testEnglishDefaultNames()
        testRepeatedSeparatorsKeepIndependentSettingsAndOrder()
        testDeletingLastPluginDoesNotRestoreDefaults()
        testLauncherDrops()
        testLauncherSorting()
        testApplicationCatalog()
        testDockRestorationAndRecovery()
        testReservedWorkspace()
        testPanelHeightSettings()
        testTaskbarSettingsCompatibility()
        print("Passed: migration, independent instances and order, persistent empty panel, launcher validation, persistence and sorting, taskbar settings compatibility, panel height presets and bounds, application discovery and search, Dock rollback and recovery, reserved window geometry")
    }
    @MainActor
    private static func withIsolatedPreferences(_ body: () -> Void) {
        let suite = "dev.plank.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let original = PluginPreferences.defaults
        PluginPreferences.defaults = defaults
        defer {
            defaults.removePersistentDomain(forName: suite)
            PluginPreferences.defaults = original
        }
        body()
    }

    @MainActor
    static func testMigratesExistingOrderAndHiddenState() {
        withIsolatedPreferences {
            PluginPreferences.defaults.set(["clock", "separator", "clock", "unknown"], forKey: "pluginOrder")
            PluginPreferences.defaults.set(false, forKey: "plugin.clock.enabled")
            precondition(PluginPreferences.order == ["clock", "separator", "taskbar", "trash"])
            precondition(!PluginPreferences.isEnabled("clock"))
        }
    }

    @MainActor
    static func testDefaultPluginOrder() {
        withIsolatedPreferences {
            precondition(PluginPreferences.order == ["imenu", "launcher", "taskbar", "clock", "trash"])
            precondition(PluginPreferences.configurations.allSatisfy(\.enabled))
            PluginPreferences.setOrder(["trash", "clock", "taskbar", "launcher", "imenu"])
            precondition(PluginPreferences.order == ["trash", "clock", "taskbar", "launcher", "imenu"])
        }
    }

    @MainActor
    static func testTaskbarWindowOrder() {
        var state = TaskbarOrderState()
        let initial = TaskbarOrderState.Window(id: 90, pid: 1)
        let earlier = TaskbarOrderState.Window(id: 50, pid: 2)
        let later = TaskbarOrderState.Window(id: 10, pid: 3)
        let second = TaskbarOrderState.Window(id: 100, pid: 2)
        state.observe([initial])
        state.observe([initial, earlier])
        state.observe([initial, earlier, later, second])
        precondition(state.rank(for: 1)! < state.rank(for: 2)!)
        precondition(state.rank(for: 2)! < state.rank(for: 3)!)
        let rank = state.rank(for: 2)
        state.observe([later, earlier, second, initial])
        precondition(state.rank(for: 2) == rank) // Window list/z-order is irrelevant.
        state.observe([initial, later, second])
        precondition(state.rank(for: 2) == state.rank(for: 3)) // Earliest open window closed.
        state.observe([initial, later])
        precondition(state.rank(for: 2) == nil)
        state.observe([initial, later, earlier])
        precondition(state.rank(for: 2)! > state.rank(for: 3)!) // Reopen takes a new position.
        var existing = TaskbarOrderState()
        existing.observe([initial, earlier, later])
        precondition(existing.rank(for: 1) == existing.rank(for: 3)) // Unknown history falls back to names.
    }

    @MainActor
    static func testClockStyles() {
        let midnight = ClockTime(hour: 0, minute: 0, second: 0)
        precondition(midnight.binaryDigits(use24HourTime: true, showSeconds: true) == [0, 0, 0, 0, 0, 0])
        precondition(midnight.binaryDigits(use24HourTime: false, showSeconds: false) == [1, 2, 0, 0])
        let evening = ClockTime(hour: 23, minute: 59, second: 48)
        precondition(evening.binaryDigits(use24HourTime: true, showSeconds: true) == [2, 3, 5, 9, 4, 8])
        precondition(evening.binaryDigits(use24HourTime: false, showSeconds: false) == [1, 1, 5, 9])
        for digit in 0...9 {
            let decoded = (0..<4).reduce(0) { result, row in
                result + (ClockTime.bitIsSet(digit, row: row) ? 1 << (3 - row) : 0)
            }
            precondition(decoded == digit)
        }
        withIsolatedPreferences {
            let old = #"[{"id":"clock","kind":"clock","name":"Clock","enabled":true,"separatorStyle":"line","spaceWidth":24,"expand":false,"showSeconds":true}]"#
            PluginPreferences.defaults.set(Data(old.utf8), forKey: "pluginConfigurations")
            precondition(PluginPreferences.configuration("clock")?.clockDisplayStyle == .digital)
            let second = PluginPreferences.add(kind: "clock")
            PluginPreferences.update(second) { $0.clockStyle = "binary"; $0.use24HourTime = true }
            precondition(PluginPreferences.configuration("clock")?.clockDisplayStyle == .digital)
            precondition(PluginPreferences.configuration(second)?.clockDisplayStyle == .binary)
            PluginPreferences.update(second) { $0.clockStyle = "unknown" }
            precondition(PluginPreferences.configuration(second)?.clockDisplayStyle == .digital)
        }
    }

    @MainActor
    static func testEnglishDefaultNames() {
        withIsolatedPreferences {
            let old = PluginConfiguration(id: "old", kind: "taskbar", name: "任务栏")
            var custom = old
            custom.id = "custom"
            custom.name = "我的应用"
            PluginPreferences.configurations = [old, custom]
            precondition(PluginPreferences.configuration("old")?.name == "Taskbar")
            precondition(PluginPreferences.configuration("custom")?.name == "我的应用")
            let persisted = try! JSONDecoder().decode([PluginConfiguration].self,
                from: PluginPreferences.defaults.data(forKey: "pluginConfigurations")!)
            precondition(persisted[0].name == "Taskbar")
            precondition(persisted[1] == custom)
        }
    }

    @MainActor
    static func testRepeatedSeparatorsKeepIndependentSettingsAndOrder() {
        withIsolatedPreferences {
            PluginPreferences.configurations = []
            let first = PluginPreferences.add(kind: "separator")
            let second = PluginPreferences.add(kind: "separator")
            PluginPreferences.update(second) {
                $0.separatorStyle = "space"
                $0.expand = true
                $0.spaceWidth = 64
            }
            PluginPreferences.setOrder([second, second, "unknown", first])
            precondition(PluginPreferences.order == [second, first])
            precondition(PluginPreferences.configuration(first)?.separatorStyle == "line")
            precondition(PluginPreferences.configuration(second)?.separatorStyle == "space")
            precondition(PluginPreferences.configuration(second)?.expand == true)
            precondition(PluginPreferences.configuration(second)?.spaceWidth == 64)
        }
    }

    @MainActor
    static func testDeletingLastPluginDoesNotRestoreDefaults() {
        withIsolatedPreferences {
            PluginPreferences.configurations = []
            let id = PluginPreferences.add(kind: "clock")
            PluginPreferences.remove(id)
            precondition(PluginPreferences.configurations.isEmpty)
            precondition(PluginPreferences.defaults.data(forKey: "pluginConfigurations") != nil)
        }
    }
    @MainActor
    static func testLauncherDrops() {
        withIsolatedPreferences {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appendingPathComponent("Test App.app")
            let contents = app.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/TestApp")
            try! FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "TestApp",
                                       "CFBundleIdentifier": "dev.plank.test-app"]
            let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try! data.write(to: contents.appendingPathComponent("Info.plist"))
            try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            PluginPreferences.configurations = []
            let first = PluginPreferences.add(kind: "launcher")
            let second = PluginPreferences.add(kind: "launcher")
            precondition(LauncherStore.add([app, app], to: first))
            precondition(LauncherStore.paths(for: first) == [app.standardizedFileURL.resolvingSymlinksInPath().path])
            precondition(LauncherStore.paths(for: second).isEmpty)
            precondition(!LauncherStore.add([app, executable], to: second))
            precondition(LauncherStore.paths(for: second).isEmpty)
            precondition(!LauncherStore.add([URL(string: "https://example.com/App.app")!], to: first))
            PluginPreferences.setOrder([second, first])
            precondition(LauncherStore.paths(for: first).count == 1)
            LauncherStore.remove(LauncherStore.paths(for: first)[0], from: first)
            precondition(LauncherStore.paths(for: first).isEmpty)
            precondition(LauncherStore.add([app], to: first))
            PluginPreferences.remove(first)
            precondition(LauncherStore.paths(for: first).isEmpty)
        }
    }

    @MainActor
    static func testLauncherSorting() {
        withIsolatedPreferences {
            PluginPreferences.configurations = []
            let first = PluginPreferences.add(kind: "launcher")
            let other = PluginPreferences.add(kind: "launcher")
            let paths = ["/A.app", "/B.app", "/C.app", "/D.app"]
            PluginPreferences.defaults.set(paths, forKey: "plugin.\(first).launcherPaths")
            PluginPreferences.defaults.set(["/Other.app"], forKey: "plugin.\(other).launcherPaths")
            precondition(LauncherStore.move("/B.app", to: 4, in: first))
            precondition(LauncherStore.paths(for: first) == ["/A.app", "/C.app", "/D.app", "/B.app"])
            precondition(LauncherStore.move("/B.app", to: 0, in: first))
            precondition(LauncherStore.paths(for: first) == ["/B.app", "/A.app", "/C.app", "/D.app"])
            precondition(!LauncherStore.move("/B.app", to: 1, in: first))
            precondition(!LauncherStore.move("/Missing.app", to: 0, in: first))
            precondition(LauncherStore.paths(for: other) == ["/Other.app"])
            precondition(LauncherStore.move("/D.app", to: -20, in: first))
            precondition(LauncherStore.paths(for: first) == ["/D.app", "/B.app", "/A.app", "/C.app"])
            precondition(LauncherStore.move("/D.app", to: 200, in: first))
            precondition(LauncherStore.paths(for: first) == ["/B.app", "/A.app", "/C.app", "/D.app"])
        }
    }

    @MainActor
    static func testTaskbarSettingsCompatibility() {
        withIsolatedPreferences {
            let oldJSON = #"[{"id":"taskbar","kind":"taskbar","name":"任务栏","enabled":true,"separatorStyle":"line","spaceWidth":24,"expand":false,"showSeconds":false}]"#
            PluginPreferences.defaults.set(Data(oldJSON.utf8), forKey: "pluginConfigurations")
            precondition(PluginPreferences.order == ["taskbar"])
            precondition(PluginPreferences.configuration("taskbar")?.taskbarShowsTitles == false)
            precondition(PluginPreferences.configuration("taskbar")?.taskbarButtonMaximumWidth == 180)
            let other = PluginPreferences.add(kind: "taskbar")
            PluginPreferences.update("taskbar") {
                $0.taskbarStyle = "iconAndTitle"
                $0.taskbarMaximumWidth = 120
            }
            precondition(PluginPreferences.configuration("taskbar")?.taskbarShowsTitles == true)
            precondition(PluginPreferences.configuration("taskbar")?.taskbarButtonMaximumWidth == 120)
            precondition(PluginPreferences.configuration(other)?.taskbarShowsTitles == false)
            PluginPreferences.update("taskbar") { $0.taskbarMaximumWidth = -1 }
            precondition(PluginPreferences.configuration("taskbar")?.taskbarButtonMaximumWidth == 80)
            PluginPreferences.update("taskbar") { $0.taskbarMaximumWidth = 900 }
            precondition(PluginPreferences.configuration("taskbar")?.taskbarButtonMaximumWidth == 400)
        }
    }

    @MainActor
    static func testPanelHeightSettings() {
        withIsolatedPreferences {
            precondition(PanelPreferences.height == 64)
            for (preset, height) in [(PanelHeightPreset.small, 48.0), (.medium, 64.0), (.large, 80.0)] {
                PanelPreferences.setHeight(preset: preset, customHeight: 55)
                precondition(PanelPreferences.height == height)
                precondition(PanelPreferences.customHeight == 55)
            }
            PanelPreferences.setHeight(preset: .custom, customHeight: 55)
            precondition(PanelPreferences.height == 55)
            PanelPreferences.setHeight(preset: .small, customHeight: PanelPreferences.customHeight)
            PanelPreferences.setHeight(preset: .custom, customHeight: PanelPreferences.customHeight)
            precondition(PanelPreferences.height == 55)
            PanelPreferences.setHeight(preset: .custom, customHeight: -10)
            precondition(PanelPreferences.height == 32)
            precondition(PanelMetrics.buttonSize(for: PanelPreferences.height) == PanelPreferences.height)
            PanelPreferences.setHeight(preset: .custom, customHeight: 1000)
            precondition(PanelPreferences.height == 128)
            PanelPreferences.setHeight(preset: .custom, customHeight: .nan)
            precondition(PanelPreferences.height == 64)
        }
    }

    static func testApplicationCatalog() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ path: String, name: String, background: Bool = false, packageType: String = "APPL") -> URL {
            let app = root.appendingPathComponent(path)
            let contents = app.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/App")
            try! FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundlePackageType": packageType, "CFBundleExecutable": "App",
                                     "CFBundleDisplayName": name, "LSUIElement": background]
            let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try! data.write(to: contents.appendingPathComponent("Info.plist"))
            try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return app
        }
        let primary = makeApp("Applications/Cafe.app", name: "Café Editor")
        let utility = makeApp("Applications/Utilities/Tools.app", name: "Tools")
        let finder = makeApp("Applications/Finder.app", name: "访达", packageType: "FNDR")
        _ = makeApp("Applications/Agent.app", name: "Background Agent", background: true)
        _ = makeApp("Applications/Cafe.app/Contents/Helpers/Worker.app", name: "Worker")
        _ = makeApp("Applications/.Hidden.app", name: "Hidden")
        let found = ApplicationCatalog.scan(roots: [root.appendingPathComponent("Applications"), primary,
                                                   root.appendingPathComponent("Missing")])
        precondition(found.count == 3)
        precondition(Set(found.map { $0.url.lastPathComponent }) == Set([primary.lastPathComponent, utility.lastPathComponent, finder.lastPathComponent]))
        precondition(CatalogApplication.matching("CAFE editor", in: found).count == 1)
        precondition(CatalogApplication.matching("tools", in: found).count == 1)
        precondition(CatalogApplication.matching("Finder", in: found).count == 1)
        precondition(CatalogApplication.matching("not installed", in: found).isEmpty)
    }

    @MainActor
    static func testDockRestorationAndRecovery() {
        withIsolatedPreferences {
            let backend = TestDockBackend()
            let original = DockSettingsSnapshot(autoHide: false, autoHideDelay: nil)
            backend.current = original
            let first = DockReplacementSession(backend: backend, defaults: PluginPreferences.defaults)
            try! first.activate()
            precondition(first.isActive && backend.current.autoHide == true)
            // Simulate a new process after an interrupted session. It must not
            // overwrite the original values with the already-hidden settings.
            let recovered = DockReplacementSession(backend: backend, defaults: PluginPreferences.defaults)
            try! recovered.activate()
            try! recovered.restore()
            precondition(backend.current == original)
            precondition(PluginPreferences.defaults.data(forKey: "originalSystemDockSettings") == nil)
            backend.failNextReload = true
            let failing = DockReplacementSession(backend: backend, defaults: PluginPreferences.defaults)
            do { try failing.activate(); preconditionFailure("Expected reload failure") } catch {}
            precondition(backend.current == original && !failing.isActive)
            precondition(PluginPreferences.defaults.data(forKey: "originalSystemDockSettings") == nil)
            // A failed restore keeps the recovery snapshot for another attempt.
            try! failing.activate()
            backend.failRestore = true
            do { try failing.restore(); preconditionFailure("Expected restoration failure") } catch {}
            precondition(PluginPreferences.defaults.data(forKey: "originalSystemDockSettings") != nil)
            backend.failRestore = false
            try! failing.restore()
            precondition(backend.current == original)
        }
    }

    static func testReservedWorkspace() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let visible = CGRect(x: 0, y: 4, width: 1600, height: 968)
        let maximized = visible
        let adjusted = ReservedWorkspace.adjustedFrame(maximized, screen: screen, visible: visible, panelHeight: 64)!
        precondition(adjusted == CGRect(x: 0, y: 64, width: 1600, height: 908))
        let tile = CGRect(x: 800, y: 4, width: 800, height: 968)
        precondition(ReservedWorkspace.adjustedFrame(tile, screen: screen, visible: visible, panelHeight: 80)?.minY == 80)
        precondition(ReservedWorkspace.adjustedFrame(CGRect(x: 100, y: 100, width: 800, height: 600), screen: screen, visible: visible, panelHeight: 64) == nil)
        precondition(ReservedWorkspace.adjustedFrame(CGRect(x: 1600, y: 0, width: 1600, height: 1000), screen: screen, visible: visible, panelHeight: 64) == nil)
        precondition(ReservedWorkspace.adjustedFrame(screen, screen: screen, visible: visible, panelHeight: 64) == nil)
        // Regression: hiding a 75 pt Dock must let the old maximized window
        // expand down to a smaller Plank, not keep the old Dock's blank strip.
        let oldVisible = CGRect(x: 0, y: 75, width: 1600, height: 897)
        precondition(ReservedWorkspace.adjustedFrame(oldVisible, screen: screen, visible: visible,
            panelHeight: 48, previousVisible: oldVisible) == CGRect(x: 0, y: 48, width: 1600, height: 924))
        // A larger Plank still shrinks the same original window.
        precondition(ReservedWorkspace.adjustedFrame(oldVisible, screen: screen, visible: visible,
            panelHeight: 96, previousVisible: oldVisible)?.minY == 96)
        let oldTile = CGRect(x: 800, y: 75, width: 800, height: 897)
        let expandedTile = ReservedWorkspace.adjustedFrame(oldTile, screen: screen, visible: visible,
            panelHeight: 48, previousVisible: oldVisible)!
        precondition(expandedTile == CGRect(x: 800, y: 48, width: 800, height: 924))
        precondition(expandedTile.maxY == oldTile.maxY)
        precondition(ReservedWorkspace.adjustedFrame(oldVisible, screen: screen, visible: visible,
            panelHeight: 32, previousVisible: oldVisible)?.minY == 32)
        precondition(ReservedWorkspace.adjustedFrame(expandedTile, screen: screen, visible: visible,
            panelHeight: 48, previousVisible: oldVisible) == nil)
        let ordinary = CGRect(x: 100, y: 60, width: 800, height: 912)
        precondition(ReservedWorkspace.adjustedFrame(ordinary, screen: screen, visible: visible,
            panelHeight: 48, previousVisible: oldVisible) == nil)
        // Recovery data may only be reused on the original display/geometry.
        let snapshot = DockWorkspaceSnapshot(displayID: 1, screen: screen, visible: oldVisible)
        let saved = try! JSONEncoder().encode(snapshot)
        let recovered = try! JSONDecoder().decode(DockWorkspaceSnapshot.self, from: saved)
        precondition(recovered.previousVisibleFrame(displayID: 1, screen: screen) == oldVisible)
        precondition(recovered.previousVisibleFrame(displayID: 2, screen: screen) == nil)
        precondition(recovered.previousVisibleFrame(displayID: 1, screen: CGRect(x: 0, y: 0, width: 1200, height: 800)) == nil)
        let offsetScreen = CGRect(x: -1600, y: -400, width: 1600, height: 1000)
        let offsetVisible = CGRect(x: -1600, y: -396, width: 1600, height: 968)
        precondition(ReservedWorkspace.adjustedFrame(offsetVisible, screen: offsetScreen, visible: offsetVisible, panelHeight: 64)?.minY == -336)
        let ax = ReservedWorkspace.flip(adjusted, primaryTop: 1000)
        precondition(ReservedWorkspace.flip(ax, primaryTop: 1000) == adjusted)
    }

}

@MainActor
private final class TestDockBackend: DockSettingsBackend {
    var current = DockSettingsSnapshot(autoHide: nil, autoHideDelay: nil)
    var failNextReload = false
    var failRestore = false
    func snapshot() -> DockSettingsSnapshot { current }
    func hide() throws { current = DockSettingsSnapshot(autoHide: true, autoHideDelay: 86400) }
    func restore(_ snapshot: DockSettingsSnapshot) throws {
        if failRestore { throw CocoaError(.fileWriteUnknown) }
        current = snapshot
    }
    func reload() throws {
        if failNextReload { failNextReload = false; throw CocoaError(.fileWriteUnknown) }
    }
}
