import AppKit
import ApplicationServices

extension Notification.Name {
    static let plankBadgesChanged = Notification.Name("PlankBadgesChanged")
}

/// AXStatusLabel is supplied by the Dock, rather than by NSRunningApplication.
/// Missing/unsupported labels are left empty; no notification counts are guessed.
enum DockBadgeReader {
    static func read(pid: pid_t) -> [String: AppBadgeContent]? {
        let dock = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(dock, 0.1)
        guard let children = attribute(dock, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var badges: [String: AppBadgeContent] = [:]
        var visited = 0
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 4, visited < 500 else { return }
            visited += 1
            if attribute(element, kAXSubroleAttribute) as? String == "AXApplicationDockItem" {
                guard let status = attribute(element, "AXStatusLabel") as? String,
                      let badge = AppBadgeContent(status) else { return }
                let value = attribute(element, kAXURLAttribute)
                let url: URL?
                if let fileURL = value as? URL { url = fileURL }
                else if let string = value as? String { url = URL(string: string) }
                else { url = nil }
                if let url, url.isFileURL {
                    badges[url.standardizedFileURL.resolvingSymlinksInPath().path] = badge
                }
                return
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { visit(child, depth: depth + 1) }
            }
        }
        for child in children { visit(child, depth: 0) }
        return badges
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

@MainActor
final class DockBadgeCenter {
    static let shared = DockBadgeCenter()
    private var badges: [String: AppBadgeContent] = [:]
    private var timer: Timer?
    private var pending: Task<Void, Never>?

    func badge(for path: String) -> AppBadgeContent? { badges[path] }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        apply([:])
    }

    /// Finish the initial Dock snapshot before startup changes restart the Dock.
    /// The Accessibility work still runs off the main thread.
    func refreshNow() async {
        refresh()
        await pending?.value
    }

    private func refresh() {
        guard timer != nil, pending == nil else { return }
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            apply([:])
            return
        }
        // Keep Accessibility IPC off the main thread so a busy Dock cannot
        // stall panel clicks, drag sessions, or animation.
        pending = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) { DockBadgeReader.read(pid: pid) }.value
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            if let snapshot { self.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: [String: AppBadgeContent]) {
        guard badges != snapshot else { return }
        badges = snapshot
        NotificationCenter.default.post(name: .plankBadgesChanged, object: self)
    }
}
