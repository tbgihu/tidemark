import AppKit

/// Tidemark's status items. By default one item holds every account shown in the menu bar, side by side and close
/// together, by provider in their fixed order and then in the order set in Settings; a click opens the panel at the
/// clicked account's provider. With separate items (Settings), each account has an item of its own that can be
/// ⌘-dragged on its own; macOS remembers where each one sits by its `autosaveName`, derived from the account's id,
/// so hiding an account and showing it again puts it back in its place. With no account to show, a single
/// placeholder (the three-bar glyph) stays, so Tidemark is always there to click.
///
/// Items are created before the ones they replace are removed, so the menu bar never flickers empty, and each item
/// redraws only when what it draws changes.
@MainActor
final class StatusBar {
    private let model: Model
    /// Separate items, by account.
    private var items: [String: AccountItem] = [:]
    /// The one item every account shares when items aren't separate.
    private var shared: AccountItem?
    private var placeholder: AccountItem?
    /// Redraws when what an account shows changes with time alone.
    private var fadeTimer: Timer?
    /// A click on an item, or VoiceOver's press: opens the panel at its provider, or closes it.
    var onToggle: ((AccountItem) -> Void)?
    /// The provider whose accounts the open panel shows: every one of its items is highlighted, wherever they sit.
    private var marked: String?

    init(model: Model) {
        self.model = model
        // Delivered on the main queue whichever thread posts it, so the main-actor redraw never runs elsewhere.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.redrawAll() } }
        update()
    }

    /// Every item, in order; the placeholder alone while no account is shown.
    var all: [AccountItem] {
        let shown = shared.map { [$0] } ?? model.accounts.inMenuBar.compactMap { items[$0.id] }
        return shown.isEmpty ? placeholder.map { [$0] } ?? [] : shown
    }

    /// The item an account is shown in: its own, or the shared one.
    func item(for account: String) -> AccountItem? { items[account] ?? shared.flatMap { $0.accounts.contains(account) ? $0 : nil } }

    #if DEBUG
    /// Whether an account is drawn highlighted, for the self-test.
    func isHighlighted(_ account: String) -> Bool { item(for: account)?.highlighted(account) ?? false }

    /// A click on an account, as the mouse would land on it in a shared item, for the self-test.
    func press(_ account: String) { item(for: account)?.press(account) }
    #endif

    /// Where to hang the panel when nothing was clicked: the first account of `provider`, else the first account.
    func anchor(for provider: String?) -> (item: AccountItem, target: AccountItem.Target)? {
        for item in all {
            if let target = item.target(provider: provider) { return (item, target) }
        }
        return all.first.map { ($0, $0.target(provider: nil) ?? .init(provider: nil, x: nil)) }
    }

    /// Accounts in the order the menu bar shows them: by provider, then as set in Settings.
    private var shown: [Account] {
        let accounts = model.accounts.inMenuBar
        guard !model.separateItems else { return accounts }
        return accounts.enumerated().sorted {
            (Registry.order(of: $0.element.provider), $0.offset) < (Registry.order(of: $1.element.provider), $1.offset)
        }.map(\.element)
    }

