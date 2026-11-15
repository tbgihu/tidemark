import Foundation

/// An opaque sRGB colour, each component 0–1.
struct BrandColor: Equatable, Hashable, Sendable {
    let red: Double, green: Double, blue: Double

    /// From `0xRRGGBB`.
    init(hex: UInt32) {
        red = Double(hex >> 16 & 0xFF) / 255
        green = Double(hex >> 8 & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
}

/// A service Tidemark reads accounts from: its name, colour, place in every list, how often it may be asked, and the
/// ways to sign in to it. Everything specific to a provider lives in its own folder under `Sources/Providers`; the
/// rest of Tidemark sees only this descriptor (see docs/providers.md).
struct Provider: Sendable, Identifiable {
    /// Stable for ever: saved in state.json with every account.
    let id: String
    /// Tabs, Settings sections and the Add menu: "Claude".
    let name: String
    /// Status lines name who answered: "Rate-limited by Anthropic".
    let company: String
    /// The hairline down the left of each of its accounts in the menu bar, once accounts of more than one provider are
    /// configured, and its logo's colour. Readable on light and dark menu bars, and distinct from every other's.
    let brandColor: BrandColor
    /// Its fixed place in every list: its index in `Registry.order`.
    let order: Int
    /// Polling more often than this tends to be rate-limited: Settings says so below it.
    let recommendedMinimumInterval: TimeInterval
    /// The ways to add an account, in the order the Add menu lists them.
    let logins: [Login]

    func login(_ id: String) -> Login? { logins.first { $0.id == id } }
}

/// One way to sign in to a provider, and what such an account shows: "Claude Account" (OAuth) or "Console
/// Organisation" (an admin key) for Claude.
struct Login: Sendable, Identifiable {
    let id: String
    /// The Add menu's item: "Claude Account".
    let title: String
    /// Under the title in the Add menu: "Sign in to see its usage limits".
    let subtitle: String
    /// An SF Symbol for the Add menu.
    let symbol: String
    /// Shown in place of an email for accounts without one: "API organisation".
    var kindLabel: String? = nil
    let auth: Auth
    /// Never read more often than this, whatever the setting.
    var minimumInterval: TimeInterval = 0
    /// The Keychain item (`SecretStore` account) holding this login's credentials, one JSON object keyed by account.
    let secretItem: String
    /// Whether accounts report percent meters (and so offer progress bars and percentages in the menu bar, where an
    /// account without them offers its amount).
    var reportsMeters = true
    /// What History charts: up to three meters, a cost per day, or nothing.
    var history: HistoryKind = .none
    /// When percent meters notify.
    var alerts = AlertPolicy.standard
    var texts = LoginTexts()
    /// The account id for the identity the provider reports: unique across every provider and login.
    var accountID: @Sendable (_ identity: String) -> String = { $0 }
    /// Who a credential belongs to: checks it, at sign-in and once a day.
    let identify: @Sendable (_ credential: Credential, _ http: HTTP) async throws(FetchFailure) -> Identity
    /// One refresh: the usage snapshot. Runs off the main thread.
    let fetch: @Sendable (_ context: FetchContext) async throws(FetchFailure) -> Snapshot
    /// Daily costs over a range of UTC days, for the History chart of logins whose `history` is `.dailyCosts`.
    var dailyCosts: (@Sendable (_ credential: Credential, _ days: Range<Date>, _ http: HTTP, _ now: Date)
        async throws(FetchFailure) -> [Date: Decimal])? = nil
}

/// What History shows for an account.
enum HistoryKind: Sendable {
    case none
    /// Up to three meters, by id, recorded on every refresh in the order given.
    case meters([ChartedMeter])
    /// Cents of USD per UTC day, read with `Login.dailyCosts` and cached.
    case dailyCosts

    var charted: [ChartedMeter] { if case .meters(let meters) = self { meters } else { [] } }
}

/// A meter History records and draws: its id in the snapshot, the chart's label and the spoken title.
struct ChartedMeter: Sendable, Equatable {
    let id: String
    let label: String
    let title: String
}

/// The texts that depend on how an account signs in.
struct LoginTexts: Sendable {
    /// The panel's status once only the user can help.
    var signedOut = "Signed out. Sign in again to see usage."
    /// Settings' status for it.
    var signedOutShort = "Signed out"
    /// The button that helps.
    var reauthenticate = "Sign In Again…"
    /// Its VoiceOver label, with the account's name.
    var reauthenticateSpoken = "Sign in again to"
    /// What a 403 means.
    var forbidden = "This account can’t read its usage."
    /// What removing an account does, with its name and email: the alert's text.
    var removal: @Sendable (_ name: String, _ email: String) -> String = { _, email in
        "Tidemark signs out of \(email) on this Mac and deletes its usage history. The account itself isn’t affected."
    }
}

/// How often an account of a login may be read.
struct Pace: Equatable, Sendable {
    /// Polling more often than this tends to be rate-limited.
    let recommendedMinimum: TimeInterval
    /// Never read more often than this, whatever the setting.
    let minimum: TimeInterval

    /// How often an account is read with the interval set to `interval`.
    func effective(_ interval: TimeInterval) -> TimeInterval { max(interval, minimum) }

    /// Whether reading at `interval` is likely to be rate-limited.
    func mayBeRateLimited(at interval: TimeInterval) -> Bool { effective(interval) < recommendedMinimum }

    /// Whether `interval` is too short for any of `paces`, the configured accounts'; with none, for `standard`.
    static func mayBeRateLimited(at interval: TimeInterval, by paces: [Pace]) -> Bool {
        (paces.isEmpty ? [standard] : paces).contains { $0.mayBeRateLimited(at: interval) }
    }

    /// What Settings judges the interval against while there are no accounts.
    static let standard = Pace(recommendedMinimum: 300, minimum: 0)
}

extension Provider {
    func pace(_ login: Login) -> Pace {
        Pace(recommendedMinimum: recommendedMinimumInterval, minimum: login.minimumInterval)
    }
}

/// Who an account is, as its provider reports it.
struct Identity: Codable, Equatable, Sendable {
    /// The provider's own id for it, stable across sign-ins.
    let id: String
    var name: String
    var email: String

    init(id: String, name: String, email: String = "") {
        self.id = id
        self.name = name
        self.email = email
    }
}

/// What a refresh gets to work with.
struct FetchContext: Sendable {
    let account: String
    let credential: Credential
    let http: HTTP
    let now: Date
    /// The daily-cost cache, for logins that read costs.
    let costs: any CostCache
}

/// Each account's daily costs, cached between refreshes and launches.
protocol CostCache: Sendable {
    func ledger(_ account: String) async -> CostLedger
    /// Takes what a request read for `range`, forgets what is older than the cache keeps, and saves.
    func merge(_ account: String, _ days: [Date: Decimal], covering range: Range<Date>, now: Date) async -> CostLedger
}
