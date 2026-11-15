import Foundation

/// Why a refresh, a sign-in check or a token request failed. Never carries a secret.
enum FetchFailure: Error, Equatable, Sendable {
    /// 401: the token or key is no longer accepted.
    case unauthorized
    /// The grant was refused, or there is no credential: only signing in again helps.
    case signInRequired
    /// 429, with the server's Retry-After when it sent one.
    case rateLimited(TimeInterval?)
    case server(Int)
    case offline
    case network
    case unreadable
    /// The login keychain is locked: Tidemark waits, without asking, until it is unlocked.
    case keychainLocked
    /// Tidemark's Keychain item couldn't be read.
    case keychain
    /// 403: the credential may not read what Tidemark asks for.
    case forbidden

    /// Only the user can help: the account shows no values until they do.
    var needsUser: Bool { [.signInRequired, .unauthorized, .forbidden].contains(self) }

    /// What went wrong, for a status line, naming who answered ("Rate-limited by Anthropic."). `forbidden` is the
    /// login's own text for a 403.
    func message(_ company: String, forbidden: String = LoginTexts().forbidden) -> String {
        switch self {
        case .unauthorized, .signInRequired: "Sign in again to continue."
        case .rateLimited: "Rate-limited by \(company)."
        case .server(let code): "\(company)’s server answered \(code)."
        case .offline: "Offline."
        case .network: "Couldn’t reach \(company)."
        case .unreadable: "Unexpected response."
        case .keychainLocked: "Waiting for the login keychain to be unlocked."
        case .keychain: "Couldn’t read the Keychain."
        case .forbidden: forbidden
        }
    }
}

/// Tidemark's one door to the network: a single ephemeral `URLSession` (no cookies, no cache, nothing on disk),
/// shared by every provider. Each request is made once: retries are the scheduler's decision. Tests replace the
/// transport.
struct HTTP: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let transport: Transport

    init(transport: @escaping Transport) { self.transport = transport }

    /// The app's: the shared session.
    static let shared = HTTP { request in try await session.data(for: request) }

    /// An honest User-Agent, unless a provider documents otherwise.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Tidemark/\(version) (macOS)"
    }()

    /// Created on first use.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }()

    /// Makes the request and logs its method, path (never the query), status and Retry-After: nothing that
    /// identifies the account.
    func send(_ request: URLRequest) async throws(FetchFailure) -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET", path = request.url?.path ?? "?"
        let start = ContinuousClock.now
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw FetchFailure.network }
            let elapsed = start.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            Log.fetch.debug("""
                \(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode) in \(milliseconds) ms\
                , Retry-After: \(http.value(forHTTPHeaderField: "Retry-After") ?? "none", privacy: .public)
                """)
            return (data, http)
        } catch let error as URLError {
            Log.fetch.info("\(method, privacy: .public) \(path, privacy: .public) failed: URLError \(error.code.rawValue)")
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: throw .offline
            default: throw .network
            }
        } catch let failure as FetchFailure {
            throw failure
        } catch {
            throw .network
        }
    }

    /// The body of a 2xx answer; the usual statuses mapped to failures otherwise (401, 403, 429 with Retry-After).
    func data(_ request: URLRequest) async throws(FetchFailure) -> Data {
        let (data, response) = try await send(request)
        try Self.check(response)
        return data
    }

    /// Decodes a 2xx answer with `decode`; anything it can't read is `.unreadable`.
    func decode<T>(_ request: URLRequest, _ decode: (Data) throws -> T) async throws(FetchFailure) -> T {
        let data = try await data(request)
        do { return try decode(data) } catch { throw .unreadable }
    }

    static func check(_ response: HTTPURLResponse) throws(FetchFailure) {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw .unauthorized
        case 403: throw .forbidden
        case 429: throw .rateLimited(Backoff.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default: throw .server(response.statusCode)
        }
    }
}

extension URLRequest {
    /// A request with `headers` set and JSON accepted.
    init(_ url: URL, method: String = "GET", headers: [String: String] = [:]) {
        self.init(url: url)
        httpMethod = method
        setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { setValue(value, forHTTPHeaderField: name) }
    }
}
