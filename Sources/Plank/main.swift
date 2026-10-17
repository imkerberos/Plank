import AppKit

@MainActor
final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: Panel!
    private let systemDock = SystemDockController()
    private let stack = PanelStackView()
    private let scroll = PanelScrollView()
    private var scrollLeading: NSLayoutConstraint!
    private var plugins: [any PanelPlugin] = []
    private var pluginsController: PluginsWindowController?
    private var pluginSettings: [String: PluginSettingsWindowController] = [:]
    private var stackWidth: NSLayoutConstraint!
    private var observers: [NSObjectProtocol] = []
    private var movingPluginID: String?
    private var settingsController: SettingsWindowController?
    private var widthPercentage: Double {
        let stored = UserDefaults.standard.object(forKey: "panelWidthPercentage") as? Double ?? 80
        return stored.isFinite ? min(100, max(10, stored)) : 80
    }

    private func makePanelMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let pluginsItem = menu.addItem(withTitle: "Plugins…", action: #selector(showPlugins), keyEquivalent: "")
        pluginsItem.target = self
        let lock = menu.addItem(withTitle: "Lock Panel", action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self
        lock.state = PanelPreferences.isLocked ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Plank", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleLock() {
        PanelPreferences.isLocked.toggle()
        movingPluginID = nil
        refresh()
    }

    private func makePluginMenu(_ plugin: any PanelPlugin) -> NSMenu {
        let menu = NSMenu()
        let title = PluginPreferences.configuration(plugin.id)?.name ?? plugin.id
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let move = menu.addItem(withTitle: movingPluginID == plugin.id ? "Cancel Move" : "Move",
                                action: #selector(movePlugin(_:)), keyEquivalent: "")
        move.target = self
        move.representedObject = plugin.id
        move.isEnabled = !PanelPreferences.isLocked
        menu.autoenablesItems = false
        plugin.addMenuItems(to: menu)
        let hide = menu.addItem(withTitle: "Hide \(title)", action: #selector(togglePlugin(_:)), keyEquivalent: "")
        hide.target = self
        hide.representedObject = plugin.id
        let settings = menu.addItem(withTitle: "Plugin Settings…", action: #selector(showPluginSettings(_:)), keyEquivalent: "")
        settings.target = self
        settings.representedObject = plugin.id
        return menu
    }

    @objc private func movePlugin(_ sender: NSMenuItem) {
        guard !PanelPreferences.isLocked else { return }
        guard let id = sender.representedObject as? String else { return }
        movingPluginID = movingPluginID == id ? nil : id
        refresh()
    }

    private func dropPlugin(_ id: String, at windowPoint: NSPoint) {
        guard !PanelPreferences.isLocked, panel.contentView?.bounds.contains(windowPoint) == true else {
            movingPluginID = nil
            refresh()
            return
        }
        let point = stack.convert(windowPoint, from: nil)
        let containers = stack.arrangedSubviews.compactMap { $0 as? PluginContainer }
            .filter { $0.pluginID != id }
        var order = PluginPreferences.order.filter { $0 != id }
        if let next = containers.first(where: { point.x < $0.frame.midX }),
           let index = order.firstIndex(of: next.pluginID) {
            order.insert(id, at: index)
        } else {
            order.append(id)
        }
        PluginPreferences.setOrder(order)
        movingPluginID = nil
        refresh()
    }

    @objc private func togglePlugin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PluginPreferences.setEnabled(!PluginPreferences.isEnabled(id), for: id)
        if movingPluginID == id { movingPluginID = nil }
        refresh()
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                percentage: widthPercentage,
                onChange: { [weak self] value in
                    UserDefaults.standard.set(value, forKey: "panelWidthPercentage")
                    self?.refresh()
                },
                onHeightChanged: { [weak self] in self?.refresh() },
                dockEnabled: systemDock.isActive,
                dockStatusText: systemDock.status,
                onDockChanged: { [weak self] enabled in
                    guard let self else { return (false, "") }
                    self.systemDock.setEnabled(enabled)
                    return (self.systemDock.isActive, self.systemDock.status)
                },
                onShowPlugins: { [weak self] in self?.showPlugins() }
            )
        }
        settingsController?.reloadDockState(enabled: systemDock.isActive, status: systemDock.status)
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPlugins() {
        if pluginsController == nil {
            pluginsController = PluginsWindowController(
                onChange: { [weak self] in self?.movingPluginID = nil; self?.refresh() },
                onSettings: { [weak self] id in self?.openPluginSettings(id) }
            )
        }
        pluginsController?.reload()
        pluginsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        pluginsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPluginSettings(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { openPluginSettings(id) }
    }

    private func openPluginSettings(_ id: String) {
        guard let config = PluginPreferences.configuration(id) else { return }
        if pluginSettings[id] == nil {
            pluginSettings[id] = PluginSettingsWindowController(configuration: config) { [weak self] in
                self?.refresh()
            }
        }
        pluginSettings[id]?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        pluginSettings[id]?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = Panel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false

        let background = PanelBackgroundView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.menu = makePanelMenu()
        panel.contentView = background

        let handle = PanelHandle(title: "Panel", menu: makePanelMenu(), isPanel: true)
        background.addSubview(handle)

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        scroll.documentView = stack

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stackWidth = stack.widthAnchor.constraint(equalToConstant: 100)
        stackWidth.isActive = true
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24)
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            handle.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            scrollLeading,
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor)
        ])

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // Activating Plank to focus a popover must not reparent its anchor.
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                if notification.name == NSWorkspace.didActivateApplicationNotification,
                   activatedPID == ProcessInfo.processInfo.processIdentifier { return }
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        systemDock.onChange = { [weak self] in
            guard let self else { return }
            self.refresh()
            self.settingsController?.reloadDockState(enabled: self.systemDock.isActive, status: self.systemDock.status)
        }
        systemDock.onFullScreenChanged = { [weak self] fullScreen in
            if fullScreen { self?.panel.orderOut(nil) }
            else { self?.panel.orderFrontRegardless() }
        }
        refresh()
        systemDock.start()
        if !systemDock.isFullScreen { panel.orderFrontRegardless() }
    }

    private func refresh() {
        let configurations = PluginPreferences.configurations
        let taskbarOrder = TaskbarWindowOrder.shared
        taskbarOrder.onChange = { [weak self] in self?.refresh() }
        if configurations.contains(where: { $0.kind == "taskbar" && $0.enabled }) {
            taskbarOrder.start()
            taskbarOrder.update()
        } else {
            taskbarOrder.stop()
        }
        let ids = Set(configurations.map(\.id))
        for plugin in plugins where !ids.contains(plugin.id) { plugin.stop() }
        plugins = configurations.map { config in
            plugins.first(where: { $0.id == config.id }) ?? makePlugin(config)
        }
        for id in Array(pluginSettings.keys) where !ids.contains(id) {
            pluginSettings.removeValue(forKey: id)?.close()
        }
        pluginsController?.reload()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let screen = NSScreen.screens.first else { return }
        let width = screen.frame.width * widthPercentage / 100
        let height = PanelPreferences.height
        let locked = PanelPreferences.isLocked
        panel.collectionBehavior = systemDock.isActive ? [.canJoinAllSpaces] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        scrollLeading.constant = locked ? 0 : 24
        scroll.menu = makePanelMenu()
        stack.menu = makePanelMenu()
        panel.contentView?.layer?.cornerRadius = widthPercentage == 100 ? 0 : 12
        // Rebuild menus so checkmarks reflect changes made from either entry point.
        panel.contentView?.menu = makePanelMenu()
        for handle in panel.contentView?.subviews.compactMap({ $0 as? PanelHandle }) ?? [] {
            handle.isHidden = locked
            handle.menu = makePanelMenu()
            handle.setPanelHeight(height)
        }
        for id in PluginPreferences.order {
            guard let plugin = plugins.first(where: { $0.id == id }) else { continue }
            guard PluginPreferences.isEnabled(plugin.id) else {
                plugin.stop()
                continue
            }
            if let launcher = plugin as? LauncherPlugin {
                launcher.onChange = { [weak self] in self?.refresh() }
            }
            if let clock = plugin as? ClockPlugin {
                clock.onWidthChanged = { [weak self] in self?.refresh() }
            }
            plugin.setPanelHeight(height)
            plugin.refresh()
            plugin.view.removeFromSuperview()
            let title = PluginPreferences.configuration(plugin.id)?.name ?? plugin.id
            let menu = locked ? makePanelMenu() : makePluginMenu(plugin)
            let views: [NSView]
            if locked || PluginPreferences.configuration(plugin.id)?.kind == "separator" {
                plugin.view.menu = menu
                views = [plugin.view]
            } else {
                let handle = PanelHandle(title: title, menu: menu)
                handle.setPanelHeight(height)
                views = [handle, plugin.view]
            }
            let container = PluginContainer(id: plugin.id, views: views)
            container.menu = plugin is TaskbarPlugin ? nil : menu
            container.isMoving = !locked && movingPluginID == plugin.id
            container.onDrop = { [weak self] point in self?.dropPlugin(plugin.id, at: point) }
            stack.addArrangedSubview(container)
            container.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        // Allocate spare width equally to expanding spaces. Keep natural widths
        // when content overflows; the enclosing scroll view remains usable.
        let containers = stack.arrangedSubviews.compactMap { $0 as? PluginContainer }
        let expanding = containers.filter {
            guard let config = PluginPreferences.configuration($0.pluginID) else { return false }
            return config.kind == "separator" && config.separatorStyle == "space" && config.expand
        }
        let expandedIDs = Set(expanding.map(\.pluginID))
        let spacing = CGFloat(max(0, containers.count - 1)) * stack.spacing
        let fixedWidth = containers.filter { !expandedIDs.contains($0.pluginID) }
            .reduce(CGFloat.zero) { $0 + $1.fittingSize.width }
        let available = max(0, width - scrollLeading.constant)
        let spaceWidth = max(8, (available - fixedWidth - spacing) / CGFloat(max(1, expanding.count)))
        for container in expanding {
            (container.arrangedSubviews.first as? SeparatorView)?.setExpandedWidth(spaceWidth)
        }
        stackWidth.constant = fixedWidth + spacing + CGFloat(expanding.count) * spaceWidth
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2,
                             y: systemDock.isActive ? screen.frame.minY : screen.visibleFrame.minY + 8,
                             width: width, height: height), display: true)
        systemDock.layoutChanged()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TaskbarWindowOrder.shared.stop()
        systemDock.stop()
        for plugin in plugins { plugin.stop() }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
