import AppKit

/// How a sign-in ended.
enum SignInResult {
    case signedIn(Identity, Credential)
    case cancelled
    case failed(String)
}

/// One sign-in, over Settings, whatever its kind: OAuth in a browser window, a device code, a pasted secret or a web
/// view. `expecting` is the name of the account being signed in again, if any.
@MainActor
protocol SignInFlow: AnyObject {
    func run(expecting name: String?) async -> SignInResult
    func cancel()
}

/// A sheet's building blocks, shared by the sign-in sheets so they read as one family.
@MainActor
enum SheetKit {
    static let width: CGFloat = 420

    static func title(_ text: String) -> NSTextField {
        let title = NSTextField(wrappingLabelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.setAccessibilityRole(.staticText)
        return title
    }

    static func text(_ string: String) -> NSTextField {
        let text = NSTextField(wrappingLabelWithString: string)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .secondaryLabelColor
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return text
    }

    /// A warning with its sign, read by VoiceOver as one.
    static func caution(_ string: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let warning = text(string)
        warning.textColor = .labelColor
        let caution = NSStackView(views: [icon, warning])
        caution.alignment = .top
        caution.spacing = 8
        caution.setAccessibilityElement(true)
        caution.setAccessibilityRole(.staticText)
        caution.setAccessibilityLabel("Warning: " + string)
        return caution
    }

    /// The red line that says what went wrong.
    static func status() -> NSTextField {
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.isHidden = true
        status.setAccessibilityRole(.staticText)
        return status
    }

    static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return spacer
    }

    /// A titled sheet window holding `rows`, full width, 20 points in.
    static func window(_ rows: [NSView], spacing: CGFloat = 10) -> (NSWindow, NSStackView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in rows { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        fit(window)
        return (window, stack)
    }

    static func fit(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width, height: ceil(content.fittingSize.height)))
    }

    /// Reads `message` out at once, as the sheet shows it.
    static func announce(_ message: String, from element: Any) {
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
