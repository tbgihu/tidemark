import AppKit

/// One account in the panel, laid out like Claude's own usage page: name and email (or what kind of account it is),
/// then per meter a label, "NN% used", a full-width bar and when it resets; money figures, against their cap as a
/// bar, or as an amount with the period it covers; how fresh the data is; and collapsible parts below (History).
@MainActor
final class AccountSection: NSStackView {
    let id: String
    var onSignIn: (() -> Void)?
    var onResize: ((Bool) -> Void)?
    var onExpand: ((Bool) -> Void)?

    private let separator = NSBox()
    private let name = NSTextField(labelWithString: "")
    private let email = NSTextField(labelWithString: "")
    private let meters = NSStackView()
    private var rows: [String: MeterRow] = [:]
    private let money = NSStackView()
    private var figures: [String: NSView] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let signIn = NSButton(title: "Sign In Again…", target: nil, action: nil)
    private let statusLine = NSStackView()
    private let history: Disclosure
    /// Whether the section last showed an authenticated account: losing that collapses History once, as a record
    /// of the past, without changing the saved choice; the user may still open it.
    private var wasAuthenticated: Bool?

    /// `loadCosts` reads the account's daily costs for a `.dailyCosts` chart.
    init(id: String, history kind: HistoryKind, loadCosts: @escaping CostHistoryView.Load) {
        self.id = id
        history = Disclosure(title: "History") {
            if case .meters(let charted) = kind { return HistoryHost(account: id, charted: charted) }
            return CostHistoryHost(load: loadCosts)
        }
        if case .none = kind { history.isHidden = true }
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        separator.boxType = .separator
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        email.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        email.textColor = .secondaryLabelColor
        email.lineBreakMode = .byTruncatingMiddle
        let titles = NSStackView(views: [name, email])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        for list in [meters, money] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 12
        }

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .tertiaryLabelColor
        status.maximumNumberOfLines = 2
        status.preferredMaxLayoutWidth = PanelContent.width - 2 * PanelContent.inset - 120
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        signIn.bezelStyle = .glass
        signIn.controlSize = .small
        signIn.target = self
        signIn.action = #selector(signInAgain)
        statusLine.setViews([status, signIn], in: .leading)
        statusLine.alignment = .centerY
        statusLine.spacing = 8

        history.onToggle = { [weak self] expanded in
            self?.onExpand?(expanded)
            self?.onResize?(true)
        }

        for view in [separator, titles, meters, money, statusLine, history] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        setCustomSpacing(14, after: separator)
        setCustomSpacing(12, after: titles)
        setCustomSpacing(6, after: statusLine)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The status line's button: sign in again, or re-enter the key.
    @objc private func signInAgain() { onSignIn?() }

