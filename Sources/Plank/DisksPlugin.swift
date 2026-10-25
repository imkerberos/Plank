import AppKit
import DiskArbitration

struct MountedDisk: Equatable, Sendable {
    let url: URL
    let name: String
    let device: String
}

enum MountedDiskReader {
    static func isExternal(internalDevice: Bool?, removable: Bool, ejectable: Bool, deviceProtocol: String) -> Bool {
        internalDevice == false || removable || ejectable || deviceProtocol.localizedCaseInsensitiveContains("disk image")
    }

    static func mountedDisks() -> [MountedDisk] {
        guard let session = DASessionCreate(nil) else { return [] }
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        return urls.compactMap { url in
            guard url.path != "/", let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable != false, values.volumeIsLocal != false,
                  let disk = DADiskCreateFromVolumePath(nil, session, url as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let device = DADiskGetBSDName(disk) else { return nil }
            guard isExternal(internalDevice: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
                             removable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false,
                             ejectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false,
                             deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "") else { return nil }
            return MountedDisk(url: url, name: values.volumeName ?? url.lastPathComponent, device: String(cString: device))
        }.sorted { $0.name == $1.name ? $0.url.path < $1.url.path : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
enum MountedDiskIcons {
    // Use the same full-color drive artwork supplied by macOS, rather than
    // tinting a symbol or shipping copies of the system's assets.
    static let external = systemIcon("External")
    static let idle = systemIcon("Internal")

    private static func systemIcon(_ name: String) -> NSImage {
        let bundle = Bundle(url: URL(fileURLWithPath: "/System/Library/Extensions/IOStorageFamily.kext"))
        let image: NSImage
        if let url = bundle?.url(forResource: name, withExtension: "icns"), let resource = NSImage(contentsOf: url) {
            image = resource
        } else {
            image = NSWorkspace.shared.icon(forFile: "/").copy() as! NSImage
        }
        return image
    }

    static func volume(_ disk: MountedDisk) -> NSImage {
        // Finder's resolved volume icon includes media-specific artwork and
        // custom volume icons configured inside mounted disk images.
        NSWorkspace.shared.icon(forFile: disk.url.path)
    }
}

// The session stays alive until Disk Arbitration completes its asynchronous request.
private final class DiskUnmountRequest {
    let session: DASession
    let completion: @MainActor @Sendable (String?) -> Void
    init(session: DASession, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        self.session = session
        self.completion = completion
    }
}

@MainActor
enum DiskUnmountService {
    static func unmount(_ mounted: MountedDisk, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        // Resolve again so a stale menu cannot target a device that reused the mount point.
        guard MountedDiskReader.mountedDisks().contains(mounted),
              let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, mounted.url as CFURL) else {
            completion("The volume is no longer available.")
            return
        }
        DASessionSetDispatchQueue(session, .main)
        let request = DiskUnmountRequest(session: session, completion: completion)
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, context in
            guard let context else { return }
            let request = Unmanaged<DiskUnmountRequest>.fromOpaque(context).takeRetainedValue()
            let message: String?
            if let dissenter {
                message = (DADissenterGetStatusString(dissenter) as String?)
                    ?? "The disk could not be unmounted (code \(DADissenterGetStatus(dissenter))). Close files and apps using this volume, then try again."
            } else { message = nil }
            DASessionSetDispatchQueue(request.session, nil)
            Task { @MainActor in request.completion(message) }
        }, Unmanaged.passRetained(request).toOpaque())
    }
}

@MainActor
final class DisksPlugin: NSObject, PanelPlugin {
    let id: String
    var onChange: (() -> Void)?
    private let button = PanelMenuButton()
    private var size: NSLayoutConstraint!
    private var timer: Timer?
    private var observing = false
    private(set) var disks: [MountedDisk] = []
    private var pending = Set<String>()
    var view: NSView { button }
    var shouldHide: Bool { disks.isEmpty && PluginPreferences.configuration(id)?.disksHideWhenEmpty == true }

