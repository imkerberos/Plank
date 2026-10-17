import AppKit

@MainActor
final class TaskbarWindowOrder {
    static let shared = TaskbarWindowOrder()
    var onChange: (() -> Void)?
    private var state = TaskbarOrderState()
    private var timer: Timer?
    private var previousOrder: [pid_t] = []

    func start() {
        guard timer == nil else { return }
        update()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.timer != nil else { return }
                if self.update() { self.onChange?() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Include minimized, hidden, and other-Space windows so activating or
    /// minimizing an app cannot change the ordering of its existing windows.
    @discardableResult func update() -> Bool {
        let applications = runningApplications()
        let pids = Set(applications.map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return false }
        let snapshot = Set(windows.compactMap { item -> TaskbarOrderState.Window? in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            return TaskbarOrderState.Window(id: id, pid: pid)
        })
        state.observe(snapshot)
        let order = sorted(applications).map(\.processIdentifier)
        defer { previousOrder = order }
        return previousOrder != order
    }

    func sorted(_ applications: [NSRunningApplication]) -> [NSRunningApplication] {
        applications.sorted { lhs, rhs in
            let left = state.rank(for: lhs.processIdentifier)
            let right = state.rank(for: rhs.processIdentifier)
            switch (left, right) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let comparison = (lhs.localizedName ?? "").localizedStandardCompare(rhs.localizedName ?? "")
                return comparison == .orderedSame ? lhs.processIdentifier < rhs.processIdentifier : comparison == .orderedAscending
            }
        }
    }

    private func runningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }
}
