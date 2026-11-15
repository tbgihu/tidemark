import AppKit
import Network

/// How an account's last refresh went, beyond its saved data.
struct Health: Equatable {
    var failures = 0
    var notBefore = Date.distantPast
    var lastAttempt: Date?
    var error: FetchFailure?
    var loading = false
}

/// The accounts of every provider (grouped by provider, in the fixed order; in the configured order within each),
/// their snapshots, and when each is refreshed: one scheduler staggers them all. Everything visible observes it
/// through `onChange`; it owns no views. Nothing here knows a provider: each account's `Provider` and `Login` say how
/// to read it.
@MainActor
final class Model {
    private(set) var accounts: [Account] = []
    private(set) var health: [String: Health] = [:]
    private(set) var interval: TimeInterval
    /// Every account with a menu bar item of its own; otherwise all share one.
    private(set) var separateItems: Bool
    var onChange: [() -> Void] = []

    let http = HTTP.shared
    let history = HistoryRecorder()
    let costs = CostStore()
    let notifier = Notifier()
    private let keychainWatch: KeychainWatch?
    private var fired = Set<String>()
    private var timer: Timer?
    private var paused = false
    /// One Keychain item per login, read on first need.
    private var vaults: [String: Vault<Credential>] = [:]
    private var refreshing: [String: Task<Credential, any Error>] = [:]
    /// Accounts whose older costs are being read for the history chart.
    private var backfilling: Set<String> = []
    private var queue: [String] = []
    private var draining = false
    private var pathMonitor: NWPathMonitor?
    private var online = true
    /// False when state.json couldn't be read: it is then kept aside, never overwritten.
    private var writable = true
    /// In the sample mode of debug builds nothing is loaded, saved or fetched.
    private let persistent: Bool

    init(persistent: Bool = true) {
        self.persistent = persistent
        interval = persistent ? Preferences.interval : Interval.defaultValue
        separateItems = persistent && Preferences.separateItems
        keychainWatch = persistent ? KeychainWatch() : nil
        guard persistent else { return }
        let data = try? Data(contentsOf: Paths.state)
        if let state = SavedState.load(data) {
            accounts = state.accounts
            fired = Alerts.prune(state.fired)
        } else {
            // Not readable at all: keep it for the user, start empty.
            let aside = Paths.state.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            writable = (try? FileManager.default.moveItem(at: Paths.state, to: aside)) != nil
        }
    }

    func start() {
        guard persistent else { return }
        observeSystem()
        keychainWatch?.onUnlock = { [weak self] in self?.keychainUnlocked() }
        schedule(after: 1)
    }

    // MARK: Accounts

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    /// The Keychain item of a login's credentials.
    func vault(_ item: String) -> Vault<Credential> {
        if let vault = vaults[item] { return vault }
        let vault = Vault<Credential>(account: item, store: persistent ? Secrets.store : nil)
        vault.onChange = { [weak self] in self?.vaultChanged() }
        vaults[item] = vault
        return vault
    }

    /// Whether a credential couldn't be saved yet, and whether that is because the login keychain is locked.
    var unsavedCredentials: (unsaved: Bool, locked: Bool) {
        (vaults.values.contains(where: \.unsaved), vaults.values.contains(where: \.locked))
    }

