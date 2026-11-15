import AppKit

/// One provider's accounts in Settings, one row each. A drag lifts a row and it follows the pointer within the list; the
/// others slide aside as soon as its centre enters their slot, and it settles into place on release. It all happens
/// inside this view, with no drag session or pasteboard. Controls in a row (the checkboxes, Remove) take their own
/// clicks; a press anywhere else in the row starts a drag once the pointer moves 3 points. VoiceOver gets Move Up
/// and Move Down.
@MainActor
final class AccountList: NSView {
    static let rowHeight: CGFloat = 58, spacing: CGFloat = 0

    var onReorder: (([String]) -> Void)?
    var onRemove: ((String) -> Void)?
    var onShowPercent: ((String, Bool) -> Void)?
    var onShowLabels: ((String, Bool) -> Void)?
    var onShowBars: ((String, Bool) -> Void)?
    var onSignIn: ((String) -> Void)?

    private var ids: [String] = []
    private var rows: [String: AccountRow] = [:]
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    /// The pressed row, where it was grabbed, whether it moved far enough to be a drag, and the order before.
    private struct Drag { let id: String; let grab: CGFloat; let start: NSPoint; var lifted = false; let before: [String] }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height.isActive = true
        setAccessibilityRole(.list)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Controls inside rows get their clicks; everything else is the list's, for dragging.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if drag == nil, let hit = super.hitTest(point), hit is NSControl || hit.superview is NSControl { return hit }
        return self
    }

    /// Shows `accounts` in order; true when the list's height changed.
    @discardableResult
    func show(_ accounts: [Account]) -> Bool {
        let newIDs = accounts.map(\.id)
        if newIDs != ids, drag == nil {
            for (id, row) in rows where !newIDs.contains(id) { row.removeFromSuperview(); rows[id] = nil }
            for account in accounts where rows[account.id] == nil {
                let id = account.id
                let row = AccountRow()
                row.onRemove = { [weak self] in self?.onRemove?(id) }
                row.onShowPercent = { [weak self] on in self?.onShowPercent?(id, on) }
                row.onShowLabels = { [weak self] on in self?.onShowLabels?(id, on) }
                row.onShowBars = { [weak self] on in self?.onShowBars?(id, on) }
                row.onSignIn = { [weak self] in self?.onSignIn?(id) }
                row.setAccessibilityCustomActions([
                    NSAccessibilityCustomAction(name: "Move Up") { [weak self] in self?.move(id, by: -1) ?? false },
                    NSAccessibilityCustomAction(name: "Move Down") { [weak self] in self?.move(id, by: 1) ?? false },
                ])
                rows[id] = row
                addSubview(row)
            }
            ids = newIDs
            needsLayout = true
        }
        for account in accounts { rows[account.id]?.show(account, last: account.id == ids.last) }
        let total = max(0, CGFloat(ids.count) * (Self.rowHeight + Self.spacing) - Self.spacing)
        guard height.constant != total else { return false }
        height.constant = total
        return true
    }

    private func slot(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * (Self.rowHeight + Self.spacing), width: bounds.width, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        for (index, id) in ids.enumerated() {
            if id == drag?.id, drag?.lifted == true { rows[id]?.frame.size.width = bounds.width } else { rows[id]?.frame = slot(index) }
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Slides every row but the dragged one to its slot.
    private func settle(except dragged: String?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.18
            context.allowsImplicitAnimation = true
            for (index, id) in ids.enumerated() where id != dragged { rows[id]?.animator().frame = slot(index) }
        }
        for (index, id) in ids.enumerated() { rows[id]?.showSeparator(index < ids.count - 1) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / (Self.rowHeight + Self.spacing))
        guard ids.indices.contains(index), slot(index).contains(point) else { return }
        drag = Drag(id: ids[index], grab: point.y - slot(index).minY, start: point, before: ids)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, let row = rows[drag.id], ids.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !drag.lifted {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) >= 3 else { return }   // still a click
            drag.lifted = true
            row.lifted = true
            addSubview(row, positioned: .above, relativeTo: nil)
            NSCursor.closedHand.push()
        }
        let last = CGFloat(ids.count - 1) * (Self.rowHeight + Self.spacing)
        row.frame.origin.y = min(max(point.y - drag.grab, 0), last)
        let target = min(max(Int(row.frame.midY / (Self.rowHeight + Self.spacing)), 0), ids.count - 1)
        if let current = ids.firstIndex(of: drag.id), current != target {
            ids.insert(ids.remove(at: current), at: target)
            settle(except: drag.id)
        }
        self.drag = drag
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let row = rows[drag.id] else { self.drag = nil; return }
        self.drag = nil
        guard drag.lifted else { return }
        NSCursor.pop()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.18
            context.allowsImplicitAnimation = true
            row.animator().frame = slot(ids.firstIndex(of: drag.id) ?? 0)
        }, completionHandler: { MainActor.assumeIsolated { row.lifted = false } })
        if ids != drag.before { onReorder?(ids) }
    }

    /// VoiceOver's Move Up / Move Down.
    private func move(_ id: String, by offset: Int) -> Bool {
        guard drag == nil, let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return false }
        ids.swapAt(index, index + offset)
        settle(except: nil)
        onReorder?(ids)
        return true
    }
}

