import Foundation
import Network

/// A one-page HTTP server on the loopback interface that receives the OAuth redirect
/// (`http://localhost:<port>/callback`). It listens on 127.0.0.1 and, on the same port when it can, on ::1, since a
/// browser may resolve localhost to either. Nothing outside this Mac can connect to it. It serves only
/// `GET /callback`, answers a request whose `state` doesn't match with an error page and keeps waiting, and stops
/// after the first matching one.
final class Loopback: @unchecked Sendable {
    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "io.github.tbgihu.tidemark.loopback")
    private var listeners: [NWListener] = []
    private var state = ""
    private var delivered: OAuth.Callback?
    private var onResult: (@Sendable (OAuth.Callback) -> Void)?
    private(set) var port: UInt16 = 0

    var redirect: String { "http://localhost:\(port)/callback" }

    /// Starts listening on a free port.
    func start() async throws {
        // Both stacks on one port, each bound to its loopback address only.
        if let ipv6 = try? listener(host: "::1", port: .any), let bound = try? await ready(ipv6) {
            port = bound
            if let ipv4 = try? listener(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: bound)!),
               (try? await ready(ipv4)) != nil { return }
            stopListeners()
        }
        port = try await ready(try listener(host: "127.0.0.1", port: .any))
    }

    private func stopListeners() {
        queue.sync {
            listeners.forEach { $0.cancel() }
            listeners = []
        }
    }

    /// Waits for the redirect of the sign-in that `state` identifies; a new call replaces the previous wait.
    func expect(state: String, onResult: @escaping @Sendable (OAuth.Callback) -> Void) {
        queue.sync {
            self.state = state
            self.delivered = nil
            self.onResult = onResult
        }
    }

    /// The redirect the current wait has already delivered, if any.
    func received() -> OAuth.Callback? { queue.sync { delivered } }

    func stop() {
        stopListeners()
        queue.async { self.onResult = nil }
    }

    private func listener(host: String, port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true          // lets ::1 and 127.0.0.1 share the port
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return listener
    }

    private func ready(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { @Sendable state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    resumed = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:                                       // stopped before it was ready
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            queue.sync {
                listeners.append(listener)
                listener.start(queue: queue)
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }      // a client that never finishes
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || complete || error != nil || buffer.count > 16384 {
                self.respond(connection, request: buffer)
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self).split(separator: " ")
        var status = "404 Not Found", page = Page.notFound
        if line.count >= 2, line[0] == "GET", let target = URLComponents(string: String(line[1])), target.path == "/callback" {
            let result = OAuth.callback(query: target.percentEncodedQuery, expecting: state)
            switch result {
            case .foreign:
                status = "400 Bad Request"
                page = Page.foreign
            case .code, .denied:
                status = "200 OK"
                if case .denied(let reason) = result, reason != "invalid_scope" { page = Page.cancelled } else { page = Page.done }
                if delivered == nil, let onResult {
                    delivered = result
                    onResult(result)
                }
            }
        }
        let body = Data(page.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum Page {
        static let done = page("Signed in", "You can close this window and return to Tidemark.")
        static let cancelled = page("Sign-in cancelled", "You can close this window.")
        static let foreign = page("This link has expired", "Start the sign-in again from Tidemark’s settings.")
        static let notFound = page("Not found", "")

        static func page(_ title: String, _ text: String) -> String {
            """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
            <meta name="color-scheme" content="light dark"><title>Tidemark</title><style>
            body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.4 -apple-system,system-ui,sans-serif;
            background:Canvas;color:CanvasText}main{text-align:center;padding:32px}h1{font-size:22px;font-weight:600;margin:0 0 8px}
            p{margin:0;opacity:.65}</style></head><body><main><h1>\(title)</h1><p>\(text)</p></main></body></html>
            """
        }
    }
}