    /// `shown` is what may be shown of the snapshot now (see `ShownSnapshot`); `authenticated` whether the account
    /// can be read at all. Without either, the section is the account's name, its status and what to do about it.
    func show(_ account: Account, provider: Provider, login: Login, health: Health, shown: ShownSnapshot?,
              authenticated: Bool, separator showSeparator: Bool) {
        separator.isHidden = !showSeparator
        name.stringValue = account.name
        let now = Date()
        let subtitle = account.email.isEmpty || account.email == account.name ? login.kindLabel ?? "" : account.email
        email.stringValue = [subtitle, shown?.plan ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        email.isHidden = email.stringValue.isEmpty

        showMeters(shown?.rows ?? [], now: now)
        showMoney(shown?.figures ?? [], fetchedAt: shown?.fetchedAt, company: provider.company, now: now)

        signIn.isHidden = !account.needsSignIn
        signIn.title = login.texts.reauthenticate
        // Figures that say "as of" when they were read need no "Updated" line of their own.
        let datedFigures = (shown?.rows.isEmpty ?? false) && (shown?.figures.contains { $0.money.start != nil && !$0.money.partial } ?? false)
        let message = { (error: FetchFailure) in error.message(provider.company, forbidden: login.texts.forbidden) }
        if account.needsSignIn {
            status.stringValue = login.texts.signedOut
            status.textColor = .systemOrange
        } else if !authenticated, let error = health.error {
            status.stringValue = Format.failure(message(error), retry: retry(health), updated: nil, now: now)
            status.textColor = .secondaryLabelColor
        } else if health.loading, shown == nil {
            status.stringValue = "Loading…"
            status.textColor = .tertiaryLabelColor
        } else if let error = health.error {
            status.stringValue = Format.failure(message(error), retry: retry(health),
                                                updated: datedFigures ? nil : shown?.fetchedAt, now: now)
            status.textColor = .secondaryLabelColor
        } else if let shown {
            let updated = Format.updated(shown.fetchedAt, now: now)
            status.stringValue = shown.isEmpty ? "\(shown.note ?? "No usage limits reported") · \(updated)" : datedFigures ? "" : updated
            status.textColor = shown.late ? .secondaryLabelColor : .tertiaryLabelColor
        } else {
            status.stringValue = account.snapshot == nil ? "Waiting for the first update…" : "Waiting for an update…"
            status.textColor = .tertiaryLabelColor
        }
        status.toolTip = shown.map { $0.fetchedAt.formatted(date: .abbreviated, time: .standard) }
        statusLine.isHidden = status.stringValue.isEmpty && signIn.isHidden
        signIn.setAccessibilityLabel("\(login.texts.reauthenticateSpoken) \(account.name)")

        if case .none = login.history { return }
        history.isHidden = account.snapshot == nil
        if authenticated {
            history.setExpanded(account.historyExpanded, animated: false)
        } else if wasAuthenticated != false {
            history.setExpanded(false, animated: false)
        }
        wasAuthenticated = authenticated
    }

    /// One row per meter, in the snapshot's order, kept across refreshes.
    private func showMeters(_ shown: [ShownSnapshot.Row], now: Date) {
        let ids = shown.map(\.meter.id)
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for (index, entry) in shown.enumerated() {
            let row = rows[entry.meter.id] ?? {
                let row = MeterRow()
                rows[entry.meter.id] = row
                return row
            }()
            if meters.arrangedSubviews.firstIndex(of: row) != index {
                row.removeFromSuperview()
                meters.insertArrangedSubview(row, at: min(index, meters.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: meters.widthAnchor).isActive = true
            }
            row.show(entry, now: now)
        }
        meters.isHidden = rows.isEmpty
    }

    /// One row per money figure: against its cap as a bar, or as an amount with the period it covers.
    private func showMoney(_ shown: [ShownSnapshot.Figure], fetchedAt: Date?, company: String, now: Date) {
        let keys = shown.map { "\($0.money.limit == nil ? "amount" : "capped")-\($0.money.id)" }
        if Array(figures.keys).sorted() != keys.sorted() || money.arrangedSubviews.count != keys.count {
            money.arrangedSubviews.forEach { $0.removeFromSuperview() }
            var made: [String: NSView] = [:]
            for key in keys {
                let view = figures[key] ?? (key.hasPrefix("capped") ? CappedRow() : AmountRow())
                made[key] = view
                money.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: money.widthAnchor).isActive = true
            }
            figures = made
        }
        for (key, figure) in zip(keys, shown) {
            (figures[key] as? CappedRow)?.show(figure)
            (figures[key] as? AmountRow)?.show(figure, fetchedAt: fetchedAt ?? now, company: company, now: now)
        }
        money.isHidden = figures.isEmpty
    }

    /// When a failed refresh is tried again, if the panel should say so: not while only the user can help.
    private func retry(_ health: Health) -> Date? {
        switch health.error {
        case .rateLimited, .server, .network, .unreadable, .keychain: health.notBefore
        default: nil
        }
    }
}

/// An amount: its title and value, the headline larger, then the period it covers (in local time; providers bill
/// in UTC days), as of when it was read, or that it is still counting.
@MainActor
private final class AmountRow: NSStackView {
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        title.font = .systemFont(ofSize: 12, weight: .medium)
        value.alignment = .right
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [title, spacer, value])
        line.alignment = .firstBaseline
        addArrangedSubview(line)
        addArrangedSubview(detail)
        line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ figure: ShownSnapshot.Figure, fetchedAt: Date, company: String, now: Date) {
        let money = figure.money
        title.stringValue = money.title
        value.font = money.headline ? .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
                                    : .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.stringValue = figure.amount.map { money.format($0) } ?? "—"
        let day = money.start.map { start in (money.end ?? now).timeIntervalSince(start) <= 90000 } ?? false
        if figure.amount == nil {
            detail.stringValue = day ? "Not read yet today" : "Not read yet"
        } else if let start = money.start {
            detail.stringValue = "\(Format.since(start, day: day)) · \(money.partial ? "partial" : Format.asOf(fetchedAt, now: now))"
        } else {
            detail.stringValue = ""
        }
        detail.isHidden = detail.stringValue.isEmpty
        detail.toolTip = money.partial ? "Still coming in." : money.start == nil ? nil : "Months and days are UTC, as \(company) bills."
        setAccessibilityLabel([money.title, value.stringValue, detail.isHidden ? nil : detail.stringValue]
            .compactMap(\.self).joined(separator: ", "))
    }
}

