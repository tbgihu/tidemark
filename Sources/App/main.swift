import AppKit
import UserNotifications

// Tidemark shows usage limits and costs of AI accounts in the menu bar, one status item per account. Launching it
// creates the status items and nothing else: no Dock icon (LSUIElement), no main window, no app menu. Everything
// else is built when first shown.
//
//   Tidemark                     the menu bar app
//   Tidemark --icon <dir>        writes the app icon as an .iconset (build.sh)
//   Tidemark --uninstall         removes the login item, notifications and Keychain items; reports each step
//                                (uninstall.sh)
//   Tidemark --sample [0-6]      debug builds only: shows sample accounts (4: a Console organisation too; 5: and a
//                                fake second provider's; 6: and ChatGPT, Copilot and OpenCode), touching nothing on
//                                disk or network. With --selftest it checks itself; with --snapshot <dir> it writes
//                                PNGs of the menu bar, panel and Settings (--dark or --light, --collapsed, --showcase
//                                for real providers only); --open opens the panel

let arguments = CommandLine.arguments
if arguments.count > 2, arguments[1] == "--icon" {
    MainActor.assumeIsolated { Icon.write(to: URL(filePath: arguments[2])) }
    exit(0)
}
if arguments.count > 1, arguments[1] == "--uninstall" {
    Task { @MainActor in exit(await Uninstall.run() ? 0 : 1) }
    dispatchMain()
}

// One Tidemark at a time. Opening it again (Finder, Spotlight, `open -n`) shows the running one's panel instead.
if !arguments.contains("--sample"), !Instance.claim() {
    Instance.handOff()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = editMenu()
    withExtendedLifetime(delegate) { app.run() }
}

/// A menu-bar-only app shows no menus, but text fields still look for the standard edit commands in the main menu:
/// without it, ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z do nothing in Settings and its sheets. Never shown.
@MainActor
private func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    item.submenu = edit
    let main = NSMenu()
    main.addItem(NSMenuItem())                           // the application menu's place
    main.addItem(item)
    return main
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: Model!
    private var status: StatusBar!
    private var panel: PanelController!
    private var settings: SettingsController!
    private let updater = Updater()

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let sample = Sample.requested
        if sample != nil { Paths.support = FileManager.default.temporaryDirectory.appending(path: "TidemarkSample") }
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        model = Model(persistent: sample == nil)
        #else
        model = Model()
        #endif
        model.notifier.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusBar(model: model)
        panel = PanelController(model: model)
        settings = SettingsController(model: model, updater: updater)

        // A press on an account of the provider shown closes the panel; on any other, opens it there.
        status.onToggle = { [unowned self] item in
            let target = item.target()
            if panel.isOpen, target.provider == panel.provider { panel.dismiss() } else { open(item, target) }
        }
        panel.ownWindows = { [unowned self] in status.windows }
        panel.onProvider = { [unowned self] provider in status.mark(provider) }
        panel.onSettings = { [unowned self] in settings.show() }
        panel.onAddAccount = { [unowned self] in settings.addAccount() }
        panel.onSignIn = { [unowned self] id in settings.signIn(expecting: id) }
        settings.onClose = { [unowned self] in
            updater.settingsClosed()
            NSApp.hide(nil)                              // give focus back to the app that had it
        }
        updater.onChange = { [unowned self] in settings.reload() }

        Instance.onHandOff = { [unowned self] in showPanel() }
        // A display added, removed or rearranged moves the menu bar: the panel would be left floating elsewhere.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        model.onChange.append { [unowned self] in
            status.update()
            panel.reload()
            settings.reload()
        }

        #if DEBUG
        if let count = Sample.requested {
            model.loadSample(Sample.accounts(count))
            if arguments.contains("--selftest") { Selftest.run(model: model, status: status, panel: panel, settings: settings) }
            if arguments.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel() } }
            if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
                Screenshots.run(to: URL(filePath: arguments[index + 1]), model: model, status: status, panel: panel, settings: settings)
            }
            return
        }
        #endif
        // An update never interrupts a sign-in: it waits for the sign-in to end.
        updater.signingIn = { [unowned self] in settings.isSigningIn }
        settings.onSignInEnded = { [unowned self] in updater.signInEnded() }
        if updater.installIfAutomatic() { return }       // a prepared update, installed before anything starts
        LoginItem.registerOnFirstLaunch()
        model.start()
        updater.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    private func screensChanged() {
        panel.dismiss()
        status.update()
    }

    /// Opens the panel under `item` at the pressed account's provider, centred on that account in a shared item; open
    /// elsewhere, it moves there.
    private func open(_ item: AccountItem, _ target: AccountItem.Target) {
        if panel.isOpen { panel.close() }
        panel.open(below: item.anchor, provider: target.provider, at: target.x)
    }

    /// Opening Tidemark again (Finder, Spotlight, a second launch) shows its panel: the way in when the status items
    /// are hidden behind the notch or by a full menu bar.
    private func showPanel() {
        guard !panel.isOpen, let (item, target) = status.anchor(for: panel.provider) else { return }
        open(item, target)
    }
}

/// What `make uninstall` asks the app to undo, since only it can: its login item and its delivered notifications, and
/// its Keychain items (every login's credentials), which the script also finds itself when the app is gone. Each step
/// is reported as uninstall.sh reports its own, and the work is done before it returns: true when nothing failed.
@MainActor
enum Uninstall {
    static func run() async -> Bool {
        var ok = true
        func say(_ state: String, _ what: String) {
            print("  " + state.padding(toLength: 9, withPad: " ", startingAt: 0) + " " + what)
            if state == "failed" { ok = false }
        }
        if LoginItem.service.status != .notRegistered {
            do { try await LoginItem.service.unregister(); say("removed", "the login item") }
            catch { say("failed", "the login item: \(error.localizedDescription)") }
        }
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        _ = await center.deliveredNotifications()                       // returns once the removal is through
        // Only Tidemark's own items, through /usr/bin/security, which deletes them without asking. A locked keychain
        // is left alone: the tool would ask for its password.
        var deleted = 0
        for account in Registry.secretItems {
            do throws(SecretError) {
                if try Secrets.store.delete(account) { deleted += 1 }
            } catch {
                say("failed", "the Keychain item \(account): \(error == .locked ? "the keychain is locked" : "\(error)")")
            }
        }
        if deleted > 0 { say("removed", "\(deleted) Keychain item\(deleted == 1 ? "" : "s") with your sign-ins") }
        return ok
    }
}
