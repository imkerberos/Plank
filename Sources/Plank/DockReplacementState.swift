import Foundation
import CoreGraphics

struct DockSettingsSnapshot: Codable, Equatable {
    var autoHide: Bool?
    var autoHideDelay: Double?
}

@MainActor
protocol DockSettingsBackend {
    func snapshot() -> DockSettingsSnapshot
    func hide() throws
    func restore(_ snapshot: DockSettingsSnapshot) throws
    func reload() throws
}

/// Persist the original Dock settings before changing them so restoration also
/// works on the next launch after an interrupted session.
@MainActor
final class DockReplacementSession {
    private let backend: any DockSettingsBackend
    private let defaults: UserDefaults
    private let backupKey = "originalSystemDockSettings"
    private(set) var isActive = false
    var hasRecoverySnapshot: Bool { defaults.data(forKey: backupKey) != nil }

    init(backend: any DockSettingsBackend, defaults: UserDefaults) {
        self.backend = backend
        self.defaults = defaults
    }

    func activate() throws {
        guard !isActive else { return }
        if defaults.data(forKey: backupKey) == nil {
            defaults.set(try JSONEncoder().encode(backend.snapshot()), forKey: backupKey)
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        }
        do {
            try backend.hide()
            try backend.reload()
            isActive = true
        } catch {
            try? restore()
            throw error
        }
    }

    func restore() throws {
        guard let data = defaults.data(forKey: backupKey) else { isActive = false; return }
        let snapshot = try JSONDecoder().decode(DockSettingsSnapshot.self, from: data)
        try backend.restore(snapshot)
        try backend.reload()
        defaults.removeObject(forKey: backupKey)
        isActive = false
    }
}

struct DockWorkspaceSnapshot: Codable, Equatable {
    let displayID: UInt32
    let screen: CGRect
    let visible: CGRect

    func previousVisibleFrame(displayID: UInt32, screen: CGRect) -> CGRect? {
        self.displayID == displayID && ReservedWorkspace.approximatelyEqual(self.screen, screen) ? visible : nil
    }
}

enum ReservedWorkspace {
    /// AppKit coordinates (bottom-left origin). Match either today's work area
    /// or the pre-hide Dock boundary, then resize in either direction.
    static func adjustedFrame(_ frame: CGRect, screen: CGRect, visible: CGRect,
                              panelHeight: CGFloat, previousVisible: CGRect? = nil) -> CGRect? {
        let overlap = frame.intersection(screen)
        guard !overlap.isNull, overlap.width * overlap.height > frame.width * frame.height * 0.5 else { return nil }
        func matches(_ area: CGRect, oldDock: Bool) -> Bool {
            let touchesBottom = oldDock ? abs(frame.minY - area.minY) <= 8 : frame.minY <= area.minY + 8
            return abs(frame.maxY - area.maxY) <= 12 && touchesBottom
                && frame.height >= area.height * 0.65 && frame.width >= area.width * 0.25
        }
        guard matches(visible, oldDock: false)
                || previousVisible.map({ matches($0, oldDock: true) }) == true else { return nil }
        let bottom = screen.minY + panelHeight
        guard abs(frame.minY - bottom) > 1, frame.maxY - bottom >= 160 else { return nil }
        return CGRect(x: frame.minX, y: bottom, width: frame.width, height: frame.maxY - bottom)
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3
            && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    static func flip(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
