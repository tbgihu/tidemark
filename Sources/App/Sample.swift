#if DEBUG
import Foundation

/// Sample accounts for looking at Tidemark without signing in (`--sample 0…5`, debug builds only): up to three
/// Claude accounts; with 4 (the default) a Console organisation too; with 5 also two accounts of a fake second
/// provider (`Example`); with 6 also a ChatGPT, a Copilot and an OpenCode account. `--showcase` keeps only real
/// providers' accounts with something to show, for pictures. Their history and costs are generated into a temporary folder; nothing touches the
/// Keychain, the network or Tidemark's real files.
enum Sample {
    static var requested: Int? {
        guard let index = CommandLine.arguments.firstIndex(of: "--sample") else { return nil }
        let next = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Int.init) ?? 4
        return min(max(next, 0), 6)
    }

    static let organization = Identity(id: "00000000-0000-4000-8000-000000000001", name: "Acme Research")

    static func claude(_ id: String, _ name: String, _ email: String, showPercent: Bool = false, expanded: Bool = false,
                       _ usage: Usage) -> Account {
        Account(id: id, provider: Claude.id, login: Claude.account.id, name: name, email: email, showPercent: showPercent,
                historyExpanded: expanded, snapshot: usage.snapshot)
    }

    static func accounts(_ count: Int) -> [Account] {
        let now = Date()
        let all = [
            claude("sample-1", "Jane Doe", "jane@example.com", showPercent: true, expanded: true,
                   Usage(limits: [.session: Limit(percent: 48, resetsAt: now + 2 * 3600 + 13 * 60),
                                  .weekly: Limit(percent: 64, resetsAt: now + 4 * 86400 + 3600),
                                  .fable: Limit(percent: 75, resetsAt: now + 4 * 86400 + 3600, reportedSeverity: "warning")],
                         extra: ExtraUsage(spentMinor: 1240, limitMinor: 5000, currency: "EUR", decimals: 2),
                         fetchedAt: now - 40)),
            claude("sample-2", "Jane Doe (Work)", "jane.doe@example.org",
                   Usage(limits: [.session: Limit(percent: 97, resetsAt: now + 4 * 3600),
                                  .weekly: Limit(percent: 91, resetsAt: now + 86400 * 2)],
                         fetchedAt: now - 200)),
            claude("sample-3", "Sam Lee", "sam@example.org", showPercent: true,
                   Usage(limits: [.weekly: Limit(percent: 3, resetsAt: now + 6 * 86400)], fetchedAt: now - 300)),
        ]
        var accounts = Array(all.prefix(count))
        for account in accounts { writeHistory(account.id, now: now) }
        if count > 3 {
            let id = Claude.console.accountID(organization.id)
            let ledger = writeCosts(id, now: now)
            accounts.append(Account(id: id, provider: Claude.id, login: Claude.console.id, name: organization.name,
                                    historyExpanded: true,
                                    snapshot: ledger.figures(at: now).map { Snapshot(money: $0, fetchedAt: now - 90) }))
        }
        if count > 4 {
            accounts += Example.accounts(now: now)
            writeHistory("example-key-1", now: now)
        }
        if count > 5 {
            func meter(_ id: String, _ title: String, _ label: String, _ percent: Double, in seconds: TimeInterval,
                       short: Bool = false) -> Meter {
                Meter(id: id, title: title, label: label, percent: percent, resetsAt: now + seconds, short: short)
            }
            accounts += [
                Account(id: "chatgpt-sample", provider: OpenAI.id, login: OpenAI.account.id, name: "Jane Doe",
                        email: "jane@example.com", snapshot: Snapshot(
                            meters: [meter("session", "5-hour limit", "5h", 22, in: 3 * 3600, short: true),
                                     meter("weekly", "Weekly limit", "w", 37, in: 3 * 86400)],
                            plan: "Go", fetchedAt: now - 30)),
                Account(id: "copilot-sample", provider: Copilot.id, login: Copilot.account.id, name: "janedoe",
                        snapshot: Snapshot(meters: [meter("premium", "Premium requests", "pr", 58, in: 12 * 86400)],
                                           plan: "Pro", fetchedAt: now - 50)),
                Account(id: "opencode-sample", provider: OpenCode.id, login: OpenCode.apiKey.id, name: "Personal",
                        snapshot: Snapshot(money: OpenCodeUsage.money(balance: Decimal(string: "18.42"),
                                                                      spend: Decimal(string: "6.58"), now: now, headline: true),
                                           fetchedAt: now - 70)),
            ]
        }
        // For pictures of Tidemark: only real providers, each with something to show.
        if CommandLine.arguments.contains("--showcase") {
            accounts.removeAll { $0.provider == Example.id || $0.snapshot?.isEmpty == true }
        }
        if CommandLine.arguments.contains("--collapsed") { for index in accounts.indices { accounts[index].historyExpanded = false } }
        return accounts
    }

    /// The same numbers on every run for the same account, so snapshots are reproducible (SplitMix64).
    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(_ id: String) { state = id.utf8.reduce(0x9E3779B97F4A7C15) { ($0 ^ UInt64($1)) &* 0x100000001B3 } }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A year of daily costs, in cents with fractions as the API reports them: busier on weekdays, growing.
    private static func writeCosts(_ id: String, now: Date) -> CostLedger {
        var generator = Seeded(id)
        let tomorrow = CostCalendar.add(days: 1, to: CostCalendar.day(now))
        let start = CostCalendar.add(days: -CostPlan.maximumDays, to: tomorrow)
        var days: [Date: Decimal] = [:]
        var day = start
        while day < tomorrow {
            let weekday = CostCalendar.utc.component(.weekday, from: day)
            let growth = 1 + Double(CostCalendar.days(from: start, to: day)) / 200
            let base = (weekday == 1 || weekday == 7 ? 300 : 1400) * growth
            let cents = (base * (0.6 + Double(generator.next() % 80) / 100) * 1000).rounded() / 1000
            if generator.next() % 30 != 0 { days[day] = Decimal(string: String(cents)) ?? 0 }   // a few days without costs
            day = CostCalendar.add(days: 1, to: day)
        }
        var ledger = CostLedger()
        ledger.merge(days, covering: start..<tomorrow)
        try? FileManager.default.createDirectory(at: Paths.costs, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ledger).write(to: Paths.costs(id))
        return ledger
    }

    /// Five weeks of plausible usage: a session window that climbs and resets every five hours during the day,
    /// weekly limits that climb and reset each week, and a gap of two days when "Tidemark wasn't running".
    private static func writeHistory(_ id: String, now: Date) {
        let url = Paths.history(id)
        try? FileManager.default.removeItem(at: url)
        var samples: [History.Sample] = []
        var generator = Seeded(id)
        let start = now.addingTimeInterval(-35 * 86400)
        var time = start
        var session = 0.0, weekly = 0.0, fable = 0.0
        let seed = Double(generator.next() & 7) / 7
        while time < now {
            let hours = time.timeIntervalSince(start) / 3600
            if hours.truncatingRemainder(dividingBy: 168) < 0.1 { weekly = 0; fable = 0 }
            if hours.truncatingRemainder(dividingBy: 5) < 0.1 { session = 0 }
            let hour = Calendar.current.component(.hour, from: time)
            if (9...22).contains(hour) {
                let burst = Double(generator.next() % 100) / 100
                session = min(session + burst * (1.2 + seed), 100)
                weekly = min(weekly + burst * 0.045, 100)
                fable = min(fable + burst * 0.06, 100)
            }
            let gap = time > start + 12 * 86400 && time < start + 14 * 86400
            if !gap {
                samples.append(History.Sample(time: time, [UInt8(session), UInt8(weekly), id == "sample-3" ? nil : UInt8(fable)]))
            }
            time += 300
        }
        try? FileManager.default.createDirectory(at: Paths.history, withIntermediateDirectories: true)
        try? History.encode(History.compact(samples, now: now)).write(to: url)
    }
}
#endif

