import AppKit

/// The panel's content: a header with the gear, the provider tabs when accounts of more than one provider are
/// configured, then one section per account of the chosen provider in the configured order, or a friendly empty
/// state. Sections are kept and updated in place, so an open history chart survives a refresh.
@MainActor
final class PanelContent: NSView {
    static let width: CGFloat = 360
    static let inset: CGFloat = 16

    private let model: Model
    private let stack = NSStackView()
    private let header = NSStackView()
    private let title = NSTextField(labelWithString: "Tidemark")
    private let tabs = ProviderTabs()
    private let spacer = NSView()
    private var sections: [String: AccountSection] = [:]
    private var empty: NSView?
    /// The provider whose accounts are shown.
    private(set) var provider: String?
    var onSettings: (() -> Void)?
    var onAddAccount: (() -> Void)?
    var onSignIn: ((String) -> Void)?
    var onResize: ((Bool) -> Void)?
    /// The shown provider changed: a tab, or a shortcut.
    var onProvider: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init(model: Model, provider: String?) {
        self.model = model
        self.provider = provider
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        buildHeader()
        tabs.onSelect = { [weak self] provider in self?.select(provider) }
        tabs.glassHost = self
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildHeader() {
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.setAccessibilityRole(.staticText)

        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                            target: self, action: #selector(settings))
        gear.bezelStyle = .glass
        gear.isBordered = true
        gear.controlSize = .large
        gear.imageScaling = .scaleProportionallyDown
        gear.toolTip = "Settings"
        gear.setAccessibilityLabel("Settings")
        gear.setContentHuggingPriority(.required, for: .horizontal)
        // Round and fixed, so the tabs take the rest of the header.
        NSLayoutConstraint.activate([gear.widthAnchor.constraint(equalToConstant: 30), gear.heightAnchor.constraint(equalToConstant: 30)])

        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.setViews([title, tabs, spacer, gear], in: .leading)
        header.orientation = .horizontal
        header.distribution = .fill                      // no gaps: the spacer, or the tabs, take the free width
        header.alignment = .centerY
        header.spacing = 8
        // The tabs' glass and the gear's, drawn together as Liquid Glass side by side should be.
        let glass = NSGlassEffectContainerView()
        glass.contentView = header
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: glass.leadingAnchor), header.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            header.topAnchor.constraint(equalTo: glass.topAnchor), header.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        stack.addArrangedSubview(glass)
        glass.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
    }

    @objc private func settings() { onSettings?() }
    @objc private func addAccount() { onAddAccount?() }

    /// The tab `index` (-1: the last); false without tabs to choose from.
    func selectTab(at index: Int) -> Bool {
        let ids = tabs.ids
        guard !tabs.isHidden, !ids.isEmpty else { return false }
        let target = index < 0 ? ids.count - 1 : index
        guard ids.indices.contains(target) else { return true }       // ⌘7 with five tabs: taken, does nothing
        select(ids[target])
        return true
    }

    /// The next (+1) or previous (-1) tab, round from the last to the first; false without tabs.
    func step(_ by: Int) -> Bool {
        let ids = tabs.ids
        guard !tabs.isHidden, ids.count > 1 else { return false }
        let current = provider.flatMap(ids.firstIndex(of:)) ?? 0
        select(ids[(current + by + ids.count) % ids.count])
        return true
    }

    /// Shows another provider's accounts.
    func select(_ provider: String) {
        guard provider != self.provider else { return }
        self.provider = provider
        reload()
        onProvider?(provider)
        // Another provider's accounts start at their top.
        if let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        onResize?(true)
    }

