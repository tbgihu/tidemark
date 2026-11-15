import AppKit
import ServiceManagement

/// Tidemark's Settings window: accounts by provider, refresh interval, notifications, login item, updates and Quit.
/// One instance, opened only from the panel's gear, and released when closed.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private let model: Model
    private let updater: Updater
    private var window: NSWindow?
    private var view: SettingsView?
    private var flow: SignInFlow?
    var onClose: (() -> Void)?
    var onSignInEnded: (() -> Void)?

    init(model: Model, updater: Updater) {
        self.model = model
        self.updater = updater
    }

    var isOpen: Bool { window != nil }
    /// A sign-in running: an update waits for it to end.
    var isSigningIn: Bool { flow != nil }
    #if DEBUG
    var settingsWindow: NSWindow? { window }
    var currentFlow: SignInFlow? { flow }
    #endif

    func show() {
        if window == nil {
            let view = SettingsView(model: model, updater: updater)
            view.onAdd = { [weak self] provider, login in self?.add(provider, login, expecting: nil) }
            view.onSignIn = { [weak self] id in self?.signIn(expecting: id) }
            view.onRemove = { [weak self] id in self?.confirmRemove(id) }
            view.onResize = { [weak self] in self?.fit() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Tidemark Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = view
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
            self.window = window
            self.view = view
            fit()
            window.center()
        }
        view?.reload()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() { view?.reload() }

    /// Opens Settings and its Add menu.
    func addAccount() {
        show()
        view?.offerProviders()
    }

    /// Signs an account in again: its own login's sheet, over Settings.
    func signIn(expecting id: String) {
        guard let account = model.account(id), let (provider, login) = Registry.resolve(account) else { return }
        add(provider, login, expecting: id)
    }

    /// Runs `login`'s sign-in over Settings and adds the account, or updates it when it is already here (the same
    /// identity). `expecting` is the account being signed in again.
    func add(_ provider: Provider, _ login: Login, expecting id: String?) {
        show()
        guard flow == nil, let window else { return }
        let expected = id.flatMap(model.account)
        let flow: SignInFlow
        switch login.auth {
        case .oauth(let config):
            flow = OAuthSignIn(anchor: window, provider: provider, login: login, config: config, http: model.http)
        case .deviceCode(let device):
            flow = DeviceCodeSheet(over: window, flow: device, provider: provider, login: login, http: model.http)
        case .secret(let form):
            flow = SecretSheet(over: window, form: form, login: login, company: provider.company, http: model.http)
        case .web(let web):
            flow = WebSignIn(over: window, web: web, provider: provider, login: login, http: model.http,
                             store: nil)
        }
        self.flow = flow
        view?.signingIn = true
        Task {
            defer {
                self.flow = nil
                view?.signingIn = false
                onSignInEnded?()
            }
            switch await flow.run(expecting: expected?.name) {
            case .signedIn(let identity, let credential):
                let added = model.add(identity, credential: credential, provider: provider, login: login)
                if let expected, expected.id != added {
                    present("Added \(identity.email.isEmpty ? identity.name : identity.email)",
                            "That’s a different account from \(expected.email.isEmpty ? expected.name : expected.email), so it was added as a new one.")
                }
            case .failed(let message):
                present("Couldn’t Sign In", message)
            case .cancelled:
                break
            }
        }
    }

    private func confirmRemove(_ id: String) {
        guard let window, let account = model.account(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.name)?"
        alert.informativeText = Registry.resolve(account)?.login.texts.removal(account.name, account.email)
            ?? "Tidemark forgets this account on this Mac."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { self?.model.remove(id) } }
        }
    }

    private func present(_ title: String, _ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window)
    }

    /// Sizes the window to its content, keeping the top edge in place.
    private func fit() {
        guard let window, let view else { return }
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: SettingsView.width, height: ceil(view.fittingSize.height))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if window.frame.size != frame.size { window.setFrame(frame, display: true, animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    }

    func windowDidBecomeKey(_ notification: Notification) { view?.refreshPermissions() }

    func windowWillClose(_ notification: Notification) {
        flow?.cancel()
        window?.contentView = nil
        window?.delegate = nil
        window = nil
        view = nil
        onClose?()
    }
}

/// The settings content, in grouped sections.
@MainActor
final class SettingsView: NSView {
    static let width: CGFloat = 500

