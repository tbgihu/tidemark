import AppKit
import AuthenticationServices

/// Signs in with OAuth 2.0 authorization code and PKCE, in an ephemeral web session (no shared cookies, so every
/// sign-in can be a different account), redirected to Tidemark's loopback server. Tidemark never reads the
/// credentials of a provider's own apps.
@MainActor
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding, SignInFlow {
    enum Failure: Error {
        case cancelled
        case denied(String)
        case failed(String)
    }

    /// The window the web session opens over. Never changed; AuthenticationServices may ask for it from any thread.
    nonisolated private let anchor: NSWindow
    private let provider: Provider
    private let login: Login
    private let config: OAuthPKCE
    private let http: HTTP
    /// The web session running now, for `cancel()`.
    private var current: Pending?

    init(anchor: NSWindow, provider: Provider, login: Login, config: OAuthPKCE, http: HTTP) {
        self.anchor = anchor
        self.provider = provider
        self.login = login
        self.config = config
        self.http = http
    }

    func run(expecting name: String?) async -> SignInResult {
        do throws(Failure) {
            let (identity, credential) = try await signIn()
            return .signedIn(identity, credential)
        } catch {
            switch error {
            case .cancelled: return .cancelled
            case .denied(let reason): return .failed("\(provider.name) didn’t allow the sign-in (\(reason)).")
            case .failed(let text): return .failed(text)
            }
        }
    }

    /// Runs the whole flow: browser, code exchange, identity.
    private func signIn() async throws(Failure) -> (Identity, Credential) {
        let server = Loopback()
        defer { server.stop() }
        let redirect: String, code: String, attempt: OAuthPKCE.Attempt
        if (try? await server.start()) != nil, server.port != 0 {
            (code, attempt) = try await authorize(server: server)
            redirect = server.redirect
        } else if let manual = config.manualRedirect {
            (code, attempt) = try await authorizeManually(redirect: manual)
            redirect = manual
        } else {
            throw .failed("Couldn’t open a local port for the sign-in.")
        }
        let credential: Credential
        do {
            credential = try await config.exchange(code: code, attempt: attempt, redirect: redirect, http: http)
        } catch {
            throw .failed(error == .signInRequired ? "\(provider.name) rejected the sign-in code. Try again."
                                                   : error.message(provider.company))
        }
        do {
            return (try await login.identify(credential, http), credential)
        } catch {
            throw .failed("Signed in, but couldn’t read the account: \(error.message(provider.company))")
        }
    }

    /// The code from the loopback redirect, trying the broader scope only if the narrow one is refused.
    private func authorize(server: Loopback) async throws(Failure) -> (String, OAuthPKCE.Attempt) {
        for scope in config.scopes {
            let attempt = OAuthPKCE.Attempt()
            let url = config.authorizeURL(attempt, redirect: server.redirect, scope: scope)
            // The loopback reports from its own queue; the hop to the main actor finishes this browse only.
            let result = await browse(url, received: { server.received() }) { pending in
                server.expect(state: attempt.state) { [weak pending] callback in
                    Task { @MainActor in pending?.finish(.success(callback)) }
                }
            }
            switch result {
            case .success(.code(let code)): return (code, attempt)
            case .success(.denied("invalid_scope")): continue
            case .success(.denied(let reason)): throw reason == "access_denied" ? .cancelled : .denied(reason)
            case .success(.foreign): throw .failed("The sign-in response didn’t match. Try again.")
            case .failure(let failure): throw failure
            }
        }
        throw .denied("invalid_scope")
    }

    /// Without a loopback port: the provider shows a code to paste, as "code#state".
    private func authorizeManually(redirect: String) async throws(Failure) -> (String, OAuthPKCE.Attempt) {
        let attempt = OAuthPKCE.Attempt()
        let url = config.authorizeURL(attempt, redirect: redirect, scope: config.scopes[0])
        let name = provider.name
        let result = await browse(url) { pending in
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Paste the Code from \(name)"
                alert.informativeText = "After you sign in, \(name) shows a code. Copy it and paste it here."
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                field.placeholderString = "Code"
                alert.accessoryView = field
                alert.addButton(withTitle: "Continue")
                alert.addButton(withTitle: "Cancel")
                alert.window.initialFirstResponder = field
                let response = await alert.beginSheetModal(for: self.anchor)
                pending.finish(response == .alertFirstButtonReturn
                       ? .success(OAuth.pasted(field.stringValue, expecting: attempt.state)) : .failure(.cancelled))
            }
        }
        switch result {
        case .success(.code(let code)): return (code, attempt)
        case .success: throw .failed("That code doesn’t belong to this sign-in. Try again.")
        case .failure(let failure): throw failure
        }
    }

    /// Opens `url` in an ephemeral web authentication session until `wait` reports a result through the `Pending` it
    /// is given, or the session ends (closed by the user, or cancelled). `received` tells what the loopback already
    /// has when the session ends first.
    private func browse(_ url: URL, received: (@MainActor () -> OAuth.Callback?)? = nil, wait: (Pending) -> Void)
        async -> Result<OAuth.Callback, Failure> {
        let result = await withCheckedContinuation { continuation in
            let pending = Pending(continuation, received: received)
            current = pending
            // The loopback page ends the flow, not a URL scheme; this scheme is never opened.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("tidemark"),
                                                     completionHandler: Self.completion(for: pending))
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            pending.session = session
            wait(pending)
            if !session.start() { pending.finish(.failure(.failed("Couldn’t open the sign-in window."))) }
        }
        current = nil
        return result
    }

    /// The web session's completion handler. AuthenticationServices calls it on a queue of its own (an XPC reply),
    /// never on the main thread, including after `cancel()`. So it is built here, outside the main actor, as a
    /// `@Sendable` closure that only hops to it: a closure inferred to be on the main actor is checked at run time
    /// and traps when called anywhere else.
    nonisolated private static func completion(for pending: Pending) -> ASWebAuthenticationSession.CompletionHandler {
        { @Sendable [weak pending] _, error in
            let ended: Pending.Ended = if let error {
                (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? .cancelled : .failed(error.localizedDescription)
            } else {
                .failed("Sign-in failed.")
            }
            Task { @MainActor in pending?.sessionEnded(ended) }
        }
    }

    func cancel() { current?.finish(.failure(.cancelled)) }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    /// One web session, from its start to its one result. Whatever finishes it first wins, in any order: the
    /// loopback's code, the session ending, or `cancel()`. Later reports, such as the session's completion after
    /// the code arrived and the window was closed, find it finished and change nothing.
    @MainActor
    final class Pending {
        enum Ended: Sendable { case cancelled, failed(String) }

        fileprivate var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<Result<OAuth.Callback, Failure>, Never>?
        private let received: (@MainActor () -> OAuth.Callback?)?

        fileprivate init(_ continuation: CheckedContinuation<Result<OAuth.Callback, Failure>, Never>,
                         received: (@MainActor () -> OAuth.Callback?)?) {
            self.continuation = continuation
            self.received = received
        }

        /// Ends the browse with `result` and closes the web window, once.
        func finish(_ result: Result<OAuth.Callback, Failure>) {
            guard let continuation else { return }
            self.continuation = nil
            session?.cancel()
            session = nil
            continuation.resume(returning: result)
        }

        /// The session ended. If the loopback already has the redirect (its hop to the main actor may still be queued
        /// behind this one), that is the result; otherwise the user closed the window, or it failed.
        fileprivate func sessionEnded(_ ended: Ended) {
            guard continuation != nil else { return }
            if let callback = received?() { return finish(.success(callback)) }
            switch ended {
            case .cancelled: finish(.failure(.cancelled))
            case .failed(let message): finish(.failure(.failed(message)))
            }
        }
    }
}
