import Foundation
import Testing
@testable import TidemarkCore

@Suite struct UpdateTests {
    @Test func modes() {
        #expect(UpdateMode.allCases.map(\.title) == ["Automatically", "Download Only", "Manually"])
        #expect(UpdateMode.allCases.map(\.rawValue) == ["automatic", "download", "manual"])
        #expect(UpdateMode.stored(nil, legacyChecks: nil) == .automatic)
        #expect(UpdateMode.stored("download", legacyChecks: nil) == .downloadOnly)
        #expect(UpdateMode.stored("manual", legacyChecks: true) == .manual)
        #expect(UpdateMode.stored("bogus", legacyChecks: nil) == .automatic)
        // the old "check automatically" switch, turned off, is Manually; on or never set is Automatically
        #expect(UpdateMode.stored(nil, legacyChecks: false) == .manual)
        #expect(UpdateMode.stored(nil, legacyChecks: true) == .automatic)
        #expect(UpdateMode.stored("automatic", legacyChecks: false) == .automatic)
    }

    @Test func state() {
        for mode in UpdateMode.allCases {
            #expect(UpdateState.current(mode: mode, ready: false, newer: false, scheduled: false) == .none)
            #expect(UpdateState.current(mode: mode, ready: true, newer: false, scheduled: false) == .restart)
            #expect(UpdateState.current(mode: mode, ready: true, newer: true, scheduled: true) == .pending)
        }
        // a check that found something newer offers Download and Install only in Manually mode
        #expect(UpdateState.current(mode: .manual, ready: false, newer: true, scheduled: false) == .download)
        #expect(UpdateState.current(mode: .manual, ready: false, newer: true, scheduled: true) == .pending)
        #expect(UpdateState.current(mode: .automatic, ready: false, newer: true, scheduled: false) == .none)
        #expect(UpdateState.current(mode: .downloadOnly, ready: false, newer: true, scheduled: false) == .none)
        #expect(UpdateState.restart.title == "Restart to Update" && UpdateState.restart.actionable)
        #expect(UpdateState.download.title == "Download and Install" && UpdateState.download.actionable)
        #expect(UpdateState.pending.title == "Update Pending" && !UpdateState.pending.actionable)
        #expect(!UpdateState.none.actionable)
    }

    @Test func exitStatus() {
        #expect([0, 10, 3, 11, 1, 64, 128].map { UpdateCheck(status: Int32($0)) }
                == [.done, .available, .offline, .diverged, .failed, .failed, .failed])
        #expect(UpdateActivity(.diverged) == .diverged)
        #expect(UpdateActivity(.done) == .upToDate && UpdateActivity(.available) == .upToDate)
        #expect(UpdateActivity(.offline) == .offline && UpdateActivity(.failed) == .failed)
    }

    @Test func status() {
        #expect(UpdateActivity.checking.status(.restart) == "Checking for Updates…")
        #expect(UpdateActivity.downloading.status(.none) == "Downloading Update…")
        #expect(UpdateActivity.upToDate.status(.restart) == UpdateState.restart.summary)    // a known update wins
        #expect(UpdateActivity.upToDate.status(.none) == "Tidemark is up to date.")
        #expect(UpdateActivity.none.status(.none).isEmpty)
        #expect(UpdateActivity.none.status(.pending) == UpdateState.pending.summary)
        #expect(UpdateActivity.checking.busy && UpdateActivity.downloading.busy && !UpdateActivity.failed.busy)
    }

    /// A diverged clone is never "up to date", whether a click or the 2-hourly prepare found it so.
    @Test func divergedIsNeverUpToDate() {
        #expect(UpdateActivity.diverged.status(.none) == UpdateActivity.divergedStatus)
        #expect(UpdateActivity.upToDate.status(.none, diverged: true) == UpdateActivity.divergedStatus)
        #expect(UpdateActivity.none.status(.none, diverged: true) == UpdateActivity.divergedStatus)
        #expect(UpdateActivity.checking.status(.none, diverged: true) == "Checking for Updates…")
        #expect(UpdateActivity.divergedStatus.hasPrefix("Can’t update automatically"))
        #expect(UpdateActivity.repair == "git fetch origin && git reset --hard origin/main && make install")
    }

    /// `relation` in scripts/lib.sh, which update.sh decides with, from the commits only the clone has and only its
    /// upstream has.
    @Test(arguments: [(0, 0, "current"), (0, 3, "behind"), (2, 0, "ahead"), (1, 4, "diverged"), (12, 1, "diverged")])
    func relation(_ ahead: Int, _ behind: Int, _ expected: String) throws {
        let lib = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/lib.sh").standardized
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-f", "-c", "source \"$1\" && relation $2 $3", "relation", lib.path, String(ahead), String(behind)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0 && text == expected + "\n")
    }

    @Test func cadence() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdatePolicy.interval == 7200)
        #expect(UpdatePolicy.due(lastChecked: nil, now: now))
        #expect(!UpdatePolicy.due(lastChecked: now - 7199, now: now))
        #expect(UpdatePolicy.due(lastChecked: now - 7200, now: now))
        #expect(UpdatePolicy.due(lastChecked: now + 60, now: now))                       // the clock was set back
    }

    @Test func automaticInstall() {
        // Automatically installs as soon as an update is ready…
        #expect(UpdatePolicy.installsByItself(mode: .automatic, ready: true, signingIn: false, alreadyTried: false))
        // …never during a sign-in, never twice for the same prepared commit, never in the other modes
        #expect(!UpdatePolicy.installsByItself(mode: .automatic, ready: true, signingIn: true, alreadyTried: false))
        #expect(!UpdatePolicy.installsByItself(mode: .automatic, ready: true, signingIn: false, alreadyTried: true))
        #expect(!UpdatePolicy.installsByItself(mode: .automatic, ready: false, signingIn: false, alreadyTried: false))
        #expect(!UpdatePolicy.installsByItself(mode: .downloadOnly, ready: true, signingIn: false, alreadyTried: false))
        #expect(!UpdatePolicy.installsByItself(mode: .manual, ready: true, signingIn: false, alreadyTried: false))
    }

    @Test func restart() {
        #expect(UpdatePolicy.restart(ready: true, newer: false, signingIn: false) == .install)
        #expect(UpdatePolicy.restart(ready: false, newer: true, signingIn: false) == .install)
        #expect(UpdatePolicy.restart(ready: true, newer: false, signingIn: true) == .schedule)
        #expect(UpdatePolicy.restart(ready: false, newer: false, signingIn: false) == .nothing)
        #expect(UpdatePolicy.restart(ready: false, newer: false, signingIn: true) == .nothing)
    }
}
