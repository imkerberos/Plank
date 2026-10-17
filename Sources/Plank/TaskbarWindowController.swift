import AppKit
import ApplicationServices

@MainActor
enum TaskbarWindowController {
    /// A second click minimizes the active window. Other clicks retain the
    /// Launch Services reopen behavior, including restoring minimized windows.
    static func minimizeFocusedWindow(of application: NSRunningApplication) -> Bool {
        guard !application.isTerminated, !application.isHidden,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              hasOnScreenWindow(pid: application.processIdentifier) else { return false }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return false }

        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Prefer the focused window, falling back to the main window for apps
        // that do not expose a focused window. Never minimize unrelated windows.
        guard let window = windowAttribute(app, kAXFocusedWindowAttribute)
                ?? windowAttribute(app, kAXMainWindowAttribute),
              attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              let minimized = attribute(window, kAXMinimizedAttribute) as? NSNumber,
              !minimized.boolValue,
              (attribute(window, "AXFullScreen") as? NSNumber)?.boolValue != true else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func windowAttribute(_ app: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func hasOnScreenWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
    }
}
