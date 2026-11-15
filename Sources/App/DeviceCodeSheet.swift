import AppKit

/// Signs in with a device code, as a sheet over Settings: the code, large and selectable, with Copy Code and a button
/// that opens the verification page in the default browser; Tidemark polls until the code is approved, denied or
/// expires, at the provider's pace.
@MainActor
final class DeviceCodeSheet: NSObject, SignInFlow {
    private let parent: NSWindow
    private let flow: DeviceCodeFlow
    private let provider: Provider
    private let login: Login
    private let http: HTTP
    private var window: NSWindow?
    private let code = NSTextField(labelWithString: "")
    private let progress = NSTextField(labelWithString: "Waiting for you to approve…")
    private let spinner = NSProgressIndicator()
    private let open = NSButton(title: "Open Browser", target: nil, action: nil)
    private let copy = NSButton(title: "Copy Code", target: nil, action: nil)
    private var device: DeviceCode?
    private var polling: Task<Void, Never>?
    private var continuation: CheckedContinuation<SignInResult, Never>?

    init(over parent: NSWindow, flow: DeviceCodeFlow, provider: Provider, login: Login, http: HTTP) {
        self.parent = parent
        self.flow = flow
        self.provider = provider
        self.login = login
        self.http = http
        super.init()
    }

    #if DEBUG
    var shownCode: String { code.stringValue }
    var sheetWindow: NSWindow? { window }
    #endif

    func run(expecting name: String?) async -> SignInResult {
        let device: DeviceCode
        do throws(FetchFailure) {
            device = try await flow.start(http)
        } catch {
            return .failed("Couldn’t start the sign-in: \(error.message(provider.company))")
        }
        self.device = device
        let window = build(device, name: name)
        self.window = window
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window)
            polling = Task { await poll(device) }
        }
    }

    func cancel() { finish(.cancelled) }

    private func build(_ device: DeviceCode, name: String?) -> NSWindow {
        let title = SheetKit.title(name.map { "Sign In Again to \($0)" } ?? "Sign In to \(provider.name)")
        let host = device.verificationURL.host() ?? device.verificationURL.absoluteString
        let intro = SheetKit.text("Open \(host) in your browser and enter this code. Tidemark signs in once you approve it.")
        code.stringValue = device.userCode
        code.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        code.isSelectable = true
        code.alignment = .center
        code.setAccessibilityLabel("Code: " + device.userCode.map(String.init).joined(separator: " "))
        copy.target = self
        copy.action = #selector(copyCode)
        open.title = "Open \(host)"
        open.target = self
        open.action = #selector(openPage)
        open.keyEquivalent = "\r"
        let actions = NSStackView(views: [SheetKit.spacer(), copy, open, SheetKit.spacer()])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        progress.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progress.textColor = .secondaryLabelColor
        let waiting = NSStackView(views: [spinner, progress])
        waiting.spacing = 6
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [waiting, SheetKit.spacer(), cancel])
        buttons.alignment = .centerY
        let (window, stack) = SheetKit.window([title, intro, code, actions, buttons], spacing: 12)
        stack.setCustomSpacing(18, after: actions)
        return window
    }

    @objc private func copyCode() {
        guard let device else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.userCode, forType: .string)
        SheetKit.announce("Code copied", from: copy)
    }

    @objc private func openPage() {
        guard let device else { return }
        NSWorkspace.shared.open(device.completeURL ?? device.verificationURL)
    }

    @objc private func cancelled() { cancel() }

    private func poll(_ device: DeviceCode) async {
        var interval = device.interval
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            guard Date() < device.expiresAt else { return finish(.failed("The code expired. Try again.")) }
            do throws(FetchFailure) {
                switch try await flow.poll(device, http) {
                case .pending: continue
                case .slowDown: interval += 5
                case .denied: return finish(.failed("The sign-in was declined."))
                case .expired: return finish(.failed("The code expired. Try again."))
                case .approved(let credential):
                    progress.stringValue = "Approved. Reading the account…"
                    do throws(FetchFailure) {
                        let identity = try await login.identify(credential, http)
                        return finish(.signedIn(identity, credential))
                    } catch {
                        return finish(.failed("Signed in, but couldn’t read the account: \(error.message(provider.company))"))
                    }
                }
            } catch {
                switch error {
                case .offline, .network, .rateLimited, .server: interval = min(interval * 2, 60)   // try again, slower
                default: return finish(.failed(error.message(provider.company)))
                }
            }
        }
    }

    private func finish(_ result: SignInResult) {
        guard let continuation else { return }
        self.continuation = nil
        polling?.cancel()
        polling = nil
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        continuation.resume(returning: result)
    }
}