    var onAdd: ((Provider, Login) -> Void)?
    var onSignIn: ((String) -> Void)?
    var onRemove: ((String) -> Void)?
    var onResize: (() -> Void)?
    var signingIn = false { didSet { add.isEnabled = !signingIn; add.title = signingIn ? "Adding…" : "Add Account…" } }

    private let model: Model
    private let updater: Updater
    /// One section per provider with accounts, in the fixed order.
    private let accounts = NSStackView()
    private var lists: [String: (header: NSView, group: Group, list: AccountList)] = [:]
    private let noAccounts = NSTextField(labelWithString: "No accounts yet. Add one to see its limits.")
    private let add = NSButton(title: "Add Account…", target: nil, action: nil)
    private let interval = NSSlider()
    private let intervalValue = NSTextField(labelWithString: "")
    private let intervalWarning = SettingsView.note("May be rate-limited by the provider.")
    private let notifications = NSSwitch()
    private let notificationNote = NSTextField(wrappingLabelWithString: "")
    private let notificationSettings = NSButton(title: "Open Notification Settings…", target: nil, action: nil)
    private let login = NSSwitch()
    private let separate = NSSwitch()
    private let orderNote = SettingsView.note("")
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    private let loginSettings = NSButton(title: "Open Login Items Settings…", target: nil, action: nil)
    private let version = NSTextField(labelWithString: "")
    private let mode = NSPopUpButton()
    private let modeNote = NSTextField(wrappingLabelWithString: "")
    /// "Checking for Updates…" over an indeterminate bar, then how it went, or the update that is waiting.
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    /// Download and Install (Manually) or Restart to Update; greyed out as Update Pending during a sign-in.
    private let install = NSButton(title: "Download and Install", target: nil, action: nil)
    private let check = NSButton(title: "Check for Updates", target: nil, action: nil)
    /// For a clone that can't update by itself: what to run in it, to copy.
    private let repair = NSTextField(wrappingLabelWithString: "")
    private let keychainNote = NSTextField(wrappingLabelWithString: "")
    private var permission = Notifier.Permission.unknown

