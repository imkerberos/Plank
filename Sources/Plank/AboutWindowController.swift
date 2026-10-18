import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    private let projectURL = URL(string: "https://github.com/imkerberos/Plank")!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Plank"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: "Plank")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: "An XFCE-style panel for macOS.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center

        let github = NSButton(title: "https://github.com/imkerberos/Plank", target: self, action: #selector(openProject))
        github.bezelStyle = .inline
        github.isBordered = false
        github.contentTintColor = .linkColor
        github.attributedTitle = NSAttributedString(
            string: github.title,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        github.setAccessibilityLabel("Open Plank on GitHub")

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [icon, title, subtitle, version, github, close])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        subtitle.widthAnchor.constraint(equalToConstant: 320).isActive = true
        github.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private var versionText: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "Development build"
        }
        return "Version \(version)"
    }

    @objc private func openProject() {
        NSWorkspace.shared.open(projectURL)
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
