import AppKit

/// Where Tidemark keeps its files, and the bundle identity everything is keyed by.
enum Paths {
    static let identifier = Bundle.main.bundleIdentifier ?? "io.github.tbgihu.tidemark"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    /// ~/Library/Application Support/Tidemark (a scratch folder in the sample mode of debug builds).
    nonisolated(unsafe) static var support: URL = URL.applicationSupportDirectory.appending(path: "Tidemark", directoryHint: .isDirectory)
    static var state: URL { support.appending(path: "state.json") }
    static var history: URL { support.appending(path: "History", directoryHint: .isDirectory) }

    static var costs: URL { support.appending(path: "Costs", directoryHint: .isDirectory) }

    static func history(_ account: String) -> URL {
        history.appending(path: "\(safe(account)).bin")
    }

    /// An account's cached daily costs.
    static func costs(_ account: String) -> URL {
        costs.appending(path: "\(safe(account)).json")
    }

    private static func safe(_ account: String) -> String {
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return safe.isEmpty ? "account" : safe
    }
}

/// Settings that aren't per account, in user defaults.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    /// The refresh interval chosen in Settings, or the default. Setting it records that it was chosen.
    static var interval: TimeInterval {
        get {
            Interval.stored(defaults.object(forKey: "interval") as? Double,
                            chosen: defaults.object(forKey: "intervalChosen") as? Bool)
        }
        set {
            defaults.set(newValue, forKey: "interval")
            defaults.set(true, forKey: "intervalChosen")
        }
    }
    /// An item of its own for every account, rather than one shared by all.
    static var separateItems: Bool {
        get { defaults.bool(forKey: "separateItems") }
        set { defaults.set(newValue, forKey: "separateItems") }
    }
    static var notifications: Bool {
        get { defaults.bool(forKey: "notifications") }
        set { defaults.set(newValue, forKey: "notifications") }
    }
    /// Set once Tidemark has registered itself as a login item, so turning that off later sticks.
    static var loginItemInitialized: Bool {
        get { defaults.bool(forKey: "loginItemInitialized") }
        set { defaults.set(newValue, forKey: "loginItemInitialized") }
    }
    /// The history chart's time frame, shared by every account.
    static var historyRange: String {
        get { defaults.string(forKey: "historyRange") ?? "day" }
        set { defaults.set(newValue, forKey: "historyRange") }
    }
}

/// One login's credentials for every account, as one JSON value in a Keychain item of Tidemark's (`SecretStore`): each
/// login has its own item (`Login.secretItem`), so adding an account of one never rewrites another's. Read once, at the first
/// need, then kept in memory; written only when a secret changes (a sign-in, a token's rotation, a removal). Every
/// Keychain call runs off the main thread, one at a time (`Secrets`). Secrets are never logged or written anywhere
/// else. A vault that isn't persistent (the sample mode of debug builds) keeps everything in memory.
@MainActor
final class Vault<Value: Codable & Equatable & Sendable> {
    /// Everything, once read; nil until then.
    private var cache: [String: Value]?
    /// Changes made before the item could be read: used meanwhile, written once it has been.
    private var pending: [String: Value?] = [:]
    /// What the Keychain holds as far as Tidemark knows; nil when unknown, so the next write happens regardless.
    private var stored: [String: Value]?
    private var reading: Task<Result<String?, SecretError>, Never>?
    private var writing = false
    /// The wait before writing again after a failure that waiting may cure (a timeout, the tool failing): it doubles
    /// up to 15 minutes. A locked keychain is retried when it unlocks instead.
    private var retryDelay: Duration = .seconds(60)
    private var retrying = false
    let account: String
    private let store: SecretStore?
    /// Called when `unsaved` may have changed.
    var onChange: (() -> Void)?

    init(account: String, store: SecretStore?) {
        self.account = account
        self.store = store
        if store == nil { cache = [:] }
    }