    /// Adds a signed-in account, or updates it when it is already here (the same identity): the new credential
    /// replaces the old one. Returns its id.
    @discardableResult
    func add(_ identity: Identity, credential: Credential, provider: Provider, login: Login) -> String {
        let id = login.accountID(identity.id)
        vault(login.secretItem).set(id, credential)
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].name = identity.name
            accounts[index].email = identity.email
            accounts[index].needsSignIn = false
            accounts[index].profileFetchedAt = Date()
        } else {
            accounts.append(Account(id: id, provider: provider.id, login: login.id, name: identity.name,
                                    email: identity.email, profileFetchedAt: Date()))
            accounts = SavedState.grouped(accounts)
        }
        health[id] = Health(loading: health[id]?.loading ?? false)   // a fetch may be in flight
        changed()
        refresh(id)
        return id
    }

    func remove(_ id: String) {
        let removed = account(id)
        accounts.removeAll { $0.id == id }
        health[id] = nil
        queue.removeAll { $0 == id }
        if let removed, let (_, login) = Registry.resolve(removed) {
            let vault = vault(login.secretItem)
            if case .web = login.auth {
                // Its web data store goes with it: read which one first.
                Task {
                    let store = ((try? await vault.value(id)) ?? nil)?.fields[WebLogin.storeField]
                    if self.account(id) == nil { vault.set(id, nil) }
                    if let store { await WebSignIn.forget(store: store) }
                }
            } else {
                vault.set(id, nil)
            }
            if case .dailyCosts = login.history { Task { await costs.delete(id) } }
        }
        fired = fired.filter { !$0.hasPrefix(id + "|") }
        notifier.removeDelivered(account: id)
        Task { await history.delete(id) }
        changed()
        schedule()
    }

    /// Puts one provider's accounts in the order of `ids`; the other providers' stay as they are.
    func reorder(_ ids: [String]) {
        guard let provider = ids.first.flatMap(account)?.provider else { return }
        let current = accounts.of(provider)
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byID[$0] }
        guard ordered.count == current.count, ordered.map(\.id) != current.map(\.id) else { return }
        var replacements = ordered.makeIterator()
        accounts = accounts.map { $0.provider == provider ? replacements.next()! : $0 }
        changed()
    }

    func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var account = accounts[index]
        change(&account)
        guard account != accounts[index] else { return }
        accounts[index] = account
        changed()
    }

    func setInterval(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        if persistent { Preferences.interval = seconds }
        schedule()
        touch()                                                        // the freshness window follows the interval
    }

    func setSeparateItems(_ on: Bool) {
        guard on != separateItems else { return }
        separateItems = on
        if persistent { Preferences.separateItems = on }
        touch()
    }

    /// Tells every view to redraw, as when the time zone or locale changed.
    func touch() { onChange.forEach { $0() } }

    private func changed() {
        save()
        onChange.forEach { $0() }
    }

    private func save() {
        guard persistent, writable else { return }
        let state = SavedState(accounts: accounts, fired: fired)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? data.write(to: Paths.state, options: [.atomic])           // a quit mid-write leaves the old file
    }

    // MARK: Refreshing

    /// Refreshes `id` soon unless it is backing off, already loading, or needs signing in.
    func refresh(_ id: String) {
        guard persistent, !queue.contains(id) else { return }
        queue.append(id)
        drain()
    }

    /// Refreshes every account whose last attempt is older than `age`, as when the panel opens, but never more often
    /// than its provider allows.
    func refreshIfOlder(than age: TimeInterval) {
        for account in accounts where !account.needsSignIn {
            let last = health[account.id]?.lastAttempt ?? .distantPast
            let age = pace(account).effective(age)
            if abs(Date().timeIntervalSince(last)) > age { refresh(account.id) }
        }
    }

    /// A change couldn't be saved, or now has been: Settings says so, and a locked keychain is watched.
    private func vaultChanged() {
        if unsavedCredentials.locked { keychainWatch?.wait() }
        touch()
    }

    /// The login keychain was unlocked: writes what is waiting, and refreshes the accounts that waited for it.
    private func keychainUnlocked() {
        vaults.values.forEach { $0.retry() }
        for account in accounts where [.keychainLocked, .keychain].contains(health[account.id]?.error) {
            health[account.id]?.notBefore = .distantPast
            refresh(account.id)
        }
    }

    /// How often an account may be read.
    func pace(_ account: Account) -> Pace {
        Registry.resolve(account).map { $0.provider.pace($0.login) } ?? .standard
    }

    /// How often an account is refreshed: the setting, within what its provider allows.
    func interval(for account: Account) -> TimeInterval { pace(account).effective(interval) }

    // MARK: What may be shown

    /// Whether Tidemark can currently read the account at all. Not when it is signed out or its key was rejected
    /// (`needsSignIn`, which also covers missing tokens), nor while its credentials can't be read (the login keychain
    /// is locked, or the item unreadable). Then none of its saved values are shown.
    func authenticated(_ account: Account) -> Bool {
        guard !account.needsSignIn else { return false }
        switch health[account.id]?.error {
        case .keychainLocked, .keychain, .signInRequired, .unauthorized, .forbidden: return false
        default: return true
        }
    }

    /// An account's snapshot as it may be shown now; nil when none of it may.
    func shown(_ account: Account, now: Date = Date()) -> ShownSnapshot? {
        ShownSnapshot(account.snapshot, authenticated: authenticated(account), interval: interval(for: account), now: now)
    }

    /// When what an account shows next changes by itself (it turns late or expires, a meter resets, a period ends).
    func nextDisplayChange(_ account: Account, now: Date = Date()) -> Date? {
        ShownSnapshot.nextChange(account.snapshot, authenticated: authenticated(account), interval: interval(for: account),
                                 now: now)
    }

    /// Runs the queue one account at a time, a couple of seconds apart, so accounts never hit the API together.
    private func drain() {
        guard !draining, !paused, online else { return }
        draining = true
        Task {
            while !queue.isEmpty, !paused, online {
                let id = queue.removeFirst()
                if await fetch(id), !queue.isEmpty { try? await Task.sleep(for: .seconds(2)) }
            }
            draining = false
            schedule()
        }
    }

    /// One refresh. Returns whether a request was made.
    private func fetch(_ id: String) async -> Bool {
        guard let account = account(id), !account.needsSignIn, let (_, login) = Registry.resolve(account) else { return false }
        var state = health[id] ?? Health()
        // A backoff further away than any can be means the clock was set back: it no longer applies (as in Due).
        let wait = state.notBefore.timeIntervalSinceNow
        guard !state.loading, wait <= 0 || wait > Backoff.ceiling else {
            Log.fetch.debug("\(id, privacy: .private) skipped: \(state.loading ? "loading" : "backing off for \(Int(wait)) s", privacy: .public)")
            return false
        }
        Log.fetch.info("\(id, privacy: .private) fetching (\(account.provider, privacy: .public) \(account.login, privacy: .public))")
        state.loading = true
        state.lastAttempt = Date()
        health[id] = state
        onChange.forEach { $0() }

        let result: Result<Void, FetchFailure>
        do throws(FetchFailure) {
            let snapshot = try await read(id, login)                   // replaces the last: a meter it lacks goes
            result = .success(())
            succeeded(id)
            update(id) { account in
                account.snapshot = snapshot
                account.needsSignIn = false
                if let identity = snapshot.identity {
                    account.name = identity.name
                    account.email = identity.email
                }
            }
            let charted = login.history.charted
            if !charted.isEmpty { Task { await history.record(snapshot, charted: charted, account: id) } }
            alert(id, snapshot, login.alerts)
        } catch {
            result = .failure(error)
        }
        guard self.account(id) != nil else { return true }              // removed meanwhile
        var health = self.health[id] ?? Health()
        health.loading = false
        switch result {
        case .success:
            self.health[id] = health
            Log.fetch.info("\(id, privacy: .private) updated")
            if Date().timeIntervalSince(self.account(id)?.profileFetchedAt ?? .distantPast) > 86400 { await renewProfile(id, login) }
        case .failure(let failure):
            health.error = failure
            switch failure {
            case .signInRequired, .unauthorized, .forbidden:
                self.health[id] = health
                update(id) { $0.needsSignIn = true }
            case .offline:
                self.health[id] = health                               // the network monitor resumes it
            case .rateLimited(let after):
                health.failures += 1
                health.notBefore = Date().addingTimeInterval(Backoff.delay(failures: health.failures, retryAfter: after))
                self.health[id] = health
            case .keychainLocked:
                self.health[id] = health                               // the keychain watch resumes it
                keychainWatch?.wait()
            case .server, .network, .unreadable, .keychain:
                health.failures += 1
                health.notBefore = Date().addingTimeInterval(Backoff.delay(failures: health.failures, retryAfter: nil))
                self.health[id] = health
            }
            let backoff = health.notBefore.timeIntervalSinceNow
            Log.fetch.info("""
                \(id, privacy: .private) failed: \(String(describing: failure), privacy: .public), \
                failures in a row: \(health.failures), backing off \(backoff > 0 ? Int(backoff.rounded()) : 0) s
                """)
        }
        onChange.forEach { $0() }
        return true
    }

    /// The snapshot, with an expiring credential renewed first, and once more after a 401, when the login can.
    private func read(_ id: String, _ login: Login) async throws(FetchFailure) -> Snapshot {
        guard var credential = try await vault(login.secretItem).value(id) else { throw .signInRequired }
        let renewable = login.auth.refresh != nil
        if renewable, credential.needsRefresh() { credential = try await renew(id, login) }
        do {
            return try await login.fetch(context(id, credential))
        } catch .unauthorized where renewable && credential.refresh != nil {
            credential = try await renew(id, login)
            return try await login.fetch(context(id, credential))
        }
    }

    private func context(_ id: String, _ credential: Credential) -> FetchContext {
        FetchContext(account: id, credential: credential, http: http, now: Date(), costs: costs)
    }

    /// Clears a failure streak and its backoff once a refresh worked.
    private func succeeded(_ id: String) {
        var health = health[id] ?? Health()
        health.failures = 0
        health.error = nil
        health.notBefore = .distantPast
        self.health[id] = health
    }

    /// An account's cached costs reaching back to `start` (a year at most), reading the days still missing in
    /// 30-day requests, one at a time. `complete` is false when that stopped early (offline, rate limited, the
    /// credential rejected): the chart then shows what there is. A rate limit or a rejection counts as for any refresh.
    func costHistory(_ id: String, from start: Date) async -> (ledger: CostLedger, complete: Bool) {
        var ledger = await costs.ledger(id)
        guard persistent else { return (ledger, true) }
        guard let account = account(id), let (_, login) = Registry.resolve(account), let read = login.dailyCosts,
              !account.needsSignIn, online, !backfilling.contains(id),
              let credential = (try? await vault(login.secretItem).value(id)) ?? nil else { return (ledger, false) }
        backfilling.insert(id)
        defer { backfilling.remove(id) }
        let now = Date()
        for (index, chunk) in CostPlan.backfill(ledger, from: start, now: now).enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled, self.account(id) != nil,
                  (health[id]?.notBefore ?? .distantPast) <= Date() else { return (ledger, false) }
            do throws(FetchFailure) {
                let days = try await read(credential, chunk, http, now)
                ledger = await costs.merge(id, days, covering: chunk, now: now)
            } catch {
                switch error {
                case .rateLimited(let after):
                    var health = health[id] ?? Health()
                    health.failures += 1
                    health.notBefore = Date().addingTimeInterval(Backoff.delay(failures: health.failures, retryAfter: after))
                    self.health[id] = health
                case .unauthorized, .forbidden:
                    health[id]?.error = error
                    update(id) { $0.needsSignIn = true }
                default: break
                }
                return (ledger, false)
            }
        }
        return (ledger, true)
    }

    /// Renews an account's credential: one request per account at a time (a second caller waits for the first), and
    /// the rotated credential is saved before anything else happens, unless the account was removed meanwhile.
    private func renew(_ id: String, _ login: Login) async throws(FetchFailure) -> Credential {
        if let running = refreshing[id] {
            do { return try await running.value } catch { throw error as? FetchFailure ?? .network }
        }
        guard let refresh = login.auth.refresh else { throw .signInRequired }
        let vault = vault(login.secretItem), http = http
        // Registered before anything is awaited, so a second caller always finds it: a refresh token is spent on use.
        let task = Task { () throws -> Credential in
            guard let credential = try await vault.value(id) else { throw FetchFailure.signInRequired }
            return try await refresh(credential, http)
        }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        Log.auth.info("\(id, privacy: .private) refreshing its token")
        do {
            let fresh = try await task.value
            if account(id) != nil { vault.set(id, fresh) }
            Log.auth.info("\(id, privacy: .private) token refreshed, valid for \(Int((fresh.expiresAt ?? .now).timeIntervalSinceNow / 60)) min")
            return fresh
        } catch {
            let failure = error as? FetchFailure ?? .network
            Log.auth.info("\(id, privacy: .private) token refresh failed: \(String(describing: failure), privacy: .public)")
            if failure == .signInRequired, account(id) != nil { vault.set(id, nil) }
            throw failure
        }
    }

    /// Renews the name (and email) shown, once a day: an account or organisation may have been renamed.
    private func renewProfile(_ id: String, _ login: Login) async {
        guard let credential = (try? await vault(login.secretItem).value(id)) ?? nil,
              let identity = try? await login.identify(credential, http), login.accountID(identity.id) == id else { return }
        update(id) { $0.name = identity.name; $0.email = identity.email; $0.profileFetchedAt = Date() }
    }

    // MARK: Schedule

    /// Sets one timer for the next account that is due: its last attempt plus the interval, or later while it backs
    /// off. The tolerance lets macOS coalesce the wake-up with others.
    private func schedule(after minimum: TimeInterval = 0) {
        timer?.invalidate()
        timer = nil
        guard persistent, !paused, online else {
            if persistent { Log.schedule.debug("not scheduling: \(self.paused ? "asleep" : "offline", privacy: .public)") }
            return
        }
        let now = Date()
        let due = accounts.filter { !$0.needsSignIn }.map { due($0, now: now) }
        guard let next = due.min() else {
            Log.schedule.debug("nothing to schedule")
            return
        }
        let delay = max(next.timeIntervalSince(now), minimum, 0.5)
        Log.schedule.debug("next refresh in \(Int(delay.rounded())) s, at \(now.addingTimeInterval(delay).formatted(date: .omitted, time: .standard), privacy: .public)")
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        // Right after a reset the account shows nothing for that limit until it is read: keep that gap short.
        let atReset = accounts.contains { account in
            (account.snapshot?.resets ?? []).contains { abs($0.addingTimeInterval(Due.jitter(account: account.id)).timeIntervalSince(next)) < 0.01 }
        }
        timer.tolerance = atReset ? 1 : min(max(interval * 0.1, 1), 30)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// When `account` is next due: after its interval, or just after a limit it shows resets, never during a backoff.
    private func due(_ account: Account, now: Date) -> Date {
        let health = health[account.id] ?? Health()
        return Due.next(lastAttempt: health.lastAttempt, notBefore: health.notBefore, interval: interval(for: account),
                        resets: account.snapshot?.resets ?? [], jitter: Due.jitter(account: account.id), now: now)
    }

    private func timerFired() {
        let now = Date()
        for account in accounts where !account.needsSignIn && due(account, now: now).timeIntervalSince(now) <= 1 {
            refresh(account.id)
        }
        if !draining { schedule() }
    }

    // MARK: Sleep, wake, clock and network

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        // The clock jumped (manually, or by network time after a wake): timers and "due" times are recomputed.
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 1); self?.touch() }
        }
        // Reset times are shown in the current time zone and locale.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.touch() }
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.network(satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func pause() {
        Log.schedule.info("pausing for sleep")
        paused = true
        timer?.invalidate()
        timer = nil
    }

    /// After a wake, refreshes what is due once the network had a moment to come back.
    private func resume() {
        guard paused else { return }
        Log.schedule.info("resuming after wake")
        paused = false
        schedule(after: 3)
        drain()
    }

    private func network(_ satisfied: Bool) {
        let regained = satisfied && !online
        if satisfied != online { Log.schedule.info("network \(satisfied ? "back" : "lost", privacy: .public)") }
        online = satisfied
        guard regained else {
            if !satisfied { timer?.invalidate(); timer = nil }
            return
        }
        for id in health.keys where [.offline, .network].contains(health[id]?.error) {
            health[id]?.notBefore = .distantPast
            health[id]?.lastAttempt = nil                              // due now
        }
        schedule(after: 2)
        drain()
    }

    // MARK: Notifications

    private func alert(_ id: String, _ snapshot: Snapshot, _ policy: AlertPolicy) {
        guard Preferences.notifications, let account = account(id) else { return }
        var updated = fired
        let due = Alerts.evaluate(account: id, snapshot: snapshot, policy: policy, fired: &updated)
        updated = Alerts.prune(updated)
        if updated != fired {                                           // state.json was just saved with the snapshot
            fired = updated
            save()
        }
        for due in due {
            let (title, body) = Alerts.text(due, name: account.name, email: account.email)
            notifier.post(title: title, body: body, account: id, meter: due.meter)
        }
    }

    // MARK: Sample data

    #if DEBUG
    func loadSample(_ accounts: [Account]) {
        self.accounts = SavedState.grouped(accounts)
        for account in accounts { health[account.id] = Health() }
        let subscriptions = accounts.filter { $0.provider == Claude.id && $0.login == Claude.account.id }
        if let last = subscriptions.last?.id, subscriptions.count > 1 { health[last]?.error = .rateLimited(nil) }
        changed()
    }
    #endif
}