    /// Brings the items in line with the accounts: adds, removes and redraws only what changed.
    func update() {
        let shown = shown
        let branded = model.accounts.providers.count > 1
        let separate = model.separateItems
        let now = Date()
        // The shared item, or none.
        if !separate, !shown.isEmpty {
            if shared == nil {
                let item = AccountItem(account: nil, provider: nil, shared: true)
                wire(item)
                shared = item
            }
        } else if let item = shared {
            item.remove()
            shared = nil
        }
        // New items appear to the left of existing ones: created last to first, they first appear in order.
        for account in shown.reversed() where separate && items[account.id] == nil {
            let item = AccountItem(account: account.id, provider: account.provider)
            wire(item)
            items[account.id] = item
        }
        if shown.isEmpty, placeholder == nil {
            let item = AccountItem(account: nil, provider: nil)
            wire(item)
            placeholder = item
        }
        let visible = separate ? Set(shown.map(\.id)) : []
        for (id, item) in items where !visible.contains(id) {
            item.remove()
            items[id] = nil
        }
        if !shown.isEmpty, let placeholder {
            placeholder.remove()
            self.placeholder = nil
        }
        func block(_ account: Account) -> MenuBarContent.Block {
            var block = Self.content(model, account, branded: branded, now: now).blocks[0]
            block.highlighted = marked == account.provider
            return block
        }
        if let shared {
            shared.show(MenuBarContent(blocks: shown.map(block)), accounts: shown.map { ($0.id, $0.provider) },
                        label: shown.map { Self.summary(model, $0, now: now) }.joined(separator: "; "), toolTip: nil)
        }
        for account in shown {
            items[account.id]?.show(MenuBarContent(blocks: [block(account)]), accounts: [(account.id, account.provider)],
                                    label: Self.summary(model, account, now: now), toolTip: nil)
        }
        placeholder?.show(MenuBarContent(blocks: []), accounts: [],
                          label: model.accounts.isEmpty ? "Tidemark, no accounts" : "Tidemark, every account hidden from the menu bar",
                          toolTip: model.accounts.isEmpty ? "Tidemark: no accounts" : "Tidemark: every account is hidden from the menu bar")
        scheduleFade()
    }

    private func wire(_ item: AccountItem) {
        item.onToggle = { [weak self, weak item] in if let item { self?.onToggle?(item) } }
        item.onAppearance = { [weak self] in self?.update() }
    }

    private func redrawAll() {
        (Array(items.values) + [shared, placeholder].compactMap(\.self)).forEach { $0.invalidate() }
        update()
    }

    /// Highlights every account of `provider` (nil: none), the clicked one among them.
    func mark(_ provider: String?) {
        guard provider != marked else { return }
        marked = provider
        update()
    }

    /// The windows the items sit in: a click there is the item's to handle, not one that closes the panel.
    var windows: [NSWindow] { all.compactMap(\.anchor) }