    /// Brings the tabs and every section up to date with the model, in order.
    func reload() {
        let providers = model.accounts.providers.compactMap(Registry.provider)
        if provider.flatMap(Registry.provider).map({ p in !providers.contains { $0.id == p.id } }) ?? true {
            provider = providers.first?.id
        }
        tabs.show(providers, selected: provider)
        tabs.isHidden = providers.count < 2
        title.isHidden = !tabs.isHidden
        spacer.isHidden = !tabs.isHidden                 // the tabs take the whole width beside the gear
        let accounts = model.accounts.of(provider ?? "")
        if accounts.isEmpty {
            sections.values.forEach { $0.removeFromSuperview() }
            sections = [:]
            if empty == nil {
                let view = emptyState()
                empty = view
                append(view)
            }
        } else {
            empty?.removeFromSuperview()
            empty = nil
            for (id, section) in sections where !accounts.contains(where: { $0.id == id }) {
                section.removeFromSuperview()
                sections[id] = nil
            }
            let now = Date()
            let ordered = accounts.enumerated().compactMap { index, account -> AccountSection? in
                guard let (provider, login) = Registry.resolve(account) else { return nil }
                let section = sections[account.id] ?? makeSection(account, login)
                section.show(account, provider: provider, login: login, health: model.health[account.id] ?? Health(),
                             shown: model.shown(account, now: now), authenticated: model.authenticated(account),
                             separator: index > 0)
                return section
            }
            if Array(stack.arrangedSubviews.dropFirst()) != ordered {
                stack.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
                for section in ordered { append(section) }
            }
        }
        onResize?(false)
    }

    private func makeSection(_ account: Account, _ login: Login) -> AccountSection {
        let id = account.id
        let section = AccountSection(id: id, history: login.history) { [weak model] start in
            await model?.costHistory(id, from: start) ?? (CostLedger(), false)
        }
        section.onSignIn = { [weak self] in self?.onSignIn?(id) }
        section.onResize = { [weak self] animated in self?.onResize?(animated) }
        section.onExpand = { [weak self] expanded in self?.model.update(id) { $0.historyExpanded = expanded } }
        sections[id] = section
        return section
    }

    private func append(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
    }

    private func emptyState() -> NSView {
        let symbol = NSImageView(image: NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                                accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "No accounts yet")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: "Add an account to see its usage limits, or an organisation to see its costs, in the menu bar.")
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        text.preferredMaxLayoutWidth = Self.width - 2 * Self.inset - 24
        let button = NSButton(title: "Add Account…", target: self, action: #selector(addAccount))
        button.bezelStyle = .glass
        button.controlSize = .large
        let view = NSStackView(views: [symbol, title, text, button])
        view.orientation = .vertical
        view.alignment = .centerX
        view.spacing = 6
        view.setCustomSpacing(12, after: text)
        view.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 8, right: 0)
        return view
    }
}

/// The provider tabs, on one Liquid Glass capsule: each provider's logo in its colour over its name, in
/// slots sized so five fit before the strip scrolls sideways (a swipe, or a mouse wheel). The chosen tab sits on a
/// shaded highlight that lifts into Liquid Glass and glides to the next (`Glide`), the strip fades at an edge it
/// continues past, and the chosen tab stays in view.
@MainActor
final class ProviderTabs: NSView {
    var onSelect: ((String) -> Void)?
    private(set) var ids: [String] = []
    private var buttons: [Tab] = []
    private var selected = -1
    /// The tab the keyboard is on while the strip has focus: the arrows move it, Space chooses it.
    private var focused = -1
    private let scroll = TabScrollView()
    private let strip = FlippedView()
    private let glass = NSGlassEffectView()
    /// The selection, under the chosen tab's logo and name. A layer, not glass: glass draws over what it sits under.
    private let highlight = CALayer()
    /// Where the glass of a move is drawn: above the tabs' own glass, as glass inside glass doesn't show.
    weak var glassHost: NSView?
    private let lens = GlideLens()
    /// The move under way, its start (from the first frame it shows) and where it last was.
    private var glide: Glide?
    private var glideStart: CFTimeInterval?
    private var glideNow = (position: 0.0, velocity: 0.0)
    private var link: CADisplayLink?
    /// The width the tabs were last laid out for: a layout pass at the same width leaves them, the highlight and the
    /// scroll position alone, so nothing moves but what a click moves.
    private var laidOut: (width: CGFloat, count: Int)?

