import AppKit

/// Updates come from the git clone Tidemark was built from (Info.plist `TidemarkSource`), through its
/// `scripts/update.sh`, in two halves:
///
/// - **prepare**, every 2 hours while Tidemark runs (Automatically and Download Only): fetch, and when the clone's
///   upstream is ahead of this build, build that commit into a stage (`~/Library/Caches/Tidemark/update`). Nothing
///   installed changes.
/// - **install**, once a stage is ready: Tidemark quits, the installer fast-forwards the clone, swaps in the staged
///   app and opens Tidemark again. Automatically does this as soon as the stage is ready (at launch too), unless a
///   sign-in is running, in which case it waits for the sign-in to end. Otherwise you choose Restart to Update.
///
/// Manually only fetches and compares, when you click Check for Updates; Download and Install then prepares and
/// installs in one go. Everything about updates is shown in Settings.
@MainActor
final class Updater {
    /// The commit this build is from ("+" when it had local changes), and the clone it came from.
    static let commit = Bundle.main.object(forInfoDictionaryKey: "TidemarkCommit") as? String
    static let source = Bundle.main.object(forInfoDictionaryKey: "TidemarkSource") as? String

    static var mode: UpdateMode {
        get {
            let defaults = UserDefaults.standard
            return UpdateMode.stored(defaults.string(forKey: "updates"), legacyChecks: defaults.object(forKey: "checkForUpdates") as? Bool)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "updates")
            UserDefaults.standard.removeObject(forKey: "checkForUpdates")
        }
    }

    /// Whether a sign-in is running: an update never interrupts one.
    var signingIn: () -> Bool = { false }
    var onChange: (() -> Void)?

    /// A Check for Updates clicked in Settings: what it is doing, then how it went.
    private(set) var activity = UpdateActivity.none
    /// In Manually mode, a check found a newer version that isn't downloaded yet.
    private(set) var newer = false
    /// The last check or prepare found the clone's history diverged from its source: it can't update by itself.
    private(set) var diverged = false
    /// Update was clicked during a sign-in; it installs once the sign-in ends.
    private var scheduled = false
    private var installing = false
    private var preparing = false
    private var building = false
    private var waiting: [@MainActor (UpdateCheck) -> Void] = []
    private var timer: Timer?
    private let script: URL?
    private let stage = URL.cachesDirectory.appending(path: "Tidemark/update", directoryHint: .isDirectory)
    private static let log = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Tidemark/update.log")

    init() {
        script = Self.source
            .map { URL(filePath: $0).appending(path: "scripts/update.sh") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// False for a build without a clone (a downloaded ZIP), which has nothing to update from.
    var supported: Bool { script != nil }

    /// The commit a prepared update was built from, when one is waiting: the stage holds an app built from a
    /// commit other than this one.
    private var staged: String? {
        guard script != nil, FileManager.default.fileExists(atPath: stage.appending(path: "Tidemark.app").path),
              let staged = try? String(contentsOf: stage.appending(path: "commit"), encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !staged.isEmpty, staged != Self.commit?.trimmingCharacters(in: ["+"]) else { return nil }
        return staged
    }

    var ready: Bool { staged != nil }

    var state: UpdateState {
        UpdateState.current(mode: Self.mode, ready: ready, newer: newer, scheduled: scheduled)
    }

    /// The prepared commit Automatically last tried to install by itself. Still being on the old build with that
    /// same commit staged means the install didn't take, and it isn't retried by itself.
    private static var tried: String? {
        get { UserDefaults.standard.string(forKey: "updateTried") }
        set { UserDefaults.standard.set(newValue, forKey: "updateTried") }
    }

    var installsByItself: Bool {
        UpdatePolicy.installsByItself(mode: Self.mode, ready: ready, signingIn: signingIn(),
                                      alreadyTried: staged != nil && staged == Self.tried)
    }

    // MARK: Schedule

    /// Prepares now if the last check is older than the interval, then every interval while Tidemark runs. Does
    /// nothing in Manually mode. Called again when the mode changes.
    func start() {
        timer?.invalidate()
        timer = nil
        guard script != nil, Self.mode != .manual else { return }
        let checked = (try? stage.appending(path: "checked").resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if UpdatePolicy.due(lastChecked: checked) { prepare() }
        let timer = Timer(timeInterval: UpdatePolicy.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepare() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The Updates setting changed.
    func modeChanged(_ mode: UpdateMode) {
        Self.mode = mode
        start()
        onChange?()
    }

    // MARK: Checking and preparing

    /// Check for Updates, from Settings. Checks now whatever the mode and shows progress and the result in
    /// Settings. In Manually mode it only checks, and Settings then offers Download and Install. Otherwise it also
    /// downloads, and Settings offers Restart to Update (or Automatically installs it).
    func checkNow() {
        guard script != nil, !activity.busy, !installing else { return }
        activity = building ? .downloading : .checking          // joining a prepare already downloading
        onChange?()
        let report: @MainActor (UpdateCheck) -> Void = { [weak self] check in
            guard let self else { return }
            self.activity = UpdateActivity(check)
            self.onChange?()
        }
        if Self.mode == .manual { check(then: report) } else { prepare(then: report) }
    }

    /// Settings closed: a finished check's result is forgotten, one under way keeps going.
    func settingsClosed() {
        if !activity.busy { activity = .none }
    }

    /// Fetches and compares only, for Manually mode. Nothing is downloaded or built.
    private func check(then: @escaping @MainActor (UpdateCheck) -> Void) {
        guard let script else { return then(.failed) }
        let process = run(script, ["check"])
        process.terminationHandler = { [weak self] process in
            let check = UpdateCheck(status: process.terminationStatus)
            Task { @MainActor in
                self?.newer = check == .available
                if check != .offline, check != .failed { self?.diverged = check == .diverged }
                self?.onChange?()
                then(check)
            }
        }
        if (try? process.run()) == nil { then(.failed) }
    }

    /// Fetches and, when there is something new, builds it into the stage. `then` gets the result. A prepare
    /// already under way (the 2-hourly one, say) is joined rather than started twice.
    private func prepare(then: (@MainActor (UpdateCheck) -> Void)? = nil) {
        if let then { waiting.append(then) }
        guard let script, !preparing, !installing else { if script == nil { finish(.failed) }; return }
        let process = run(script, ["prepare"]) { [weak self] output in
            guard output.contains("building") else { return }
            Task { @MainActor in
                guard let self else { return }
                self.building = true
                if self.activity == .checking { self.activity = .downloading }
                self.onChange?()
            }
        }
        process.qualityOfService = .utility
        process.terminationHandler = { [weak self] process in
            let check = UpdateCheck(status: process.terminationStatus)
            Task { @MainActor in self?.finish(check) }
        }
        preparing = (try? process.run()) != nil
        if !preparing { finish(.failed) }
    }

    private func finish(_ check: UpdateCheck) {
        building = false
        preparing = false
        if check != .offline, check != .failed { diverged = check == .diverged }
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0(check) }
        onChange?()
        installIfAutomatic()
    }

    // MARK: Installing

    /// Automatically: installs a ready update now, unless a sign-in is running. Called at launch, after every
    /// prepare and when a sign-in ends. Returns whether Tidemark is quitting into the installer.
    @discardableResult
    func installIfAutomatic() -> Bool {
        guard !installing, installsByItself else { return false }
        Self.tried = staged
        return install()
    }

    /// Download and Install, or Restart to Update, was clicked. During a sign-in it waits until the sign-in ends.
    func restartToUpdate() {
        switch UpdatePolicy.restart(ready: ready, newer: newer, signingIn: signingIn()) {
        case .install: install()
        case .schedule:
            scheduled = true
            onChange?()
        case .nothing: onChange?()
        }
    }

    /// A sign-in ended: installs the update clicked meanwhile, or one Automatically held back.
    func signInEnded() {
        if scheduled {
            scheduled = false
            restartToUpdate()
        } else {
            installIfAutomatic()
        }
    }

    /// Starts the installer, which waits for Tidemark to exit, installs the newest commit (preparing it first unless
    /// the stage is fresh) and opens Tidemark again whatever happens; then quits.
    @discardableResult
    private func install() -> Bool {
        guard let script, !installing, (try? run(script, ["install", "--after", String(getpid())]).run()) != nil else {
            activity = .failed
            onChange?()
            return false
        }
        installing = true
        timer?.invalidate()
        NSApp.terminate(nil)
        return true
    }

    /// A process for the script with its output appended to update.log (trimmed once it passes 512 KB). `watch`
    /// also sees the output as it arrives.
    private func run(_ script: URL, _ arguments: [String], watch: (@Sendable (String) -> Void)? = nil) -> Process {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: Self.log.path))?[.size] as? Int, size > 512 * 1024 {
            try? manager.removeItem(at: Self.log)
        }
        if !manager.fileExists(atPath: Self.log.path) { manager.createFile(atPath: Self.log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: Self.log) else { return process }
        handle.seekToEndOfFile()
        process.standardError = handle
        guard let watch else { process.standardOutput = handle; return process }
        let pipe = Pipe()
        // Called on a queue of FileHandle's, so it is Sendable and touches nothing of the main actor's.
        pipe.fileHandleForReading.readabilityHandler = { @Sendable reader in
            let data = reader.availableData
            guard !data.isEmpty else { reader.readabilityHandler = nil; return }
            handle.write(data)
            watch(String(decoding: data, as: UTF8.self))
        }
        process.standardOutput = pipe
        return process
    }
}
