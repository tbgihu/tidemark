import Foundation

/// Runs `/usr/bin/security`, bounded in time. A keychain that locked just now, or a dialog, would otherwise block
/// the tool, and whoever waits for it, indefinitely: a run that overruns is stopped and reported as `.timedOut`.
enum SecurityTool {
    /// `input`, when given, is written to the tool's standard input, which is then closed: that is how a secret
    /// reaches it, never through its arguments.
    static func run(_ arguments: [String], input: String?, timeout: TimeInterval,
                    executable: String = SecretStore.tool) throws(SecretError) -> ToolResult {
        _ = ignoreBrokenPipes
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw .failed(-1) }

        // Both pipes are drained while the tool runs, so a full pipe never blocks it.
        let output = Collected(), errors = Collected()
        let drained = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: drained) { output.set(stdout.fileHandleForReading.readDataToEndOfFile()) }
        DispatchQueue.global(qos: .utility).async(group: drained) { errors.set(stderr.fileHandleForReading.readDataToEndOfFile()) }
        if let input {
            // Fails (broken pipe) only when the tool has already exited; its status says why.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            drained.wait()
            throw .timedOut
        }
        drained.wait()
        return ToolResult(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self),
                          error: String(decoding: errors.data, as: UTF8.self))
    }

    /// Writing to a tool that already exited must fail with an error, not end Tidemark with SIGPIPE.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        var data: Data { lock.withLock { value } }
        func set(_ data: Data) { lock.withLock { value = data } }
    }
}