    /// How many tabs show before the strip scrolls.
    static let visible = 5
    static let padding: CGFloat = 3
    static let height: CGFloat = 42

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Still glass under a click: the gliding highlight answers it, as in the system's own segmented controls, and an
        // interactive capsule would swell with every press.
        glass.cornerRadius = 14
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = strip
        glass.contentView = scroll
        strip.wantsLayer = true
        highlight.cornerRadius = 11
        highlight.cornerCurve = .continuous
        highlight.isHidden = true
        strip.layer?.addSublayer(highlight)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Providers")
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // the header's width wins
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    func show(_ providers: [Provider], selected id: String?) {
        let ids = providers.map(\.id)
        let rebuilt = ids != self.ids
        if rebuilt {
            self.ids = ids
            buttons.forEach { $0.removeFromSuperview() }
            buttons = providers.enumerated().map { index, provider in
                let tab = Tab(provider)
                tab.onPress = { [weak self] in self?.press(index) }
                strip.addSubview(tab)
                return tab
            }
            selected = -1
            laidOut = nil
            needsLayout = true
        }
        // A shortcut glides the highlight as a click does; new tabs start where they are.
        choose(id.flatMap(ids.firstIndex(of:)) ?? 0, animated: !rebuilt && window != nil)
    }

    override func layout() {
        super.layout()
        let visible = scroll.contentView.bounds.width
        guard visible > 0, laidOut.map({ $0.width != visible || $0.count != buttons.count }) ?? true else { return }
        laidOut = (visible, buttons.count)
        // Five to the width, inside the capsule's padding; fewer fill it.
        let slot = floor((visible - 2 * Self.padding) / CGFloat(max(min(buttons.count, Self.visible), 1)))
        for (index, tab) in buttons.enumerated() {
            tab.frame = NSRect(x: Self.padding + CGFloat(index) * slot, y: Self.padding, width: slot,
                               height: Self.height - 2 * Self.padding)
            tab.fit(width: slot)
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(slot * CGFloat(buttons.count) + 2 * Self.padding, visible),
                             height: Self.height)
        place(animated: false)
        reveal()
        scroll.updateFades()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        place(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { place(animated: false) }                 // a closed panel ends a move where it was going
    }

    private func press(_ index: Int) {
        guard index != selected else { return }
        choose(index, animated: true)
        if ids.indices.contains(index) { onSelect?(ids[index]) }
    }

    private func choose(_ index: Int, animated: Bool) {
        guard buttons.indices.contains(index), index != selected else { return }
        selected = index
        if window?.firstResponder === self { focused = index; noteFocusRingMaskChanged() }
        reveal()
        place(animated: animated)
    }

    /// Puts the highlight under the chosen tab: animated, it glides there in glass (`Glide`), and a move under way
    /// turns to the new tab from where it is, keeping its speed. Unanimated with Reduce Motion.
    private func place(animated: Bool) {
        guard buttons.indices.contains(selected) else { endGlide(); highlight.isHidden = true; return }
        let target = buttons[selected].frame
        var tone: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tone = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.backgroundColor = tone
        CATransaction.commit()
        let current = highlight.frame
        if animated, !highlight.isHidden, window != nil, let host = glassHost,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(current.midX - target.midX) > 0.5 {
            return startGlide(to: target, in: host)
        }
        endGlide()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.isHidden = false
        highlight.frame = target
        highlight.opacity = 1
        CATransaction.commit()
        for (i, tab) in buttons.enumerated() { tab.isSelected = i == selected }
    }

    private func startGlide(to target: CGRect, in host: NSView) {
        let current = highlight.frame
        var velocity = 0.0
        var start = current
        var lifted = false
        if let glide {
            // Redirected under way: from the centre it has reached, at its speed along the new way.
            start = CGRect(x: current.midX - target.width / 2, y: target.minY, width: target.width, height: target.height)
            let distance = target.midX - start.midX
            velocity = abs(distance) > 0.5 ? glideNow.velocity * (glide.to.midX - glide.from.midX) / distance : 0
            lifted = glideStart.map { CACurrentMediaTime() - $0 < glide.fadeOutAt } ?? false
        }
        glide = Glide(from: start, to: target, velocity: velocity, lifted: lifted,
                      squash: glide?.squash ?? 0, squashSpeed: glide?.squashSpeed ?? 0)
        glideStart = nil
        glideNow = (0, velocity)
        if lens.view.superview !== host { host.addSubview(lens.view, positioned: .above, relativeTo: nil) }
        lens.view.frame = convert(bounds, to: host).insetBy(dx: -12, dy: -12).integral   // room for the glass's rim
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// One frame of the move: the highlight to its place and shade on the spring, the glass over it.
    @objc private func step(_ link: CADisplayLink) {
        guard var glide else { return endGlide() }
        let start = glideStart ?? link.timestamp
        if glideStart == nil {
            glideStart = start
            lens.glass(true)
        }
        let t = link.targetTimestamp - start
        let state = glide.advance(to: t)
        self.glide = glide
        glideNow = state.resting ? (1, 0) : (state.position, state.velocity)
        // The labels change under the glass, by the middle of the way.
        if glideNow.position >= 0.5, !buttons[selected].isSelected {
            for (i, tab) in buttons.enumerated() { tab.isSelected = i == selected }
        }
        if t >= glide.fadeOutAt { lens.glass(false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = state.resting ? glide.to : glide.frame(position: glideNow.position, squash: state.squash)
        highlight.opacity = state.resting ? 1 : Float(glide.shade(at: t))
        CATransaction.commit()
        lens.frame = lens.view.convert(highlight.frame, from: strip)
        if state.resting { endGlide() }
    }

    private func endGlide() {
        link?.invalidate()
        link = nil
        glide = nil
        glideStart = nil
        lens.reset()
    }

    /// Scrolls the chosen tab into view, with part of a neighbour so the strip reads as one that continues. Tabs that
    /// all fit never move.
    private func reveal(_ index: Int? = nil) {
        let index = index ?? selected
        let visible = scroll.contentView.bounds.width
        let overflow = strip.frame.width - visible
        guard buttons.indices.contains(index), visible > 0, overflow > 0.5 else { return }
        let tab = buttons[index].frame
        let current = scroll.contentView.bounds.origin.x
        let margin = tab.width / 3
        var x = current
        if tab.minX - margin < current { x = tab.minX - margin }
        if tab.maxX + margin > current + visible { x = tab.maxX + margin - visible }
        x = min(max(x, 0), overflow).rounded()
        guard abs(x - current) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.updateFades()
        if window?.firstResponder === self { noteFocusRingMaskChanged() }
    }

    // MARK: Keyboard

    // As a segmented control: one stop in the key view loop with Full Keyboard Access on, the arrows move the focus
    // ring between tabs, and Space chooses the one it is on.
    override var acceptsFirstResponder: Bool { !buttons.isEmpty }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled && !buttons.isEmpty }
    override var focusRingMaskBounds: NSRect { focusRect ?? .zero }
    override func drawFocusRingMask() {
        guard let rect = focusRect else { return }
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
    }

    private var focusRect: NSRect? {
        guard buttons.indices.contains(focused) else { return nil }
        return convert(buttons[focused].frame, from: strip).intersection(convert(scroll.bounds, from: scroll))
    }

    override func becomeFirstResponder() -> Bool {
        focused = selected
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard flags.isEmpty, buttons.indices.contains(focused) else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?, .upArrow?: moveFocus(to: focused - 1)
        case .rightArrow?, .downArrow?: moveFocus(to: focused + 1)
        case .home?: moveFocus(to: 0)
        case .end?: moveFocus(to: buttons.count - 1)
        default:
            if event.charactersIgnoringModifiers == " " { press(focused) } else { super.keyDown(with: event) }
        }
    }

    private func moveFocus(to index: Int) {
        let index = min(max(index, 0), buttons.count - 1)
        guard index != focused else { return NSSound.beep() }
        focused = index
        reveal(focused)
        noteFocusRingMaskChanged()
        NSAccessibility.post(element: buttons[index], notification: .focusedUIElementChanged)
    }

    #if DEBUG
    /// Chooses a tab as a click would, for the self-test.
    func choose(_ id: String) { ids.firstIndex(of: id).map(press) }
    var titles: [String] { buttons.map(\.title) }
    var focusedTitle: String? { buttons.indices.contains(focused) ? buttons[focused].title : nil }
    var slotsVisible: Int {
        guard let width = buttons.first?.frame.width, width > 0 else { return 0 }
        return Int((scroll.contentView.bounds.width / width).rounded(.down))
    }
    #endif

    /// A small dot of a provider's colour, ringed so it reads on any background.
    static func dot(_ color: BrandColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            let fill = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 0.5
            ring.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

}

/// One provider's tab: its logo over its name, which shrinks a little rather than truncate when long.
@MainActor
private final class Tab: NSView {
    var onPress: (() -> Void)?
    let title: String
    private let logo = NSImageView()
    private let label = NSTextField(labelWithString: "")

    static let logoSize: CGFloat = 18
    static let fontSize: CGFloat = 10
    static let minimumFontSize: CGFloat = 9

    var isSelected = false {
        didSet {
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            setAccessibilityValue(isSelected)
        }
    }

    override var isFlipped: Bool { true }

    init(_ provider: Provider) {
        title = provider.name
        super.init(frame: .zero)
        logo.image = ProviderLogo.image(provider, size: Self.logoSize)
        logo.imageScaling = .scaleNone
        label.stringValue = provider.name
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        addSubview(logo)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(provider.name)
        setAccessibilityHelp("Shows \(provider.name) accounts")
        toolTip = "\(provider.name) accounts"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lays out for a slot `width` wide: the name at its size if it fits, else a point smaller, else truncated.
    func fit(width: CGFloat) {
        let room = width - 8                             // the label cell's own padding, and a little air
        var size = Self.fontSize
        while size > Self.minimumFontSize,
              (title as NSString).size(withAttributes: [.font: Self.font(size)]).width > room { size -= 0.5 }
        label.font = Self.font(size)
        let labelHeight = ceil(label.font!.ascender - label.font!.descender + label.font!.leading) + 1
        let top = floor((bounds.height - Self.logoSize - 2 - labelHeight) / 2)
        logo.frame = NSRect(x: floor((width - Self.logoSize) / 2), y: top, width: Self.logoSize, height: Self.logoSize)
        label.frame = NSRect(x: 0, y: top + Self.logoSize + 2, width: width, height: labelHeight)
    }

    private static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .medium) }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

/// Lays its subviews out from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The tabs' scroller: sideways only, with a mouse wheel's vertical turns taken as sideways ones while the tabs
/// overflow (and passed on to the panel otherwise), and a soft fade at each edge the tabs continue past.
@MainActor
private final class TabScrollView: NSScrollView {
    private let fade = CAGradientLayer()
    private static let fadeWidth: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var overflow: CGFloat { max((documentView?.frame.width ?? 0) - contentView.bounds.width, 0) }

    override func scrollWheel(with event: NSEvent) {
        guard overflow > 0 else { return nextResponder?.scrollWheel(with: event) ?? () }
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), !event.hasPreciseScrollingDeltas {
            // A mouse wheel: turn it sideways.
            let step = event.scrollingDeltaY * 8
            let x = min(max(contentView.bounds.origin.x - step, 0), overflow)
            contentView.scroll(to: NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        } else if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)           // a vertical swipe scrolls the panel
        } else {
            super.scrollWheel(with: event)
        }
    }

    @objc private func scrolled() { updateFades() }

    func updateFades() {
        let width = bounds.width
        guard overflow > 0, width > 0 else { layer?.mask = nil; return }
        let x = contentView.bounds.origin.x
        let edge = min(Self.fadeWidth / width, 0.5)
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.colors = [x > 0.5 ? clear : solid, solid, solid, x < overflow - 0.5 ? clear : solid]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        layer?.mask = fade
        CATransaction.commit()
    }
}
