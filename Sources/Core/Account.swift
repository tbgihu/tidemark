import Foundation

/// An account Tidemark shows, with what was last known about it. Saved (without credentials) in state.json, so the
/// menu bar has values the moment Tidemark launches.
struct Account: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// Its `Provider.id` and `Login.id`.
    var provider: String
    var login: String
    var name: String
    /// Empty when the provider reports none.
    var email: String
    /// What its menu bar item shows: labels ("5h"), bars (an amount, for an account without meters) and percentages.
    /// With neither bars nor percentages, it has no item; the panel still shows it.
    var showLabels = true
    var showBars = true
    var showPercent = false
    var historyExpanded = false
    /// Signed out, or the credential was rejected: only the user can fix it.
    var needsSignIn = false
    var snapshot: Snapshot?
    var profileFetchedAt: Date?

    init(id: String, provider: String, login: String, name: String, email: String = "", showLabels: Bool = true,
         showBars: Bool = true,
         showPercent: Bool = false, historyExpanded: Bool = false, needsSignIn: Bool = false,
         snapshot: Snapshot? = nil, profileFetchedAt: Date? = nil) {
        self.id = id
        self.provider = provider
        self.login = login
        self.name = name
        self.email = email
        self.showLabels = showLabels
        self.showBars = showBars
        self.showPercent = showPercent
        self.historyExpanded = historyExpanded
        self.needsSignIn = needsSignIn
        self.snapshot = snapshot
        self.profileFetchedAt = profileFetchedAt
    }

    private enum Keys: String, CodingKey {
        case id, provider, login, name, email, showLabels, showBars, showPercent, hiddenInMenuBar, historyExpanded, needsSignIn, snapshot,
             profileFetchedAt
    }

    /// Only the id is required: a field added or changed in a later version, or a snapshot that no longer decodes,
    /// falls back to its default instead of losing the account. State written before providers existed holds Claude
    /// accounts only, in Claude's own shape, and is read as such (`ClaudeState`).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        showPercent = (try? c.decodeIfPresent(Bool.self, forKey: .showPercent)) ?? false
        showLabels = (try? c.decodeIfPresent(Bool.self, forKey: .showLabels)) ?? true
        if let bars = try? c.decodeIfPresent(Bool.self, forKey: .showBars) {
            showBars = bars
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .hiddenInMenuBar)) == true {
            // Saved before the two checkboxes: hidden is neither.
            showBars = false
            showPercent = false
        }
        historyExpanded = (try? c.decodeIfPresent(Bool.self, forKey: .historyExpanded)) ?? false
        needsSignIn = (try? c.decodeIfPresent(Bool.self, forKey: .needsSignIn)) ?? false
        profileFetchedAt = try? c.decodeIfPresent(Date.self, forKey: .profileFetchedAt)
        if let provider = try? c.decodeIfPresent(String.self, forKey: .provider) {
            self.provider = provider
            login = (try? c.decodeIfPresent(String.self, forKey: .login)) ?? ""
            snapshot = try? c.decodeIfPresent(Snapshot.self, forKey: .snapshot)
        } else {
            let legacy = try ClaudeState(from: decoder)
            provider = Claude.id
            login = legacy.login
            snapshot = legacy.snapshot
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(login, forKey: .login)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encode(showLabels, forKey: .showLabels)
        try c.encode(showBars, forKey: .showBars)
        try c.encode(showPercent, forKey: .showPercent)
        try c.encode(historyExpanded, forKey: .historyExpanded)
        try c.encode(needsSignIn, forKey: .needsSignIn)
        try c.encodeIfPresent(snapshot, forKey: .snapshot)
        try c.encodeIfPresent(profileFetchedAt, forKey: .profileFetchedAt)
    }
}

extension Account {
    /// Whether it has a menu bar item: it shows bars, or percentages of meters it reports.
    var inMenuBar: Bool { showBars || showPercent && (Registry.resolve(self)?.login.reportsMeters ?? true) }
}

extension Array where Element == Account {
    /// The accounts with a menu bar item, in order: every one showing bars or percentages.
    var inMenuBar: [Account] { filter(\.inMenuBar) }

    /// The providers with at least one account, in their fixed order.
    var providers: [String] {
        var seen = Set<String>()
        return map(\.provider).filter { seen.insert($0).inserted }.sorted { Registry.order(of: $0) < Registry.order(of: $1) }
    }

    /// One provider's accounts, in their configured order.
    func of(_ provider: String) -> [Account] { filter { $0.provider == provider } }
}

/// What Tidemark keeps between launches, besides credentials and history.
struct SavedState: Codable, Equatable, Sendable {
    var accounts: [Account] = []
    var fired: Set<String> = []

    init(accounts: [Account] = [], fired: Set<String> = []) {
        self.accounts = accounts
        self.fired = fired
    }

    /// Accounts that don't decode are skipped, and a duplicated id keeps its first entry. Accounts are grouped by
    /// provider in the fixed order, keeping their order within each.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<String>()
        let accounts = ((try? c.decodeIfPresent([Lenient<Account>].self, forKey: .accounts)) ?? [])
            .compactMap(\.value).filter { seen.insert($0.id).inserted }
        self.accounts = Self.grouped(accounts)
        fired = (try? c.decodeIfPresent(Set<String>.self, forKey: .fired)) ?? []
    }

    /// Stable: within a provider the order is kept.
    static func grouped(_ accounts: [Account]) -> [Account] {
        accounts.enumerated().sorted {
            (Registry.order(of: $0.element.provider), $0.offset) < (Registry.order(of: $1.element.provider), $1.offset)
        }.map(\.element)
    }

    /// Reads state.json. Nil when the file exists but isn't Tidemark state at all (so the caller can keep it aside
    /// rather than overwrite it); empty when there is no file.
    static func load(_ data: Data?) -> SavedState? {
        guard let data else { return SavedState() }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }
}
