import AppKit
import ApplicationServices

@MainActor
private struct SystemDockBackend: DockSettingsBackend {
    private let domain = "com.apple.dock" as CFString

    func snapshot() -> DockSettingsSnapshot {
        DockSettingsSnapshot(
            autoHide: (CFPreferencesCopyValue("autohide" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue,
            autoHideDelay: (CFPreferencesCopyValue("autohide-delay" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.doubleValue
        )
    }

    func hide() throws {
        try write(autoHide: true, delay: 86400)
    }

    func restore(_ snapshot: DockSettingsSnapshot) throws {
        try write(autoHide: snapshot.autoHide, delay: snapshot.autoHideDelay)
    }

    private func write(autoHide: Bool?, delay: Double?) throws {
        CFPreferencesSetValue("autohide" as CFString, autoHide.map { NSNumber(value: $0) }, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("autohide-delay" as CFString, delay.map { NSNumber(value: $0) }, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw DockControlError.message("Unable to save system Dock settings.")
        }
    }

    func reload() throws {
        // Dock is supervised by launchd and restarts after this normal termination.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: data, as: UTF8.self)
            if !message.contains("No matching processes") { throw DockControlError.message("Unable to reload the Dock: \(message)") }
        }
    }
}

enum DockControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

@MainActor
final class SystemDockController {
    private let session = DockReplacementSession(backend: SystemDockBackend(), defaults: .standard)
    private let windows = WindowSpaceGuard()
    var onChange: (() -> Void)?
    var onFullScreenChanged: ((Bool) -> Void)? {
        get { windows.onFullScreenChanged }
        set { windows.onFullScreenChanged = newValue }
    }
    private(set) var status = "Accessibility access is required to keep maximized windows clear of the panel."
    var isActive: Bool { session.isActive }
    var isFullScreen: Bool { windows.isFullScreen }

    func start() {
        if PanelPreferences.hideSystemDock && AXIsProcessTrusted() {
            do { try enable() } catch { status = error.localizedDescription }
        } else {
            // Recover the Dock if the previous run ended before it could restore.
            do { try session.restore(); windows.clearPreparedWorkspace() } catch { status = error.localizedDescription }
            if PanelPreferences.hideSystemDock { status = "Grant Plank Accessibility access, then enable this option again." }
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
                status = "Allow Plank in Accessibility in System Settings, then enable this option again. The Dock has not been changed."
                return false
            }
            do {
                try enable()
                PanelPreferences.hideSystemDock = true
                return true
            } catch { status = error.localizedDescription; return false }
        } else {
            windows.stop(restore: true)
            do {
                try session.restore()
                windows.clearPreparedWorkspace()
                PanelPreferences.hideSystemDock = false
                status = "The original system Dock settings have been restored."
                onChange?()
                return true
            } catch {
                if session.isActive { windows.start() }
                status = error.localizedDescription
                onChange?()
                return false
            }
        }
    }

    private func enable() throws {
        if !session.isActive { windows.prepareForDockChange(reuseSaved: session.hasRecoverySnapshot) }
        do { try session.activate() }
        catch {
            if !session.hasRecoverySnapshot { windows.clearPreparedWorkspace() }
            throw error
        }
        status = "The system Dock is hidden. Maximized and tiled windows avoid Plank."
        windows.onPermissionLost = { [weak self] in
            guard let self else { return }
            self.windows.stop(restore: false)
            do { try self.session.restore(); self.windows.clearPreparedWorkspace() }
            catch { self.status = error.localizedDescription; self.onChange?(); return }
            self.status = "Accessibility access was lost. The Dock has been restored. Grant access again to enable this option."
            self.onChange?()
        }
        windows.start()
        onChange?()
    }

    func layoutChanged() { if isActive { windows.update() } }

    func stop() {
        windows.stop(restore: true)
        do { try session.restore(); windows.clearPreparedWorkspace() }
        catch { NSLog("Plank: Failed to restore the system Dock: %@", error.localizedDescription) }
    }
}