    /// True while a change isn't in the Keychain yet because it couldn't be written (the keychain is locked, or the
    /// write failed): the secrets work until Tidemark quits, and are written once the Keychain takes them.
    private(set) var unsaved = false {
        didSet { if unsaved != oldValue { onChange?() } }
    }

    /// Whether the last read or write found the keychain locked.
    private(set) var locked = false

    /// An account's secret; nil when it has none. Throws when the Keychain can't be read right now, which is not the
    /// same as having none.
    func value(_ id: String) async throws(FetchFailure) -> Value? {
        if let index = pending.index(forKey: id) { return pending[index].value }
        return try await load()[id]
    }

    /// Saves or (nil) deletes an account's secret. Before the item could be read, the change is kept aside and
    /// written once it has been, so the other accounts' secrets are never overwritten with an incomplete set.
    func set(_ id: String, _ value: Value?) {
        guard cache != nil else {
            pending[id] = .some(value)
            Task { _ = try? await load() }
            return
        }
        cache?[id] = value
        flush()
    }

    /// Tries again what couldn't be done: as when the keychain was unlocked.
    func retry() {
        if cache == nil, !pending.isEmpty { Task { _ = try? await load() } }
        flush()
    }

    /// Every account's secrets: from memory, or read once from the Keychain.
    private func load() async throws(FetchFailure) -> [String: Value] {
        if let cache { return cache }
        guard let store else { return [:] }
        let task: Task<Result<String?, SecretError>, Never>
        if let reading {
            task = reading
        } else {
            let account = account
            task = Task { await Secrets.perform { Result { () throws(SecretError) in try store.read(account) } } }
            reading = task
        }
        let result = await task.value
        if reading == task { reading = nil }
        if let cache { return cache }                                  // another caller took it already
        var all: [String: Value]
        switch result {
        case .success(let text):
            locked = false
            all = [:]
            if let text {
                if let decoded = try? JSONDecoder().decode([String: Value].self, from: Data(text.utf8)) {
                    all = decoded
                    stored = decoded
                } else {
                    Log.keychain.error("\(self.account, privacy: .public) doesn't decode: replaced with the next write")
                }
            } else {
                stored = [:]
            }
            Log.keychain.debug("\(self.account, privacy: .public) read")
        case .failure(.damaged), .failure(.foreign):
            // Unusable either way: Tidemark starts afresh, and replaces a damaged item (never a foreign one).
            Log.keychain.error("\(self.account, privacy: .public) unusable: \(String(describing: result), privacy: .public)")
            locked = false
            all = [:]
        case .failure(let error):
            locked = error == .locked
            if !pending.isEmpty { unsaved = true }
            Log.keychain.info("\(self.account, privacy: .public) not read: \(String(describing: error), privacy: .public)")
            throw error == .locked ? .keychainLocked : .keychain
        }
        for (id, value) in pending { all[id] = value }
        pending = [:]
        cache = all
        flush()
        return all
    }

    /// Writes again after `retryDelay`, once at a time, so secrets that live only in memory aren't lost at quit.
    private func retryLater() {
        guard !retrying else { return }
        retrying = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(900))
        Task {
            try? await Task.sleep(for: delay)
            retrying = false
            flush()
        }
    }

    /// Writes what changed, one write at a time; a change made meanwhile is written after it.
    private func flush() {
        guard let store, !writing, let snapshot = cache else { return }
        guard snapshot != stored else { unsaved = false; return }
        writing = true
        let account = account
        let text = snapshot.isEmpty ? nil : (try? JSONEncoder().encode(snapshot)).map { String(decoding: $0, as: UTF8.self) }
        Task {
            let result = await Secrets.perform {
                Result { () throws(SecretError) in
                    if let text { try store.write(account, text) } else { try store.delete(account) }
                }
            }
            writing = false
            switch result {
            case .success:
                stored = snapshot
                locked = false
                retryDelay = .seconds(60)
                Log.keychain.debug("\(account, privacy: .public) written")
                if cache != stored { flush() } else { unsaved = false }
            case .failure(let error):
                if error != .locked { stored = nil }                   // a failed write leaves nothing of itself
                locked = error == .locked
                unsaved = true
                Log.keychain.error("\(account, privacy: .public) not written: \(String(describing: error), privacy: .public)")
                switch error {
                case .timedOut, .unverified, .failed: retryLater()
                default: break
                }
            }
        }
    }
}

