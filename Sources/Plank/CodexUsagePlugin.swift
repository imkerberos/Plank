import AppKit
import SwiftUI

@MainActor
final class CodexUsageState: ObservableObject {
    @Published var usage: CodexUsageResponse?
    @Published var updatedAt: Date?
    @Published var error: String?
    @Published var loading = false
}

@MainActor
final class CodexUsagePlugin: NSObject, PanelPlugin, NSPopoverDelegate {
    let id: String
    private let button = CodexUsageButton()
    private let state = CodexUsageState()
    private let popover = NSPopover()
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var wakeObserver: NSObjectProtocol?
    private var active = false
    private var path: String?
    private var failures = 0
    private var height: NSLayoutConstraint!
    var view: NSView { button }

    init(id: String) {
        self.id = id
        super.init()
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = ""
        button.target = self
        button.action = #selector(togglePopover)
        button.translatesAutoresizingMaskIntoConstraints = false
        height = button.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 126), height])
        button.setAccessibilityLabel("Codex usage details")
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: CodexUsageDetails(state: state) { [weak self] in self?.fetch() })
    }

    func setPanelHeight(_ value: CGFloat) { height.constant = PanelMetrics.buttonSize(for: value) }

    func refresh() {
        let newPath = PluginPreferences.configuration(id)?.codexHomePath
        let changed = path != newPath
        path = newPath
        if changed {
            task?.cancel(); task = nil
            state.loading = false; state.usage = nil; state.updatedAt = nil; state.error = nil
            failures = 0
        }
        guard !active || changed else { return }
        active = true
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active else { return }
                    if self.state.updatedAt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true { self.fetch() }
                }
            }
        }
        fetch()
    }

    func stop() {
        active = false
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        state.loading = false
        closePopover()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func fetch() {
        guard active, task == nil else { return }
        timer?.invalidate(); timer = nil
        state.loading = true
        let currentPath = path
        task = Task { [weak self] in
            let result: Result<CodexUsageResponse, Error>
            do { result = .success(try await CodexUsageClient().fetch(homePath: currentPath)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.active else { return }
            self.state.loading = false
            self.task = nil
            switch result {
            case .success(let usage):
                self.state.usage = usage
                self.state.updatedAt = Date()
                self.state.error = nil
                self.failures = 0
            case .failure(let error):
                self.state.error = (error as? CodexUsageError)?.errorDescription ?? CodexUsageError.network.errorDescription
                self.failures = min(4, self.failures + 1)
            }
            self.updateLabel()
            let delay = min(3600, 300 * pow(2, Double(self.failures)))
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fetch() }
            }
            timer.tolerance = 30
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func updateLabel() {
        button.primaryRemaining = state.usage?.rateLimit?.primaryWindow?.remaining
        button.weeklyRemaining = state.usage?.rateLimit?.secondaryWindow?.remaining
        button.hasError = state.error != nil
        button.needsDisplay = true
        let primary = button.primaryRemaining.map { "\(Int($0.rounded()))%" } ?? "unavailable"
        let weekly = button.weeklyRemaining.map { "\(Int($0.rounded()))%" } ?? "unavailable"
        button.setAccessibilityValue("5h \(primary) remaining, Weekly \(weekly) remaining")
        button.toolTip = "Codex · Remaining quota" + (state.error.map { " · \($0)" } ?? "")
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover(); return }
        let event = NSApp.currentEvent.flatMap {
            $0.type == .leftMouseUp || $0.type == .leftMouseDown ? $0 : nil
        }
        if let host = popover.contentViewController?.view {
            host.layoutSubtreeIfNeeded()
            popover.contentSize = host.fittingSize
        }
        PanelPopover.show(popover, from: button, event: event)
        startMouseTracking()
    }

    private func closePopover() {
        popover.close()
        stopMouseTracking()
    }

    private func startMouseTracking() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if self.isInsidePopover(event) { return event }
            if self.isInsideButton(event) {
                self.closePopover()
                return nil
            }
            self.closePopover()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func stopMouseTracking() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    private func isInsidePopover(_ event: NSEvent) -> Bool {
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow { return true }
        return false
    }

    private func isInsideButton(_ event: NSEvent) -> Bool {
        if let panelWindow = button.window, event.window === panelWindow {
            let point = button.convert(event.locationInWindow, from: nil)
            return button.bounds.contains(point)
        }
        return false
    }

    func popoverDidClose(_ notification: Notification) { stopMouseTracking() }

    @objc private func manualRefresh() { fetch() }
    func addMenuItems(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Refresh Codex Usage", action: #selector(manualRefresh), keyEquivalent: "")
        item.target = self
        menu.addItem(.separator())
    }

    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent {
        CodexUsageSettings(configuration: configuration)
    }
}

/// Draw both quota rows inside one native button so the whole display remains clickable.
@MainActor
private final class CodexUsageButton: PanelMenuButton {
    var primaryRemaining: Double?
    var weeklyRemaining: Double?
    var hasError = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rowHeight = min(18, bounds.height / 2)
        let font = NSFont.monospacedDigitSystemFont(ofSize: rowHeight < 15 ? 9 : 11, weight: .medium)
        let top = bounds.midY + (isFlipped ? -rowHeight : rowHeight) / 2
        let bottom = bounds.midY + (isFlipped ? rowHeight : -rowHeight) / 2
        drawRow("5h", remaining: primaryRemaining, centerY: top, font: font)
        drawRow("W", remaining: weeklyRemaining, centerY: bottom, font: font)
    }

    private func drawRow(_ title: String, remaining: Double?, centerY: CGFloat, font: NSFont) {
        let color: NSColor = hasError ? .systemOrange : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(at: NSPoint(x: 5, y: centerY - textHeight / 2), withAttributes: attributes)
        let bar = NSRect(x: 26, y: centerY - 3, width: 54, height: 6)
        NSColor.labelColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        if let remaining {
            (hasError ? NSColor.systemOrange : remaining <= 10 ? .systemRed : .controlAccentColor).setFill()
            let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * min(100, max(0, remaining)) / 100, height: bar.height)
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
        let percent = remaining.map { "\(Int($0.rounded()))%" } ?? "—"
        let size = (percent as NSString).size(withAttributes: attributes)
        (percent as NSString).draw(at: NSPoint(x: bounds.width - 5 - size.width, y: centerY - textHeight / 2), withAttributes: attributes)
    }
}

