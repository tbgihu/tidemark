import Foundation

/// Every provider Tidemark can read, in their fixed order. Adding one is its folder under `Sources/Providers` and one
/// line in `builtIn` (docs/providers.md).
enum Registry {
    /// The order of every list (tabs, Settings, the Add menu), by popularity. Ids are reserved here before their
    /// provider exists; only registered providers ever appear.
    static let order = [
        "claude", "openai", "copilot", "cursor", "antigravity", "xai", "openrouter", "warp", "deepseek", "moonshot", "zai",
        "minimax", "ollama", "opencode", "elevenlabs",
    ]

    /// The providers this build implements.
    static let builtIn: [Provider] = [
        Claude.provider,
        OpenAI.provider,
        Copilot.provider,
        Cursor.provider,
        Antigravity.provider,
        XAI.provider,
        OpenRouter.provider,
        Warp.provider,
        DeepSeek.provider,
        Moonshot.provider,
        Zai.provider,
        MiniMax.provider,
        Ollama.provider,
        OpenCode.provider,
        ElevenLabs.provider,
    ]

    /// Every provider shown, in order. Debug builds add a fake second provider in sample mode.
    static let providers: [Provider] = {
        var all = builtIn
        #if DEBUG
        if CommandLine.arguments.contains("--sample") { all.append(Example.provider) }
        #endif
        return all.sorted { $0.order < $1.order }
    }()

    private static let byID = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func provider(_ id: String) -> Provider? { byID[id] }

    /// An account's provider and login, when this build knows them.
    static func resolve(_ account: Account) -> (provider: Provider, login: Login)? {
        guard let provider = byID[account.provider], let login = provider.login(account.login) else { return nil }
        return (provider, login)
    }

    /// A provider's place in every list; after every reserved one when it isn't reserved.
    static func order(of id: String) -> Int { order.firstIndex(of: id) ?? order.count }

    /// Every Keychain item a login of this build keeps credentials in.
    static var secretItems: [String] {
        var seen = Set<String>()
        return providers.flatMap(\.logins).map(\.secretItem).filter { seen.insert($0).inserted }
    }
}
