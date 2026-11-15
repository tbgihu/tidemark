import AppKit

/// Asks for a pasted secret (an API or admin key) and any extra fields, as a sheet over Settings: why it is needed, a
/// warning about what it allows when the provider gives one, the fields, and Add, which checks the secret with the
/// provider (`Login.identify`) before anything is saved. A secret that doesn't work keeps the sheet open with the
/// reason.
@MainActor
final class SecretSheet: NSObject, NSTextFieldDelegate, SignInFlow {
    private let parent: NSWindow
    private let form: SecretForm
    private let login: Login
    private let company: String
    private let http: HTTP
    private var window: NSWindow?
    private var inputs: [(field: SecretForm.Field, control: NSControl)] = []
    private let status = SheetKit.status()
    private let spinner = NSProgressIndicator()
    private let add = NSButton(title: "Add", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var continuation: CheckedContinuation<SignInResult, Never>?
    private var checking: Task<Void, Never>?

    init(over parent: NSWindow, form: SecretForm, login: Login, company: String, http: HTTP) {
        self.parent = parent
        self.form = form
        self.login = login
        self.company = company
        self.http = http
        super.init()
    }

    #if DEBUG
    /// For the self-test.
    var fields: [NSControl] { inputs.map(\.control) }
    var addButton: NSButton { add }
    var message: String { status.stringValue }
    var sheetWindow: NSWindow? { window }
    #endif

    func run(expecting name: String?) async -> SignInResult {
        let window = build(name: name)
        self.window = window
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window)
            window.makeFirstResponder(inputs.first?.control)
        }
    }

    func cancel() {
        checking?.cancel()
        finish(.cancelled)
    }

    private func build(name: String?) -> NSWindow {
        let secretLabel = form.fields.first { if case .secret = $0.kind { true } else { false } }?.label
        var rows: [NSView] = [SheetKit.title(secretLabel.flatMap { label in name.map { "Re-enter the \(label) for \($0)" } }
                                                 ?? form.title),
                              SheetKit.text(form.intro)]
        if let warning = form.warning { rows.append(SheetKit.caution(warning)) }

        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for field in form.fields {
            let control: NSControl
            switch field.kind {
            case .secret, .text:
                let text: NSTextField = if case .secret = field.kind { NSSecureTextField() } else { NSTextField() }
                text.placeholderString = field.placeholder + (field.optional ? (field.placeholder.isEmpty ? "Optional" : " (optional)") : "")
                text.delegate = self
                control = text
            case .choice(let options):
                let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
                for option in options {
                    popUp.addItem(withTitle: option.title)
                    popUp.lastItem?.representedObject = option.value
                }
                control = popUp
            }
            control.setAccessibilityLabel(field.label)
            let label = NSTextField(labelWithString: field.label + ":")
            label.alignment = .right
            grid.addRow(with: [label, control])
            inputs.append((field, control))
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // A single field needs no label beside it: the field says what it is.
        if form.fields.count == 1 { grid.column(at: 0).isHidden = true }
        if !form.fields.isEmpty { rows.append(grid) }
        rows.append(SheetKit.text(form.footnote))
        rows.append(status)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Checking")
        cancelButton.target = self
        cancelButton.action = #selector(cancelled)
        cancelButton.keyEquivalent = "\u{1b}"
        add.target = self
        add.action = #selector(added)
        add.keyEquivalent = "\r"
        add.isEnabled = complete                                    // a form without fields only checks
        let buttons = NSStackView(views: [spinner, SheetKit.spacer(), cancelButton, add])
        buttons.alignment = .centerY
        rows.append(buttons)

        let (window, stack) = SheetKit.window(rows)
        stack.setCustomSpacing(16, after: status)
        window.initialFirstResponder = inputs.first?.control
        SheetKit.fit(window)
        return window
    }

    /// The cleaned values, by field id.
    private var values: [String: String] {
        var values: [String: String] = [:]
        for (field, control) in inputs {
            if let popUp = control as? NSPopUpButton {
                values[field.id] = popUp.selectedItem?.representedObject as? String
            } else if let text = control as? NSTextField {
                let secret = if case .secret = field.kind { true } else { false }
                values[field.id] = SecretForm.clean(text.stringValue, secret: secret)
            }
        }
        return values
    }

    private var complete: Bool {
        let values = values
        return form.fields.allSatisfy { $0.optional || !(values[$0.id] ?? "").isEmpty }
    }

    func controlTextDidChange(_ notification: Notification) {
        add.isEnabled = complete && checking == nil
        if !status.isHidden { show(nil) }
    }

    @objc private func cancelled() { cancel() }

    @objc private func added() {
        let values = values
        guard complete, checking == nil else { return }
        if let problem = form.validate(values) { return show(problem) }
        show(nil)
        add.isEnabled = false
        inputs.forEach { $0.control.isEnabled = false }
        spinner.startAnimation(nil)
        let credential = form.credential(values)
        checking = Task {
            defer {
                checking = nil
                spinner.stopAnimation(nil)
                inputs.forEach { $0.control.isEnabled = true }
                add.isEnabled = complete
            }
            do throws(FetchFailure) {
                let identity = try await login.identify(credential, http)
                guard !Task.isCancelled else { return }
                finish(.signedIn(identity, credential))
            } catch {
                guard !Task.isCancelled else { return }
                show(form.explain(error) ?? "Couldn’t check the key: \(error.message(company, forbidden: login.texts.forbidden))")
                window?.makeFirstResponder(inputs.first?.control)
            }
        }
    }

    private func show(_ message: String?) {
        status.stringValue = message ?? ""
        status.isHidden = message == nil
        if let message { SheetKit.announce(message, from: status) }
        if let window { SheetKit.fit(window) }
    }

    private func finish(_ result: SignInResult) {
        guard let continuation else { return }
        self.continuation = nil
        for (_, control) in inputs { (control as? NSTextField)?.stringValue = "" }   // the secret leaves with the sheet
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        continuation.resume(returning: result)
    }
}