private struct CodexUsageDetails: View {
    @ObservedObject var state: CodexUsageState
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            quotaRow("5h", window: state.usage?.rateLimit?.primaryWindow, weekly: false)
            quotaRow("Weekly", window: state.usage?.rateLimit?.secondaryWindow, weekly: true)
            if let error = state.error {
                Text((state.usage == nil ? "" : "Last successful data · ") + error)
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(state.loading)
                if state.loading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14).frame(width: 320)
    }

    private func quotaRow(_ title: String, window: CodexUsageResponse.Window?, weekly: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            Text(window.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                .foregroundStyle(.secondary).monospacedDigit()
            Text(resetText(window, weekly: weekly))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(window.map { "\(Int($0.remaining.rounded())) percent remaining" } ?? "unavailable"), resets \(resetText(window, weekly: weekly))")
        .help("Remaining quota · Reset time")
    }

    private func resetText(_ window: CodexUsageResponse.Window?, weekly: Bool) -> String {
        guard let received = state.updatedAt, let reset = window?.resetDate(receivedAt: received) else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = weekly ? "M月d日" : "HH:mm"
        return formatter.string(from: reset)
    }
}

@MainActor
private final class CodexUsageSettings: PluginSettingsContent {
    private let path = NSTextField()
    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "Codex Usage", windowHeight: 480)
        path.stringValue = configuration.codexHomePath ?? ""
        path.placeholderString = "CODEX_HOME or ~/.codex"
        path.target = self
        path.action = #selector(requestSave)
        path.widthAnchor.constraint(equalToConstant: 250).isActive = true
        options = [SettingsUI.row("Codex home", control: path),
                   SettingsUI.help("Optional directory containing auth.json. Press Return to apply. Otherwise uses Plank’s CODEX_HOME environment or ~/.codex. Apps launched from Finder may not inherit your shell environment."),
                   SettingsUI.help("Reads existing OAuth credentials before each request. Refreshes every 5 minutes, with backoff on errors. No Codex process is started. Sign in again through Codex if authentication expires.")]
    }
    override func save(to configuration: inout PluginConfiguration) {
        let value = path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.codexHomePath = value.isEmpty ? nil : value
    }
}