#if DEBUG
import AppKit

/// `--snapshot <dir>` (with `--sample`): writes the menu bar items (light and dark, side by side as the menu bar
/// would show them, in the mode Settings has), the panel at each provider's tab and Settings as PNGs, then quits. For checking layout without
/// a screen capture; Liquid Glass is drawn by the window server, so the panel shows here on a plain background.
@MainActor
enum Screenshots {
    static func run(to dir: URL, model: Model, status: StatusBar, panel: PanelController, settings: SettingsController) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let height = status.all.first?.button?.bounds.height ?? NSStatusBar.system.thickness
            // As with the panel open at the first provider.
            status.mark(model.accounts.providers.first)
            let contents = status.all.compactMap(\.content)
            status.mark(nil)
            for (name, dark) in [("menubar-light", false), ("menubar-dark", true)] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let images = contents.map { MenuBarImage.image($0, height: height, appearance: appearance) }
                write(render(images), to: dir.appending(path: "\(name).png"))
            }
            // The panel and Settings in the app's appearance: run once more with `-AppleInterfaceStyle Dark` for
            // dark ones (SwiftUI's styles follow the system's, not a window's).
            let suffix = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            for provider in model.accounts.providers {
                guard let (item, target) = status.anchor(for: provider) else { continue }
                panel.open(below: item.anchor, provider: provider, at: target.x)
                try? await Task.sleep(for: .seconds(2))
                // The panel's whole content, past the screen's height too.
                if let root = panel.window?.contentView, let view = Selftest.views(NSScrollView.self, in: root).first?.documentView {
                    let name = provider == model.accounts.providers.first ? "panel-\(suffix)" : "panel-\(provider)-\(suffix)"
                    write(capture(view), to: dir.appending(path: "\(name).png"))
                }
                panel.dismiss()
            }
            settings.show()
            try? await Task.sleep(for: .seconds(1))
            if let view = settings.settingsWindow?.contentView {
                write(capture(view), to: dir.appending(path: "settings-\(suffix).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// The items' images at 4x on a transparent background, 8 points apart as in the menu bar.
    private static func render(_ images: [NSImage]) -> NSBitmapImageRep {
        let scale: CGFloat = 4, gap: CGFloat = 8
        let width = images.map(\.size.width).reduce(0, +) + gap * CGFloat(max(images.count - 1, 0))
        let height = images.map(\.size.height).max() ?? 22
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(Int(width * scale), 1),
                                   pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: max(width, 1), height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        var x: CGFloat = 0
        for image in images {
            image.draw(in: NSRect(x: x, y: 0, width: image.size.width, height: image.size.height))
            x += image.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func capture(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