    /// One timer for every item: it fires when what an account shows next changes by itself (it turns late or
    /// expires, a meter resets, a period ends), which nothing else would trigger while offline.
    private func scheduleFade() {
        let now = Date()
        let next = model.accounts.inMenuBar.compactMap { model.nextDisplayChange($0, now: now) }.filter { $0 > now }.min()
        guard next != fadeTimer?.fireDate else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    /// An account's block, from what may be shown of it now: nothing at all (a neutral dash) while it isn't
    /// authenticated or its data is beyond the freshness window; faded only while its data is late. Marked in its
    /// provider's colour when `branded`.
    static func content(_ model: Model, _ account: Account, branded: Bool, now: Date = Date()) -> MenuBarContent {
        let brand = branded ? Registry.provider(account.provider)?.brandColor : nil
        let percent = account.showPercent
        // Only the meters the last response reported, at most three. With nothing that may be shown, only their
        // labels remain, in an unavailable style; with no layout known at all, a neutral dash. A meter that has
        // reset since keeps its row, without a value. Without meters, the headline figure.
        let block: MenuBarContent.Block
        switch ShownSnapshot.menuBar(account.snapshot, authenticated: model.authenticated(account),
                                     interval: model.interval(for: account), now: now) {
        case .live(let shown) where !shown.rows.isEmpty:
            let rows = shown.rows.prefix(3).map { row in
                MenuBarContent.Row(label: row.meter.label, percent: row.current?.rounded, severity: row.current?.severity ?? .normal)
            }
            block = .init(rows: rows, showPercent: percent, showLabels: account.showLabels, showBars: account.showBars, dimmed: shown.late, brand: brand)
        case .live(let shown):
            if let headline = shown.headline, let amount = headline.amount {
                block = .init(rows: [], showPercent: false, dimmed: shown.late,
                              figure: Format.compactMoney(amount, currency: headline.money.currency), brand: brand)
            } else {
                block = .init(rows: [], showPercent: percent, dimmed: shown.late, brand: brand)
            }
        case .unavailable(let labels, nil):
            block = .init(rows: labels.prefix(3).map { MenuBarContent.Row(label: $0, percent: nil, severity: .normal) },
                          showPercent: percent, showLabels: account.showLabels, showBars: account.showBars, dimmed: true, unavailable: true, brand: brand)
        case .unavailable(_, let figure?):
            block = .init(rows: [], showPercent: false, dimmed: true, figure: Format.placeholder(currency: figure.currency),
                          unavailable: true, brand: brand)
        case .none:
            block = .init(rows: [], showPercent: percent, dimmed: false, brand: brand)
        }
        return MenuBarContent(blocks: [block])
    }

    /// For VoiceOver: an account's values in one sentence, with the meters named in full.
    static func summary(_ model: Model, _ account: Account, now: Date = Date()) -> String {
        let login = Registry.resolve(account)?.login
        let kind = login?.kindLabel.map { "\($0), " } ?? ""
        let late = ", not current"
        let missing = account.needsSignIn ? (login?.texts.signedOutShort.lowercased() ?? "signed out")
            : !model.authenticated(account) ? "waiting for its credentials" : "no current data"
        guard let shown = model.shown(account, now: now) else { return "\(account.name): \(kind)\(missing)" }
        var values = shown.rows.map { row in
            guard let meter = row.current else { return "\(row.meter.title) just reset, waiting for an update" }
            return "\(meter.title) \(meter.rounded)%" + (meter.severity.spoken.map { " (\($0))" } ?? "")
        }
        if values.isEmpty, let headline = shown.headline, let amount = headline.amount {
            values.append("\(headline.money.format(amount)) \(headline.money.title.lowercased())")
        }
        return "\(account.name): \(kind)" + (values.isEmpty ? "no limits reported" : values.joined(separator: ", "))
            + (shown.late ? late : "")
    }
}

/// One status item: an account's block, or the placeholder. A press opens or closes the panel. Tidemark draws the
/// highlight itself, on every item of the provider the panel shows, rather than leave the clicked one to the menu bar:
/// a menu bar session would highlight that one item in a shape no other can match. It has no menu: Settings is the
/// panel's gear, and Quit is in Settings.
@MainActor
final class AccountItem: NSObject {
    /// Nil for the shared item and the placeholder.
    let account: String?
    let provider: String?
    private var item: NSStatusItem?
    private var shown: MenuBarContent?
    /// The accounts drawn, left to right, with their providers, and where each sits in the image.
    private(set) var accounts: [String] = []
    private var providers: [String] = []
    private var spans: [ClosedRange<CGFloat>] = []
    #if DEBUG
    private var pressed: Int?
    #endif
    private var shownHeight: CGFloat = 0
    private var shownStyle = ""
    private var appearanceObservation: NSKeyValueObservation?
    var onToggle: (() -> Void)?
    var onAppearance: (() -> Void)?

