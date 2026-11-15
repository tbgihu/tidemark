import AppKit

extension Severity {
    /// A bar's fill: the foreground colour of whatever it is drawn on (white on dark, black on light), then the
    /// system's orange and red. All are dynamic, so they resolve for the appearance they are drawn in, Increase
    /// Contrast and a tinted menu bar included.
    var color: NSColor {
        switch self {
        case .normal: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

/// The usage panel: Liquid Glass dropping down from the clicked status item, at that account's provider. It never activates Tidemark, closes on a click
/// elsewhere, Esc, the item, or the gear, and is torn down when closed, so nothing of it stays in memory.
@MainActor
final class PanelController {
    private let model: Model
    private var panel: Panel?
    private var content: PanelContent?
    private var monitors: [Any] = []
    private var ticker: Timer?
    var onSettings: (() -> Void)?
    var onAddAccount: (() -> Void)?
    var onSignIn: ((String) -> Void)?
    /// The status items' windows: a click there is theirs to handle (it may close the panel, or move it).
    var ownWindows: () -> [NSWindow] = { [] }
    /// The provider shown: on opening, on another tab, and nil on closing.
    var onProvider: ((String?) -> Void)?

    init(model: Model) { self.model = model }

    var isOpen: Bool { panel != nil }
    #if DEBUG
    var window: NSWindow? { panel }
    #endif

    /// The provider whose tab is shown.
    var provider: String? { content?.provider }

    /// Opens hanging from `anchor`, centred on `x` on screen when given (an account in a shared item), else on it.
    func open(below anchor: NSWindow?, provider: String?, at x: CGFloat? = nil) {
        guard panel == nil else { return }
        let content = PanelContent(model: model, provider: provider)
        content.onSettings = { [weak self] in self?.dismiss(); self?.onSettings?() }
        content.onAddAccount = { [weak self] in self?.dismiss(); self?.onAddAccount?() }
        content.onSignIn = { [weak self] id in self?.dismiss(); self?.onSignIn?(id) }
        content.onResize = { [weak self] animated in self?.fit(animated: animated) }
        content.onProvider = { [weak self] id in self?.onProvider?(id) }
        let panel = Panel(content: content)
        panel.onCancel = { [weak self] in self?.dismiss() }
        self.panel = panel
        self.content = content
        place(panel, below: anchor, at: x)
        let fade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = fade ? 0 : 1
        panel.orderFrontRegardless()
        panel.makeKey()
        if fade { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 } }
        NSAccessibility.post(element: panel, notification: .created)

        // Close on a click anywhere else: in other apps (global) or in Tidemark's other windows (local).
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, event.window !== panel,
                   !self.ownWindows().contains(where: { $0 === event.window }) { self.dismiss() }
            }
            return event
        }) { monitors.append(local) }

        // Relative times ("Updated 2 min ago", "Resets in 13 min") stay current while the panel is open.
        let ticker = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.content?.reload() }
        }
        ticker.tolerance = 5
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        model.refreshIfOlder(than: 15)
        onProvider?(content.provider)
    }

    func dismiss() { close() }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        ticker?.invalidate()
        ticker = nil
        self.panel = nil
        content = nil
        panel.orderOut(nil)
        panel.contentView = nil
        onProvider?(nil)
    }

    func reload() { content?.reload() }

    private func place(_ panel: Panel, below anchor: NSWindow?, at middle: CGFloat? = nil) {
        // The item's own screen; when the item isn't on any (hidden by a full menu bar), the top right of the main
        // screen, where status items live.
        let shown = anchor.flatMap { window in window.isVisible && window.screen != nil ? window : nil }
        guard let screen = shown?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let item = shown?.frame ?? NSRect(x: screen.visibleFrame.maxX - 8, y: screen.visibleFrame.maxY, width: 0, height: 0)
        let size = fittingSize(for: panel, on: screen)
        let visible = screen.visibleFrame
        var x = (middle ?? item.midX) - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(item.minY, visible.maxY) - 6
        panel.setFrame(NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height), display: true)
    }

    private func fittingSize(for panel: Panel, on screen: NSScreen) -> NSSize {
        let wanted = panel.wantedHeight
        return NSSize(width: PanelContent.width, height: min(wanted, screen.visibleFrame.height - 20))
    }

    /// Grows or shrinks the panel downwards, keeping its top edge under the item.
    private func fit(animated: Bool) {
        guard let panel, let screen = panel.screen else { return }
        let size = fittingSize(for: panel, on: screen)
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size.height = size.height
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

/// A borderless, non-activating panel whose whole content is one glass surface.
@MainActor
private final class Panel: NSPanel {
    var onCancel: (() -> Void)?
    private let scroll = NSScrollView()
    private let document: PanelContent

    init(content: PanelContent) {
        document = content
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelContent.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        autorecalculatesKeyViewLoop = true                              // Tab moves through the panel, tabs first
        setAccessibilityLabel("Tidemark usage")

        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        scroll.contentView = TopClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        glass.contentView = scroll
        contentView = glass
    }

    var wantedHeight: CGFloat {
        document.layoutSubtreeIfNeeded()
        return ceil(document.fittingSize.height)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// The tabs' shortcuts, as in Safari and Finder: ⌘1 to ⌘8 for a tab, ⌘9 for the last, ⌃Tab and ⌘⇧] for the next,
    /// ⌃⇧Tab and ⌘⇧[ for the previous.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let step = Self.tabStep(event), document.step(step) { return true }
        if let index = Self.tabIndex(event), document.selectTab(at: index) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let step = Self.tabStep(event), document.step(step) { return }
        super.keyDown(with: event)
    }

    /// ⌘1…⌘8: that tab; ⌘9: the last (-1).
    static func tabIndex(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) else { return nil }
        return digit == 9 ? -1 : digit - 1
    }

    /// ⌃Tab or ⌘⇧]: +1; ⌃⇧Tab or ⌘⇧[: -1.
    static func tabStep(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 48 {                          // Tab
            if flags == .control { return 1 }
            if flags == [.control, .shift] { return -1 }
        }
        if flags == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "]", "}": return 1
            case "[", "{": return -1
            default: break
            }
        }
        return nil
    }
}

/// Anchors the panel's content to its top: content that grows or shrinks (another tab, a history opened) keeps its
/// top edge still, where a plain clip view would hold the bottom for a frame.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}