    init(id: String) {
        self.id = id
        super.init()
        button.image = MountedDiskIcons.idle
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.target = self
        button.action = #selector(showDisks)
        button.translatesAutoresizingMaskIntoConstraints = false
        size = button.widthAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([size, button.heightAnchor.constraint(equalTo: button.widthAnchor)])
        setPanelHeight(PanelPreferences.height)
    }

    func setPanelHeight(_ height: CGFloat) {
        size.constant = PanelMetrics.buttonSize(for: height)
        updateIcon()
    }

    private func updateIcon() {
        let source = disks.isEmpty ? MountedDiskIcons.idle : MountedDiskIcons.external
        guard let icon = source.copy() as? NSImage else { return }
        let dimension = PanelMetrics.utilityIconSize(for: size.constant)
        icon.size = NSSize(width: dimension, height: dimension)
        button.image = icon
    }

    func refresh() {
        update(notify: false)
        if !observing {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
                center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
            }
            observing = true
        }
        if timer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.update(notify: true) }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observing = false
        timer?.invalidate()
        timer = nil
        onChange = nil
    }

    @objc private func volumesChanged() { update(notify: true) }

    private func update(notify: Bool) {
        let previous = disks
        disks = MountedDiskReader.mountedDisks()
        button.isEnabled = !disks.isEmpty
        updateIcon()
        button.contentTintColor = nil
        button.toolTip = disks.isEmpty ? "No external disks mounted" : "Mounted Disks · Click a volume to unmount"
        button.setAccessibilityLabel(button.toolTip!)
        if notify && previous != disks { onChange?() }
    }

    @objc private func showDisks() {
        update(notify: true)
        guard !disks.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Click a Volume to Unmount", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        for disk in disks {
            let item = menu.addItem(withTitle: pending.contains(disk.device) ? "\(disk.name) · Unmounting…" : disk.name,
                                    action: #selector(unmount(_:)), keyEquivalent: "")
            item.image = MountedDiskIcons.volume(disk)
            item.target = self
            item.representedObject = disk.url
            item.isEnabled = !pending.contains(disk.device)
        }
        PanelMenu.show(menu, from: button)
    }

    @objc private func unmount(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let mounted = disks.first(where: { $0.url == url }), !pending.contains(mounted.device) else { return }
        pending.insert(mounted.device)
        DiskUnmountService.unmount(mounted) { [weak self] message in
            guard let self else { return }
            self.pending.remove(mounted.device)
            self.update(notify: true)
            if let message { self.showError(message, name: mounted.name) }
        }
    }

    private func showError(_ message: String, name: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Unmount \(name)"
        alert.informativeText = message
        alert.runModal()
    }

    static func makeSettings(configuration: PluginConfiguration) -> PluginSettingsContent { DisksSettings(configuration: configuration) }
}

@MainActor
private final class DisksSettings: PluginSettingsContent {
    private let hideWhenEmpty = NSButton(checkboxWithTitle: "Hide when no disks are mounted", target: nil, action: nil)
    init(configuration: PluginConfiguration) {
        super.init(sectionTitle: "Mounted Disks", windowHeight: 430)
        hideWhenEmpty.state = configuration.disksHideWhenEmpty == true ? .on : .off
        hideWhenEmpty.target = self
        hideWhenEmpty.action = #selector(requestSave)
        options = [hideWhenEmpty,
                   SettingsUI.help("Shows mounted external disks and disk images, including DMG and ISO volumes. Click a volume to unmount it. Internal system volumes are excluded."),
                   SettingsUI.help("The icon is dimmed when no disks are mounted. If a volume is in use, an error explains why it could not be unmounted.")]
    }
    override func save(to configuration: inout PluginConfiguration) { configuration.disksHideWhenEmpty = hideWhenEmpty.state == .on }
}
