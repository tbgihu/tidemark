import Foundation

/// How updates arrive, the Updates setting. Automatically checks every 2 hours, prepares (fetches and builds) what
/// is new, and installs it as soon as it is ready. Download Only checks and prepares the same way, then installs
/// when you click Restart to Update. Manually checks only when you click Check for Updates.
enum UpdateMode: String, CaseIterable, Sendable {
    case automatic, downloadOnly = "download", manual

    var title: String {
        switch self {
        case .automatic: "Automatically"
        case .downloadOnly: "Download Only"
        case .manual: "Manually"
        }
    }

    /// The one line Settings shows under the setting.
    var note: String {
        switch self {
        case .automatic: "Downloads updates automatically and installs them as soon as they’re ready, then reopens Tidemark. Never during a sign-in."
        case .downloadOnly: "Downloads updates automatically and installs them when you click Restart to Update."
        case .manual: "Checks only when you click Check for Updates."
        }
    }

    /// The stored setting. Before there were three modes, a switch turned automatic checks off: that is Manually.
    static func stored(_ raw: String?, legacyChecks: Bool?) -> UpdateMode {
        if let raw, let mode = UpdateMode(rawValue: raw) { return mode }
        return legacyChecks == false ? .manual : .automatic
    }
}

/// The update shown in Settings: nothing to install, a newer version found but not downloaded (Manually), one
/// downloaded and ready, or one requested during a sign-in, which installs once the sign-in ends.
enum UpdateState: Equatable, Sendable {
    case none, download, restart, pending

    /// What its button says.
    var title: String {
        switch self {
        case .none: ""
        case .download: "Download and Install"
        case .restart: "Restart to Update"
        case .pending: "Update Pending"
        }
    }

    var summary: String {
        switch self {
        case .none: ""
        case .download: "A new version of Tidemark is available."
        case .restart: "A new version of Tidemark is ready."
        case .pending: "A new version of Tidemark is ready. It installs as soon as the sign-in ends."
        }
    }

    /// Whether its button is enabled. Pending shows it greyed out.
    var actionable: Bool { self == .download || self == .restart }

    /// One already downloaded (`ready`), or in Manually mode a newer version a check found (`newer`); `scheduled`
    /// when Update was clicked during a sign-in.
    static func current(mode: UpdateMode, ready: Bool, newer: Bool, scheduled: Bool) -> UpdateState {
        guard ready || (mode == .manual && newer) else { return .none }
        return scheduled ? .pending : ready ? .restart : .download
    }
}

/// How a check or a prepare ended, from `update.sh`'s exit status: 0 done, 10 a newer version exists (check), 3
/// the remote couldn't be reached, 11 the clone's history diverged from its source (`relation` in scripts/lib.sh), so
/// only resetting it, which Tidemark never does by itself, can update it.
enum UpdateCheck: Equatable, Sendable {
    case done, available, offline, diverged, failed

    init(status: Int32) {
        self = switch status {
        case 0: .done
        case 10: .available
        case 3: .offline
        case 11: .diverged
        default: .failed
        }
    }
}

/// What a Check for Updates clicked in Settings is doing, or how it went.
enum UpdateActivity: Equatable, Sendable {
    case none, checking, downloading, upToDate, offline, diverged, failed

    /// What Settings says of a diverged clone, never "up to date".
    static let divergedStatus = "Can’t update automatically: this copy’s history differs from the source."
    /// What to run in the clone to bring it back to its source.
    static let repair = "git fetch origin && git reset --hard origin/main && make install"

    var busy: Bool { self == .checking || self == .downloading }

    /// How a finished check is reported: "up to date" is shown only when no newer version is known.
    init(_ check: UpdateCheck) {
        self = switch check {
        case .done, .available: .upToDate
        case .offline: .offline
        case .diverged: .diverged
        case .failed: .failed
        }
    }

    /// The line Settings shows: progress first, then a known update, then a clone that can't be updated (`diverged`:
    /// the last check or prepare, clicked or not, found so), then how the last check went.
    func status(_ update: UpdateState, diverged: Bool = false) -> String {
        switch self {
        case .checking: "Checking for Updates…"
        case .downloading: "Downloading Update…"
        case _ where update != .none: update.summary
        case .diverged: Self.divergedStatus
        case _ where diverged: Self.divergedStatus
        case .upToDate: "Tidemark is up to date."
        case .offline: "Couldn’t check for updates. Try again when online."
        case .failed: "Couldn’t check for updates. Details are in ~/Library/Logs/Tidemark/update.log."
        case .none: ""
        }
    }
}

/// The decisions behind updates, apart from the processes and timers that carry them out.
enum UpdatePolicy {
    /// How often Automatically and Download Only look for an update.
    static let interval: TimeInterval = 2 * 3600

    /// Whether a prepare is due, the last one having finished at `lastChecked`. One in the future (the clock was
    /// set back) is due too, so a clock change can't stop updates.
    static func due(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked, lastChecked <= now else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// Whether to install without asking: in Automatically mode as soon as an update is ready, unless a sign-in is
    /// running (it installs when that ends), and only once per prepared commit, so an install that didn't take
    /// can't restart Tidemark over and over. Restart to Update then remains.
    static func installsByItself(mode: UpdateMode, ready: Bool, signingIn: Bool, alreadyTried: Bool) -> Bool {
        mode == .automatic && ready && !signingIn && !alreadyTried
    }

    enum Restart: Equatable { case install, schedule, nothing }

    /// Download and Install, or Restart to Update, was clicked: install now, or once the sign-in in progress ends.
    static func restart(ready: Bool, newer: Bool, signingIn: Bool) -> Restart {
        guard ready || newer else { return .nothing }
        return signingIn ? .schedule : .install
    }
}
