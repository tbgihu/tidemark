import Foundation

/// Google Antigravity: the weekly and 5-hour limits of each model group, and the AI credits left, as Antigravity's
/// own command line tool, `agy`, reports them for the Google account it is signed in to. Tidemark runs `agy` the way
/// the user would in Terminal and reads its answer; it never reads Antigravity's files or credentials.
enum Antigravity {
    static let id = "antigravity"

    // Each reading starts `agy`, which takes a few seconds: every few minutes is plenty for limits that move slowly.
    static let provider = Provider(
        id: id, name: "Antigravity", company: "Google", brandColor: BrandColor(hex: 0x4796E3),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [cli])

    static let setup = "Tidemark reads Antigravity’s limits through its command line tool. If you use only the "
        + "Antigravity app, install the agy command line tool too, then run agy in Terminal once and sign in."

    static let cli = login { command throws(FetchFailure) in try await AgyCommand.run(command) }

    /// The login, reading through `run` (tests give it canned answers).
    static func login(run: @escaping @Sendable (_ command: String) async throws(FetchFailure) -> Data) -> Login {
        Login(
            id: "cli", title: "Antigravity", subtitle: "Read the limits of agy’s Google account", symbol: "terminal",
            kindLabel: "Antigravity", auth: .secret(SecretForm(
                title: "Add Antigravity",
                intro: setup,
                fields: [],
                footnote: "agy keeps its own sign-in: Tidemark stores no password or key for it.",
                explain: { failure in
                    failure == .signInRequired ? "agy isn’t installed or isn’t signed in. " + setup : nil
                })),
            minimumInterval: 120, secretItem: "antigravity-cli",
            history: .meters([ChartedMeter(id: "gemini-5h", label: "5h", title: "Gemini models, 5-hour limit"),
                              ChartedMeter(id: "gemini-weekly", label: "weekly", title: "Gemini models, weekly limit"),
                              ChartedMeter(id: "3p-weekly", label: "other weekly",
                                           title: "Claude and GPT models, weekly limit")]),
            texts: LoginTexts(
                signedOut: "agy isn’t signed in. Run agy in Terminal and sign in, then check again.",
                signedOutShort: "agy signed out", reauthenticate: "Check Again…",
                reauthenticateSpoken: "Check agy again for",
                removal: { _, _ in
                    "Tidemark stops showing Antigravity and deletes its usage history. agy stays signed in."
                }),
            accountID: { "antigravity-" + $0 },
            identify: { _, _ throws(FetchFailure) in
                _ = try AntigravityUsage.meters(try await run("/usage"))
                return identity
            },
            fetch: { context throws(FetchFailure) in
                let meters = try AntigravityUsage.meters(try await run("/usage"))
                // Credits only add: an answer without them never fails the account.
                let credits = try? await run("/credits")
                return AntigravityUsage.snapshot(meters: meters, credits: credits.flatMap(AntigravityUsage.credits),
                                                 now: context.now)
            })
    }

    /// agy reports no account: there is one per Mac, the one agy is signed in to.
    static let identity = Identity(id: "agy", name: "Antigravity")
}

/// Runs `agy -p <command> --output-format json` for one of agy's own commands (`/usage`, `/credits`), which answer
/// from Google's servers without running the model. In an empty folder, in plan mode and sandboxed, so nothing could
/// ever be changed, with nothing on standard input, and stopped after a minute. Signed out, agy asks to sign in and
/// waits: that is read as such and stopped at once, without a browser window, and the account waits for the user.
enum AgyCommand {
    /// Where agy's installer and the package managers put it; an app's environment has no shell `PATH` to search.
    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        [home.appending(path: ".local/bin/agy"), URL(filePath: "/opt/homebrew/bin/agy"), URL(filePath: "/usr/local/bin/agy")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let timeout: TimeInterval = 60

    static func run(_ command: String) async throws(FetchFailure) -> Data {
        guard let agy = executable() else { throw .signInRequired }
        let result: Result<Data, FetchFailure> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(agy, command))
            }
        }
        return try result.get()
    }

    private static func runBlocking(_ agy: URL, _ command: String) -> Result<Data, FetchFailure> {
        let process = Process()
        process.executableURL = agy
        process.arguments = ["-p", command, "--output-format", "json", "--log-file", "/dev/null", "--mode", "plan",
                             "--sandbox", "--print-timeout", "\(Int(timeout - 10))s"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // No `PATH`, so a signed-out agy can't open its sign-in page in the browser on every reading (it finds `open`
        // through it), and no update while Tidemark asks.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ""
        environment["BROWSER"] = nil
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        // Signed out, agy asks on its error output and waits: stop it as soon as it does.
        let state = State()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else if state.sawSignIn(chunk) { process.terminate() }
        }
        do { try process.run() } catch { return .failure(.signInRequired) }
        let stop = DispatchWorkItem {
            guard process.isRunning else { return }
            state.timedOut()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()     // until agy exits
        process.waitUntilExit()
        stop.cancel()
        errors.fileHandleForReading.readabilityHandler = nil
        if state.signedOut || signsIn(data) { return .failure(.signInRequired) }
        if state.expired { return .failure(.network) }
        return .success(data)
    }

    /// An answer that failed for want of a sign-in: `{"status":"ERROR","error":"authentication failed or timed out"}`.
    static func signsIn(_ data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["status"] as? String)?.uppercased() == "ERROR" else { return false }
        return (root["error"] as? String)?.localizedCaseInsensitiveContains("authenticat") == true
    }

    /// What happened while agy ran, from the threads that watch it.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var errors = Data()
        private var signIn = false, timeout = false

        var signedOut: Bool { lock.withLock { signIn } }
        var expired: Bool { lock.withLock { timeout } }
        func timedOut() { lock.withLock { timeout = true } }

        /// Adds error output; true the first time it asks to sign in.
        func sawSignIn(_ chunk: Data) -> Bool {
            lock.withLock {
                guard !signIn, errors.count < 65_536 else { return false }
                errors.append(chunk)
                signIn = String(decoding: errors, as: UTF8.self).contains("Authentication required")
                return signIn
            }
        }
    }
}