    init(account: String?, provider: String?, shared: Bool = false) {
        self.account = account
        self.provider = provider
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = account.map(Self.autosaveName) ?? (shared ? "tidemark-all" : "tidemark")
        item.behavior = []
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.setAccessibilityTitle("Tidemark")
            button.target = self
            button.action = #selector(activated)
            button.sendAction(on: .leftMouseDown)
            // The colours are drawn for one appearance: draw again when the menu bar's changes (light, dark, the
            // highlight). KVO calls back on whichever thread made the change, so this hops rather than assumes.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.onAppearance?() }
            }
        }
        self.item = item
    }

    /// Stable for an account, and free of anything personal: "tidemark-" and a hash of its id.
    static func autosaveName(_ account: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in account.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "tidemark-" + String(hash, radix: 16)
    }

    /// The window the item sits in, to anchor the panel to.
    var anchor: NSWindow? { item?.button?.window }
    var button: NSStatusBarButton? { item?.button }

    /// Redraws only when what is drawn changes.
    func show(_ content: MenuBarContent, accounts: [(id: String, provider: String)], label: String, toolTip: String?) {
        self.accounts = accounts.map(\.id)
        providers = accounts.map(\.provider)
        guard let button = item?.button else { return }
        let height = max(button.bounds.height, NSStatusBar.system.thickness)
        let appearance = button.effectiveAppearance
        let style = (appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                 .accessibilityHighContrastDarkAqua])?.rawValue ?? "")
            + (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? "+contrast" : "")
        if content != shown || height != shownHeight || style != shownStyle {
            shown = content
            shownHeight = height
            shownStyle = style
            button.image = MenuBarImage.image(content, height: height, appearance: appearance)
            spans = MenuBarImage.spans(content)
        }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.toolTip != toolTip { button.toolTip = toolTip }
    }

    /// Whether an account it draws is highlighted.
    func highlighted(_ account: String) -> Bool {
        accounts.firstIndex(of: account).flatMap { shown?.blocks.indices.contains($0) == true ? shown?.blocks[$0].highlighted : nil } ?? false
    }

    /// What a press opens: the provider of the account under it, and, in a shared item, where on screen that
    /// account's middle is, for the panel to hang from.
    struct Target: Equatable {
        let provider: String?
        let x: CGFloat?
    }

    /// The press being handled: the account under the mouse; VoiceOver's press, or a press between two accounts,
    /// takes the nearest, the first without a mouse.
    func target() -> Target {
        guard accounts.count > 1, let button = item?.button else { return Target(provider: provider ?? providers.first, x: nil) }
        var index = 0
        #if DEBUG
        if let pressed { index = pressed }
        #endif
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === button.window {
            let x = button.convert(event.locationInWindow, from: nil).x - imageOffset(button)
            index = spans.indices.min { abs(x - spans[$0].mid) < abs(x - spans[$1].mid) } ?? 0
        }
        return target(at: index, in: button)
    }

    /// The first account of `provider` it draws, nil for none (nil `provider`: its first account).
    func target(provider: String?) -> Target? {
        let index = provider.map { providers.firstIndex(of: $0) } ?? (providers.isEmpty ? nil : 0)
        guard let index, let button = item?.button else { return nil }
        return accounts.count > 1 ? target(at: index, in: button) : Target(provider: providers[index], x: nil)
    }

    private func target(at index: Int, in button: NSStatusBarButton) -> Target {
        guard spans.indices.contains(index), providers.indices.contains(index), let window = button.window else {
            return Target(provider: providers.first, x: nil)
        }
        let point = button.convert(NSPoint(x: imageOffset(button) + spans[index].mid, y: 0), to: nil)
        return Target(provider: providers[index], x: window.convertPoint(toScreen: point).x)
    }

    /// The image is centred in its button.
    private func imageOffset(_ button: NSStatusBarButton) -> CGFloat {
        max((button.bounds.width - (button.image?.size.width ?? 0)) / 2, 0)
    }

    #if DEBUG
    func press(_ account: String) {
        pressed = accounts.firstIndex(of: account)
        onToggle?()
        pressed = nil
    }
    #endif

    /// What it draws now.
    var content: MenuBarContent? { shown }

    /// Forgets what was drawn, so the next `show` draws again.
    func invalidate() { shownStyle = "" }

    func remove() {
        appearanceObservation = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// A press, on the mouse going down as with the menu bar's own items, or VoiceOver's.
    @objc private func activated() { onToggle?() }
}


private extension ClosedRange where Bound == CGFloat {
    var mid: CGFloat { (lowerBound + upperBound) / 2 }
}
