import AppKit
import ApplicationServices

private func plankWindowChanged(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let service = Unmanaged<WindowSpaceGuard>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor [weak service] in service?.scheduleUpdate() }
}

@MainActor
final class WindowSpaceGuard {
    private struct Adjustment {
        let window: AXUIElement
        let pid: pid_t
        let original: CGRect
        var applied: CGRect
    }
    private var adjustments: [Adjustment] = []
    private var previousWorkspace: DockWorkspaceSnapshot?
    private let workspaceBackupKey = "preDockWorkspace"
    private var timer: Timer?
    private var pendingUpdate: Task<Void, Never>?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedWindow: AXUIElement?
    private(set) var isFullScreen = false
    var onFullScreenChanged: ((Bool) -> Void)?
    var onPermissionLost: (() -> Void)?

    /// This must run before the Dock is hidden or restarted. Keep the original
    /// boundary across crash recovery instead of replacing it with a hidden Dock.
    func prepareForDockChange(reuseSaved: Bool) {
        if reuseSaved, let data = UserDefaults.standard.data(forKey: workspaceBackupKey),
           let saved = try? JSONDecoder().decode(DockWorkspaceSnapshot.self, from: data) {
            previousWorkspace = saved
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        let snapshot = DockWorkspaceSnapshot(displayID: displayID(screen), screen: screen.frame, visible: screen.visibleFrame)
        previousWorkspace = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: workspaceBackupKey)
            UserDefaults.standard.synchronize()
        }
    }

    func clearPreparedWorkspace() {
        previousWorkspace = nil
        UserDefaults.standard.removeObject(forKey: workspaceBackupKey)
    }

    private func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleUpdate()
    }

    func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    func stop(restore: Bool) {
        timer?.invalidate()
        timer = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
        detachObserver()
        if restore && AXIsProcessTrusted() {
            for record in adjustments {
                if let current = frame(record.window), ReservedWorkspace.approximatelyEqual(current, record.applied) {
                    _ = setFrame(record.original, of: record.window)
                }
            }
        }
        adjustments.removeAll()
        setFullScreen(false)
    }

    func update() {
        guard timer != nil else { return }
        guard AXIsProcessTrusted() else { onPermissionLost?(); return }
        guard let screen = NSScreen.screens.first else { return }
        let primaryTop = screen.frame.maxY
        let previousVisible = previousWorkspace?.previousVisibleFrame(displayID: displayID(screen), screen: screen.frame)
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.15)
            let focused = element(app, kAXFocusedWindowAttribute)
            setFullScreen(focused.map { bool($0, "AXFullScreen") } ?? false)
            observe(pid: front.processIdentifier, app: app, focused: focused)
        }

        // Only consider public on-screen window geometry. Do not touch windows
        // in other Spaces, hidden applications, dialogs, or native full screen.
        let visible = visibleWindows()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && visible[$0.processIdentifier] != nil
        }
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            guard let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            let candidates = windows.prefix(30).compactMap { window -> (AXUIElement, CGRect)? in
                guard !bool(window, kAXMinimizedAttribute), !bool(window, "AXFullScreen"),
                      attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      let rect = frame(window) else { return nil }
                return (window, rect)
            }
            for (window, currentAX) in candidates {
                let onScreenMatches = visible[app.processIdentifier]?.filter { ReservedWorkspace.approximatelyEqual($0, currentAX) }.count ?? 0
                let accessibleMatches = candidates.filter { ReservedWorkspace.approximatelyEqual($0.1, currentAX) }.count
                // Identical geometry can occur in different Spaces. When the
                // public metadata cannot distinguish them, leave them alone.
                guard onScreenMatches > 0, accessibleMatches <= onScreenMatches else { continue }
                let current = ReservedWorkspace.flip(currentAX, primaryTop: primaryTop)
                var index = adjustments.firstIndex { $0.pid == app.processIdentifier && CFEqual($0.window, window) }
                var source = current
                if let existing = index {
                    if ReservedWorkspace.approximatelyEqual(currentAX, adjustments[existing].applied) {
                        source = ReservedWorkspace.flip(adjustments[existing].original, primaryTop: primaryTop)
                    } else {
                        // Respect a subsequent manual move/resize by the user.
                        adjustments.remove(at: existing)
                        index = nil
                    }
                }
                guard let target = ReservedWorkspace.adjustedFrame(source, screen: screen.frame,
                    visible: screen.visibleFrame, panelHeight: PanelPreferences.height, previousVisible: previousVisible) else { continue }
                let targetAX = ReservedWorkspace.flip(target, primaryTop: primaryTop)
                guard !ReservedWorkspace.approximatelyEqual(currentAX, targetAX), setFrame(targetAX, of: window) else { continue }
                if let index { adjustments[index].applied = targetAX }
                else { adjustments.append(Adjustment(window: window, pid: app.processIdentifier, original: currentAX, applied: targetAX)) }
            }
        }
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        adjustments.removeAll { !runningPIDs.contains($0.pid) }
    }

    private func setFullScreen(_ value: Bool) {
        if isFullScreen != value { isFullScreen = value; onFullScreenChanged?(value) }
    }

    private func visibleWindows() -> [pid_t: [CGRect]] {
        guard let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: [CGRect]] = [:]
        for item in items {
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            result[pid, default: []].append(rect)
        }
        return result
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func bool(_ element: AXUIElement, _ name: String) -> Bool { (attribute(element, name) as? NSNumber)?.boolValue ?? false }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(parent, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    private func setFrame(_ rect: CGRect, of element: AXUIElement) -> Bool {
        var sizeSettable = DarwinBoolean(false)
        var positionSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable) == .success, sizeSettable.boolValue,
              AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable) == .success, positionSettable.boolValue else { return false }
        let previous = frame(element)
        var point = rect.origin
        var size = rect.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) == .success
        let moved = resized && AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue) == .success
        if moved, let actual = frame(element), ReservedWorkspace.approximatelyEqual(actual, rect) { return true }
        if let previous {
            var oldSize = previous.size
            var oldPoint = previous.origin
            if let value = AXValueCreate(.cgSize, &oldSize) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
            if let value = AXValueCreate(.cgPoint, &oldPoint) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
        }
        return false
    }

    private func observe(pid: pid_t, app: AXUIElement, focused: AXUIElement?) {
        if observedPID == pid, let previous = observedWindow, let focused, CFEqual(previous, focused) { return }
        detachObserver()
        var created: AXObserver?
        guard AXObserverCreate(pid, plankWindowChanged, &created) == .success, let created else { return }
        observer = created
        observedPID = pid
        observedWindow = focused
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(created, app, name as CFString, context)
        }
        if let focused {
            for name in [kAXResizedNotification, kAXMovedNotification] {
                AXObserverAddNotification(created, focused, name as CFString, context)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func detachObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedPID = nil
        observedWindow = nil
    }
}
