import AppKit
import WebKit

/// Signs in on a provider's website inside Tidemark, as a sheet over Settings, and keeps one named cookie as the
/// credential. The web view and its data store exist only while the sheet is open, so WebKit's processes never run at
/// idle. Each account has its own persistent data store (`WKWebsiteDataStore(forIdentifier:)`), isolated from
/// Safari, other apps and every other account; removing the account deletes it. A page that opens a new window
/// (a "Sign in with…" pop-up, a link to a new tab) opens it in the same view, so a sign-in never leaves the sheet.
@MainActor
final class WebSignIn: NSObject, SignInFlow, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
    private let parent: NSWindow
    private let web: WebLogin
    private let provider: Provider
    private let login: Login
    private let http: HTTP
    private let store: UUID
    /// The account's own store, kept whatever happens; a new one is deleted unless the sign-in succeeds.
    private let reused: Bool
    private var window: NSWindow?
    private var view: WKWebView?
    private let status = NSTextField(labelWithString: "")
    private var checking = false
    private var continuation: CheckedContinuation<SignInResult, Never>?

    /// `store` is the account's data store when it signs in again; a new one otherwise.
    init(over parent: NSWindow, web: WebLogin, provider: Provider, login: Login, http: HTTP, store: UUID? = nil) {
        self.parent = parent
        self.web = web
        self.provider = provider
        self.login = login
        self.http = http
        self.store = store ?? UUID()
        reused = store != nil
        super.init()
    }

    #if DEBUG
    var webView: WKWebView? { view }
    var sheetWindow: NSWindow? { window }
    #endif

    func run(expecting name: String?) async -> SignInResult {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: store)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 600), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setAccessibilityLabel("\(provider.name) sign-in page")
        configuration.websiteDataStore.httpCookieStore.add(self)
        self.view = view

        let title = SheetKit.title(name.map { "Sign In Again to \($0)" } ?? "Sign In to \(provider.name)")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [title, SheetKit.spacer(), status, cancel])
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let separator = NSBox()
        separator.boxType = .separator
        var rows: [NSView] = [bar]
        if let note = web.note {
            let inset = NSStackView(views: [SheetKit.text(note)])
            inset.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
            rows.append(inset)
        }
        rows += [separator, view]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = stack
        window.contentMinSize = NSSize(width: 420, height: 480)
        self.window = window
        view.load(URLRequest(url: web.start))
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window)
        }
    }

    func cancel() { finish(.cancelled) }

    @objc private func cancelled() { cancel() }

    /// Deletes an account's data store, when it is removed.
    static func forget(store: String) async {
        guard let id = UUID(uuidString: store) else { return }
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.look(in: cookieStore) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.stringValue = webView.url?.host() ?? ""
    }

    /// A new window: its page loads in this view instead, so nothing opens outside the sheet or its data store.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "https" { webView.load(navigationAction.request) }
        return nil
    }

    /// The cookie, once it is set: checked with the provider, then the sheet closes.
    private func look(in cookieStore: WKHTTPCookieStore) async {
        guard continuation != nil, !checking else { return }
        let cookies = await cookieStore.allCookies()
        guard let cookie = cookies.first(where: { web.matches(name: $0.name, domain: $0.domain) }), !cookie.value.isEmpty
        else { return }
        checking = true
        defer { checking = false }
        status.stringValue = "Reading the account…"
        let credential = Credential(secret: cookie.value, expiresAt: cookie.expiresDate,
                                    fields: [WebLogin.storeField: store.uuidString])
        do throws(FetchFailure) {
            finish(.signedIn(try await login.identify(credential, http), credential))
        } catch {
            status.stringValue = ""                                    // not signed in yet: keep waiting
        }
    }

    private func finish(_ result: SignInResult) {
        guard let continuation else { return }
        self.continuation = nil
        view?.configuration.websiteDataStore.httpCookieStore.remove(self)
        view?.stopLoading()
        view?.navigationDelegate = nil
        view?.uiDelegate = nil
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
            window.contentView = nil
        }
        view = nil
        window = nil
        if case .signedIn = result {} else if !reused {
            Task { [store] in await Self.forget(store: store.uuidString) }   // nothing to keep from a cancelled sign-in
        }
        continuation.resume(returning: result)
    }
}