/// A meter: its name and "NN% used", the bar, and when it resets.
@MainActor
private final class MeterRow: NSStackView {
    private let title = NSTextField(labelWithString: "")
    private let used = NSTextField(labelWithString: "")
    private let bar = UsageBar()
    private let reset = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        title.font = .systemFont(ofSize: 12, weight: .medium)
        used.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        used.textColor = .secondaryLabelColor
        used.alignment = .right
        reset.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reset.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [title, spacer, used])
        line.alignment = .firstBaseline
        for view in [line, bar] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        addArrangedSubview(reset)
        setCustomSpacing(4, after: bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ row: ShownSnapshot.Row, now: Date) {
        title.stringValue = row.meter.title
        switch row.value {
        case .current(let meter):
            used.stringValue = "\(Format.percent(meter.rounded)) used"
            bar.fraction = meter.clamped / 100
            bar.severity = meter.severity
            bar.isHidden = false
            let resets = Format.reset(meter.resetsAt, now: now)
            reset.stringValue = resets ?? ""
            reset.isHidden = resets == nil
            reset.toolTip = meter.resetsAt?.formatted(date: .complete, time: .shortened)
            setAccessibilityLabel([meter.title, "\(Format.percent(meter.rounded)) used", meter.severity.spoken, resets]
                .compactMap(\.self).joined(separator: ", "))
        case .reset(let date):
            // The value from before the reset is no longer true, and the new one isn't known yet: no bar, no figure.
            used.stringValue = "—"
            bar.isHidden = true
            reset.stringValue = "\(Format.resetPassed(date, now: now)) · waiting for an update"
            reset.isHidden = false
            reset.toolTip = date.formatted(date: .complete, time: .shortened)
            setAccessibilityLabel("\(row.meter.title), \(reset.stringValue)")
        }
    }
}

/// Money against a cap (extra usage, a budget): what was spent or is left and, with a cap, a bar against it.
@MainActor
private final class CappedRow: NSStackView {
    private let title = NSTextField(labelWithString: "")
    private let spent = NSTextField(labelWithString: "")
    private let bar = UsageBar()
    private let cap = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        title.font = .systemFont(ofSize: 12, weight: .medium)
        spent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        spent.textColor = .secondaryLabelColor
        spent.alignment = .right
        cap.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cap.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [title, spacer, spent])
        line.alignment = .firstBaseline
        for view in [line, bar] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        addArrangedSubview(cap)
        setCustomSpacing(4, after: bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ figure: ShownSnapshot.Figure) {
        let money = figure.money
        title.stringValue = money.title
        let verb = switch money.role { case .spend: "spent"; case .balance: "left"; case .credit: "credit" }
        spent.stringValue = figure.amount.map { "\(money.format($0)) \(verb)" } ?? "—"
        // The server's grade, as for the meters; without one, the share of the cap that is used.
        let severity = money.severity
        if let limit = money.limit, let fraction = money.fraction, figure.amount != nil {
            bar.fraction = fraction
            bar.severity = severity ?? .normal
            cap.stringValue = "of \(money.format(limit)) \(money.limitLabel ?? "limit")"
            bar.isHidden = false
            cap.isHidden = false
        } else {
            bar.isHidden = true
            cap.isHidden = true
        }
        setAccessibilityLabel([money.title, spent.stringValue, cap.isHidden ? nil : cap.stringValue, severity?.spoken]
            .compactMap(\.self).joined(separator: ", "))
    }
}

/// A rounded progress bar over a faint neutral track, filled in the foreground colour, or orange or red as the limit
/// runs low.
@MainActor
final class UsageBar: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true; setAccessibilityValue(fraction * 100) } } }
    var severity = Severity.normal { didSet { if severity != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 6).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        let width = bounds.width * min(max(fraction, 0), 1)
        guard width > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(width, bounds.height), height: bounds.height)
        severity.color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

/// A titled part that expands and collapses, building its content only while expanded.
@MainActor
final class Disclosure: NSStackView {
    var onToggle: ((Bool) -> Void)?
    private let button = NSButton()
    private let chevron = NSImageView()
    private let make: () -> NSView
    private var content: NSView?
    private(set) var expanded = false

    init(title: String, content make: @escaping () -> NSView) {
        self.make = make
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [chevron, label])
        row.spacing = 5
        row.alignment = .centerY

        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(toggle)
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(title)
        button.setAccessibilityRole(.disclosureTriangle)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 12),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        addArrangedSubview(row)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        setExpanded(!expanded, animated: true)
        onToggle?(expanded)
    }

    func setExpanded(_ value: Bool, animated: Bool) {
        guard value != expanded else { return }
        expanded = value
        button.setAccessibilityValue(value ? 1 : 0)
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        rotate(value, animated: animate)
        if value {
            let view = make()
            content = view
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            if animate {
                view.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    view.animator().alphaValue = 1
                }
            }
        } else {
            content?.removeFromSuperview()
            content = nil
        }
    }

    private func rotate(_ open: Bool, animated: Bool) {
        let image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)!
        if animated { chevron.setSymbolImage(image, contentTransition: .replace.downUp) } else { chevron.image = image }
    }
}