/// Tidemark's Keychain items (service: the bundle identifier, one item per login) and the one queue every Keychain
/// call runs on.
enum Secrets {
    /// The login keychain's store.
    static let store = SecretStore(service: Paths.identifier, keychain: .login)

    private static let queue = DispatchQueue(label: "\(Paths.identifier).keychain", qos: .userInitiated)

    /// Runs `work` (blocking calls to the tool) on the Keychain queue.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }
}

/// Notices when the login keychain is unlocked again, without asking anyone: on waking, on the session becoming
/// active or the screen being unlocked, and every minute meanwhile, by its status alone.
@MainActor
final class KeychainWatch {
    var onUnlock: (() -> Void)?
    private var timer: Timer?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Starts watching, until the keychain is unlocked.
    func wait() {
        guard timer == nil else { return }
        Log.keychain.info("waiting for the login keychain to be unlocked")
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard timer != nil, let path = KeychainTarget.login.path(), KeychainTarget.login.isUnlocked(path) else { return }
        timer?.invalidate()
        timer = nil
        Log.keychain.info("the login keychain is unlocked")
        onUnlock?()
    }
}

/// Appends meter samples to each account's history file and compacts it once a day, off the main thread.
actor HistoryRecorder {
    private var last: [String: History.Sample] = [:]
    private var compacted: [String: Date] = [:]

    /// Records the meters `charted` names.
    func record(_ snapshot: Snapshot, charted: [ChartedMeter], account: String) {
        let url = Paths.history(account)
        let sample = History.Sample(snapshot, charted: charted)
        if last[account] == nil { last[account] = History.last(url) }
        guard History.shouldAppend(sample, after: last[account]) else { return }
        do {
            if compacted[account].map({ Date().timeIntervalSince($0) > 86400 }) ?? true {
                _ = try? History.compactFile(url)
                compacted[account] = Date()
            }
            try History.append(sample, to: url)
            last[account] = sample
        } catch {}
    }

    func delete(_ account: String) {
        last[account] = nil
        compacted[account] = nil
        try? FileManager.default.removeItem(at: Paths.history(account))
    }

    nonisolated static func load(_ account: String) async -> [History.Sample] {
        await Task.detached(priority: .userInitiated) { History.read(Paths.history(account)) }.value
    }
}

/// Each account's daily costs (`CostLedger`), cached in a small file, read and written off the main thread.
actor CostStore: CostCache {
    private var ledgers: [String: CostLedger] = [:]

    /// The ledger, from memory or its file; empty when there is none.
    func ledger(_ account: String) -> CostLedger {
        if let ledger = ledgers[account] { return ledger }
        let ledger = (try? Data(contentsOf: Paths.costs(account))).flatMap { try? JSONDecoder().decode(CostLedger.self, from: $0) }
            ?? CostLedger()
        ledgers[account] = ledger
        return ledger
    }

    /// Takes what a request read for `range`, forgets what is older than the cache keeps, and saves.
    func merge(_ account: String, _ days: [Date: Decimal], covering range: Range<Date>, now: Date) -> CostLedger {
        var ledger = ledger(account)
        ledger.merge(days, covering: range)
        ledger.prune(before: CostCalendar.add(days: -CostLedger.keepDays, to: CostCalendar.day(now)))
        ledgers[account] = ledger
        let url = Paths.costs(account)
        if let data = try? JSONEncoder().encode(ledger) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return ledger
    }

    func delete(_ account: String) {
        ledgers[account] = nil
        try? FileManager.default.removeItem(at: Paths.costs(account))
    }
}