/// An account: initials, name and email (or what kind of account it is), its status when only the user can help,
/// "Show percentage in menu bar", Hide from Menu Bar and Remove. Raised while dragged. The percentage option is
/// greyed out while the account is hidden, and absent for an account without meters (its menu bar figure is an
/// amount), whose initials sit in a rounded square.
@MainActor
private final class AccountRow: NSView {
    var onRemove: (() -> Void)?
    var onShowPercent: ((Bool) -> Void)?
    var onShowLabels: ((Bool) -> Void)?
    var onShowBars: ((Bool) -> Void)?
    var onSignIn: (() -> Void)?
    var lifted = false { didSet { needsDisplay = true; updateShadow() } }

    private let avatar = Avatar()
    private let name = NSTextField(labelWithString: "")
    private let email = NSTextField(labelWithString: "")
    /// What its menu bar item shows; with neither bars nor percentages, it has none.
    private let labels = NSButton(checkboxWithTitle: "Labels", target: nil, action: nil)
    private let bars = NSButton(checkboxWithTitle: "Progress Bars", target: nil, action: nil)
    private let percent = NSButton(checkboxWithTitle: "Percentage", target: nil, action: nil)
    private let signIn = NSButton(title: "Sign In Again…", target: nil, action: nil)
    private let remove = NSButton()
    private let separator = NSBox()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: AccountList.rowHeight))
        wantsLayer = true
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        email.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        email.textColor = .secondaryLabelColor
        email.lineBreakMode = .byTruncatingMiddle
        // Wide enough for their text up to the row's controls, where they truncate.
        for label in [name, email] { label.setContentCompressionResistancePriority(.init(740), for: .horizontal) }
        for (box, action) in [(labels, #selector(toggleLabels)), (bars, #selector(toggleBars)), (percent, #selector(togglePercent))] {
            box.controlSize = .small
            box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            box.target = self
            box.action = action
            box.setContentCompressionResistancePriority(.init(750), for: .horizontal)
        }
        let shows = NSStackView(views: [labels, bars, percent])
        shows.orientation = .vertical
        shows.alignment = .leading
        shows.spacing = 1
        // One column in every row, whatever its boxes say.
        shows.widthAnchor.constraint(equalToConstant: ceil(bars.fittingSize.width)).isActive = true
        signIn.controlSize = .small
        signIn.bezelStyle = .push
        signIn.target = self
        signIn.action = #selector(signInAgain)

        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        remove.target = self
        remove.action = #selector(removeAccount)
        remove.toolTip = "Remove Account…"
        separator.boxType = .separator

        let text = NSStackView(views: [name, email])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [avatar, text, spacer, signIn, shows, remove])
        line.alignment = .centerY
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        addSubview(separator)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: signIn.leadingAnchor, constant: -8),
        ])
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ account: Account, last: Bool) {
        let login = Registry.resolve(account)?.login
        let texts = login?.texts ?? LoginTexts()
        name.stringValue = account.name
        let subtitle = account.email.isEmpty ? login?.kindLabel ?? "" : account.email
        email.stringValue = account.needsSignIn ? [texts.signedOutShort, subtitle].filter { !$0.isEmpty }.joined(separator: " · ") : subtitle
        email.textColor = account.needsSignIn ? .systemOrange : .secondaryLabelColor
        avatar.initials = Self.initials(account.name.isEmpty ? account.email : account.name)
        let meters = login?.reportsMeters ?? true
        avatar.square = !meters
        // An account without meters shows an amount, and has no percentages.
        bars.title = meters ? "Progress Bars" : "Amount"
        labels.state = account.showLabels ? .on : .off
        labels.isHidden = !meters
        bars.state = account.showBars ? .on : .off
        percent.state = account.showPercent ? .on : .off
        percent.isHidden = !meters
        signIn.title = texts.reauthenticate
        signIn.isHidden = !account.needsSignIn
        signIn.setAccessibilityLabel("\(texts.reauthenticateSpoken) \(account.name)")
        remove.setAccessibilityLabel("Remove \(account.name)")
        bars.setAccessibilityLabel("Show \(meters ? "progress bars" : "amount") in the menu bar for \(account.name)")
        percent.setAccessibilityLabel("Show percentage in the menu bar for \(account.name)")
        labels.setAccessibilityLabel("Show labels in the menu bar for \(account.name)")
        setAccessibilityLabel("\(account.name), \(email.stringValue)" + (account.inMenuBar ? "" : ", not in the menu bar"))
        showSeparator(!last)
    }

    func showSeparator(_ visible: Bool) { separator.isHidden = !visible || lifted }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    @objc private func togglePercent() { onShowPercent?(percent.state == .on) }
    @objc private func toggleLabels() { onShowLabels?(labels.state == .on) }
    @objc private func toggleBars() { onShowBars?(bars.state == .on) }
    @objc private func removeAccount() { onRemove?() }
    @objc private func signInAgain() { onSignIn?() }

    private func updateShadow() {
        separator.isHidden = lifted || separator.isHidden
        guard let layer else { return }
        layer.cornerRadius = 10
        layer.backgroundColor = lifted ? NSColor.windowBackgroundColor.cgColor : nil
        layer.shadowOpacity = lifted ? 0.22 : 0
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.zPosition = lifted ? 1 : 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if lifted { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor } }
    }
}

/// A circle with an account's initials in the accent colour; a rounded square for an organisation or key.
@MainActor
private final class Avatar: NSView {
    var initials = "" { didSet { if initials != oldValue { needsDisplay = true } } }
    /// A rounded square rather than a circle.
    var square = false { didSet { if square != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        (square ? NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8) : NSBezierPath(ovalIn: bounds)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                         .foregroundColor: NSColor.controlAccentColor]
        let size = (initials as NSString).size(withAttributes: attributes)
        (initials as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                    withAttributes: attributes)
    }
}