    init(model: Model, updater: Updater) {
        self.model = model
        self.updater = updater
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func build() {
        // Accounts
        noAccounts.textColor = .secondaryLabelColor
        noAccounts.alignment = .center
        accounts.orientation = .vertical
        accounts.alignment = .leading
        accounts.spacing = 6
        let empty = Group(rows: [noAccounts])
        accounts.addArrangedSubview(empty)
        empty.widthAnchor.constraint(equalTo: accounts.widthAnchor).isActive = true
        add.target = self
        add.action = #selector(addAccount)
        add.setAccessibilityHelp("Choose a provider and how to sign in")
        let accountsFooter = NSStackView(views: [orderNote, Self.spacer(), add])
        accountsFooter.alignment = .centerY
        keychainNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keychainNote.textColor = .systemOrange
        keychainNote.isHidden = true

        // Refresh
        interval.minValue = 0
        interval.maxValue = Double(Interval.steps.count - 1)
        interval.numberOfTickMarks = Interval.steps.count
        interval.allowsTickMarkValuesOnly = true
        interval.tickMarkPosition = .below
        interval.isContinuous = true
        interval.target = self
        interval.action = #selector(intervalChanged)
        interval.setAccessibilityLabel("Refresh interval")
        intervalValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        intervalValue.textColor = .secondaryLabelColor
        intervalValue.alignment = .right
        let ends = NSStackView(views: [Self.note(Interval.label(Interval.steps.first!)), Self.spacer(), Self.note(Interval.label(Interval.steps.last!))])
        let slider = NSStackView(views: [interval, ends, intervalWarning])
        slider.orientation = .vertical
        slider.alignment = .leading
        slider.spacing = 2
        slider.setCustomSpacing(6, after: ends)
        for view in [interval, ends] { view.widthAnchor.constraint(equalTo: slider.widthAnchor).isActive = true }
        intervalWarning.isHidden = true
        let refresh = Group(rows: [
            Self.row("Refresh every", intervalValue),
            slider,
            Self.note("When a provider asks Tidemark to slow down, it waits longer, whatever this says. Organisations’ costs aren’t live, so they are read at most every 5 minutes."),
        ])

        // Notifications
        notifications.target = self
        notifications.action = #selector(notificationsChanged)
        notifications.setAccessibilityLabel("Notifications")
        notificationSettings.target = self
        notificationSettings.action = #selector(openNotificationSettings)
        notificationSettings.controlSize = .small
        let notificationGroup = Group(rows: [
            Self.row("Notify when limits run low", notifications),
            Self.note("Daily, weekly and monthly limits at 50, 75, 90 and 98% used; short windows, such as Claude’s 5-hour limit, at 75, 90 and 98%. Once each per reset, for every account with limits."),
            Self.stack([notificationNote, notificationSettings]),
        ])

        // General
        login.target = self
        login.action = #selector(loginChanged)
        login.setAccessibilityLabel("Open at login")
        loginSettings.target = self
        loginSettings.action = #selector(openLoginSettings)
        loginSettings.controlSize = .small
        separate.target = self
        separate.action = #selector(separateChanged)
        separate.setAccessibilityLabel("Separate menu bar items")
        let general = Group(rows: [
            Self.row("Separate menu bar items", separate),
            Self.note("Each account gets a menu bar item of its own, which you can ⌘-drag. Off, they share one, closer together."),
            Self.row("Open at login", login), Self.stack([loginNote, loginSettings]),
        ])

        // Updates
        mode.addItems(withTitles: UpdateMode.allCases.map(\.title))
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Updates")
        modeNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeNote.textColor = .secondaryLabelColor
        modeNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        check.target = self
        check.action = #selector(checkNow)
        install.target = self
        install.action = #selector(installUpdate)
        install.keyEquivalent = "\r"                                  // the primary action, drawn in the accent colour
        version.font = .systemFont(ofSize: NSFont.systemFontSize)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        repair.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        repair.isSelectable = true
        repair.setAccessibilityLabel("Command to run in the clone")
        let activity = Self.stack([updateStatus, progress, repair])
        progress.widthAnchor.constraint(equalTo: activity.widthAnchor).isActive = true
        let buttons = NSStackView(views: [Self.spacer(), install, check])
        buttons.alignment = .centerY
        let updates = Group(rows: [Self.row("Version", version), Self.row("Updates", mode), modeNote, activity, buttons])

        let quit = NSButton(title: "Quit Tidemark", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let footer = NSStackView(views: [Self.spacer(), quit])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let sections: [(String?, NSView)] = [("Accounts", accounts), (nil, accountsFooter), (nil, keychainNote),
                                             ("Refresh", refresh),
                                             ("Notifications", notificationGroup), ("General", general),
                                             ("Updates", updates), (nil, footer)]
        for (title, view) in sections {
            if let title {
                let header = NSTextField(labelWithString: title)
                header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                stack.addArrangedSubview(header)
                stack.setCustomSpacing(6, after: header)
            }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            stack.setCustomSpacing(title == nil ? 20 : 8, after: view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload() {
        let changed = showAccounts()
        let index = Interval.index(of: model.interval)
        interval.doubleValue = Double(index)
        intervalValue.stringValue = Interval.label(Interval.steps[index])
        let warned = !intervalWarning.isHidden
        intervalWarning.isHidden = !Pace.mayBeRateLimited(at: model.interval, by: model.accounts.map(model.pace))
        interval.setAccessibilityHelp(intervalWarning.isHidden ? nil : intervalWarning.stringValue)
        separate.state = model.separateItems ? .on : .off
        orderNote.stringValue = model.separateItems
            ? "Drag to change the order in the panel. ⌘-drag an account in the menu bar to move it there."
            : "Drag to change the order in the panel and the menu bar, where providers keep their order."
        login.state = LoginItem.enabled || LoginItem.needsApproval ? .on : .off
        loginNote.stringValue = LoginItem.needsApproval
            ? "Allow Tidemark in System Settings to open it at login." : ""
        loginNote.superview?.isHidden = !LoginItem.needsApproval
        showNotifications()
        let updates = showUpdates(), keychain = showKeychain()        // both, never short-circuited
        let resized = updates || keychain || warned == intervalWarning.isHidden
        if changed || resized { onResize?() }
    }

    /// Reads the notification permission again: the user may have changed it in System Settings.
    func refreshPermissions() {
        Task {
            permission = await model.notifier.permission()
            showNotifications()
            reload()
            onResize?()
        }
    }

    private func showNotifications() {
        notifications.state = Preferences.notifications && permission != .denied ? .on : .off
        let denied = Preferences.notifications && permission == .denied
        notificationNote.stringValue = denied ? "Notifications for Tidemark are turned off in System Settings." : ""
        notificationNote.textColor = .systemOrange
        notificationNote.superview?.isHidden = !denied
    }

    /// Updates the update section in place: the mode and its note, a check's progress and result, and once a newer
    /// version is known, its summary and button (Download and Install, or Restart to Update once downloaded),
    /// greyed out while it waits for a sign-in to end. Check for Updates is greyed out while a check runs. Returns
    /// whether a row appeared or disappeared.
    private func showUpdates() -> Bool {
        let before = [updateStatus.superview?.isHidden, install.isHidden, repair.isHidden]
        let commit = Updater.commit.map { " (\($0))" } ?? ""
        version.stringValue = "\(Paths.version) build \(Paths.build)\(commit)"
        mode.selectItem(at: UpdateMode.allCases.firstIndex(of: Updater.mode) ?? 0)
        mode.isEnabled = updater.supported
        modeNote.stringValue = updater.supported ? Updater.mode.note : "Built without a git clone, so there’s nothing to update from."
        let state = updater.state, activity = updater.activity
        check.isEnabled = updater.supported && !activity.busy
        activity.busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        progress.isHidden = !activity.busy
        updateStatus.stringValue = activity.status(state, diverged: updater.diverged)
        let diverged = !activity.busy && updateStatus.stringValue == UpdateActivity.divergedStatus
        repair.stringValue = "In \(Updater.source ?? "the clone"), run:\n\(UpdateActivity.repair)"
        repair.isHidden = !diverged
        updateStatus.superview?.isHidden = updateStatus.stringValue.isEmpty
        install.isHidden = state == .none || activity.busy
        install.isEnabled = state.actionable
        if state != .none { install.title = state.title }
        return before != [updateStatus.superview?.isHidden, install.isHidden, repair.isHidden]
    }

    /// The warning, under the accounts, that a sign-in couldn't be saved to the Keychain. Returns whether it
    /// appeared or disappeared.
    private func showKeychain() -> Bool {
        let (unsaved, locked) = model.unsavedCredentials
        keychainNote.stringValue = !unsaved ? ""
            : locked ? "Your login keychain is locked. Tidemark saves your accounts to it once it is unlocked."
            : "Tidemark couldn’t save to your Keychain, so it won’t remember your accounts after you quit."
        guard keychainNote.isHidden != !unsaved else { return false }
        keychainNote.isHidden = !unsaved
        return true
    }

    /// One section per provider with accounts, in the fixed order, each its own list to reorder; none without.
    /// Returns whether anything changed height.
    private func showAccounts() -> Bool {
        let providers = model.accounts.providers.compactMap(Registry.provider)
        var changed = false
        if providers.map(\.id) != accounts.arrangedSubviews.compactMap({ ($0 as? ProviderHeader)?.provider }) {
            accounts.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
            var kept: [String: (header: NSView, group: Group, list: AccountList)] = [:]
            for provider in providers {
                let section = lists[provider.id] ?? makeSection(provider)
                kept[provider.id] = section
                for view in [section.header, section.group] {
                    accounts.addArrangedSubview(view)
                    view.widthAnchor.constraint(equalTo: accounts.widthAnchor).isActive = true
                }
                accounts.setCustomSpacing(14, after: section.group)
            }
            lists = kept
            changed = true
        }
        for provider in providers {
            if lists[provider.id]?.list.show(model.accounts.of(provider.id)) == true { changed = true }
        }
        let empty = providers.isEmpty
        if accounts.arrangedSubviews.first?.isHidden != !empty {
            accounts.arrangedSubviews.first?.isHidden = !empty
            changed = true
        }
        return changed
    }

    private func makeSection(_ provider: Provider) -> (header: NSView, group: Group, list: AccountList) {
        let list = AccountList(label: "\(provider.name) accounts")
        list.onReorder = { [weak self] ids in self?.model.reorder(ids) }
        list.onRemove = { [weak self] id in self?.onRemove?(id) }
        list.onSignIn = { [weak self] id in self?.onSignIn?(id) }
        list.onShowPercent = { [weak self] id, on in self?.model.update(id) { $0.showPercent = on } }
        list.onShowLabels = { [weak self] id, on in self?.model.update(id) { $0.showLabels = on } }
        list.onShowBars = { [weak self] id, on in self?.model.update(id) { $0.showBars = on } }
        return (ProviderHeader(provider), Group(rows: [list]), list)
    }

    @objc private func addAccount() { offerProviders() }

    /// The Add menu: every provider in the fixed order. One with a single way to sign in adds directly; one with
    /// several opens a submenu of them.
    func offerProviders() {
        guard add.isEnabled else { return }
        let menu = NSMenu()
        for provider in Registry.providers {
            let item = NSMenuItem(title: provider.logins.count == 1 ? provider.name + "…" : provider.name, action: nil,
                                  keyEquivalent: "")
            item.image = ProviderLogo.image(provider, size: 16)
            if provider.logins.count == 1, let login = provider.logins.first {
                item.subtitle = login.subtitle
                item.representedObject = LoginChoice(provider: provider, login: login)
                item.target = self
                item.action = #selector(choose)
            } else {
                let submenu = NSMenu(title: provider.name)
                for login in provider.logins {
                    let entry = NSMenuItem(title: login.title + "…", action: #selector(choose), keyEquivalent: "")
                    entry.subtitle = login.subtitle
                    entry.image = NSImage(systemSymbolName: login.symbol, accessibilityDescription: nil)
                    entry.representedObject = LoginChoice(provider: provider, login: login)
                    entry.target = self
                    submenu.addItem(entry)
                }
                item.submenu = submenu
            }
            menu.addItem(item)
        }
        #if DEBUG
        addMenu = menu
        if Self.presentsMenus == false { return }
        #endif
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add)
    }

    #if DEBUG
    /// The last Add menu built, for the self-test, which builds it without showing it.
    private(set) var addMenu: NSMenu?
    static var presentsMenus = true
    #endif

    @objc private func choose(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? LoginChoice else { return }
        onAdd?(choice.provider, choice.login)
    }

    @objc private func intervalChanged() {
        let index = Int(interval.doubleValue.rounded())
        let seconds = Interval.steps[min(max(index, 0), Interval.steps.count - 1)]
        intervalValue.stringValue = Interval.label(seconds)
        model.setInterval(seconds)
    }

    @objc private func notificationsChanged() {
        let on = notifications.state == .on
        Preferences.notifications = on
        guard on else { showNotifications(); onResize?(); return }
        Task {
            permission = await model.notifier.request()
            showNotifications()
            onResize?()
        }
    }

    @objc private func openNotificationSettings() { Notifier.openSettings() }

    @objc private func separateChanged() { model.setSeparateItems(separate.state == .on) }

    @objc private func loginChanged() {
        LoginItem.set(login.state == .on)
        reload()
        onResize?()
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func modeChanged() {
        updater.modeChanged(UpdateMode.allCases[max(mode.indexOfSelectedItem, 0)])
    }

    @objc private func checkNow() { updater.checkNow() }

    /// Greys the button at once: Tidemark quits into the installer, or it shows Update Pending during a sign-in.
    @objc private func installUpdate() {
        install.isEnabled = false
        install.title = "Installing…"
        updater.restartToUpdate()
    }

    // MARK: Building blocks

    static func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, spacer(), control])
        row.alignment = .centerY
        return row
    }

    static func note(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return note
    }

    static func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in views where view is NSTextField { view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return stack
    }

    static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return spacer
    }
}

/// A rounded, filled group of rows, like System Settings' forms. Rows are separated by hairlines.
@MainActor
final class Group: NSView {
    private let stack = NSStackView()

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let hasList = rows.contains { $0 is AccountList }
        stack.edgeInsets = hasList ? NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
                                   : NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rows {
            stack.addArrangedSubview(row)
            // the account list spans the whole group; other rows keep the insets
            let inset: CGFloat = row is AccountList ? 0 : -28
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: inset).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A provider's section title in Settings: its logo in its colour, and its name.
@MainActor
private final class ProviderHeader: NSStackView {
    let provider: String

    init(_ provider: Provider) {
        self.provider = provider.id
        let logo = NSImageView(image: ProviderLogo.image(provider, size: 14))
        let name = NSTextField(labelWithString: provider.name)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        name.textColor = .secondaryLabelColor
        super.init(frame: .zero)
        setViews([logo, name], in: .leading)
        spacing = 6
        alignment = .centerY
        edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(provider.name)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// What an Add menu item adds.
private final class LoginChoice: NSObject {
    let provider: Provider
    let login: Login
    init(provider: Provider, login: Login) {
        self.provider = provider
        self.login = login
    }
}
