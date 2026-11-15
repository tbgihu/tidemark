#if DEBUG
import AppKit
import WebKit

/// `--selftest` (with `--sample`): drives the status items, the panel and Settings the way a user would (slider,
/// checkboxes, drag to reorder, VoiceOver's Move Down, tabs, the Add menu and each kind of sign-in sheet) and checks
/// the model and menu bar follow, with one provider and then with two. Prints PASS/FAIL lines, then quits.
@MainActor
enum Selftest {
    typealias Check = (Bool, String) -> Void

    static func run(model: Model, status: StatusBar, panel: PanelController, settings: SettingsController) {
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ ok: Bool, _ what: String) {
                if !ok { failures += 1 }
                FileHandle.standardError.write(Data("\(ok ? "PASS" : "FAIL") \(what)\n".utf8))
            }
            // It drives accounts, reordering two of them.
            guard model.accounts.filter({ $0.provider == Claude.id }).count >= 2 else {
                check(false, "the self-test needs two Claude sample accounts or more (--sample 2 to 6)")
                exit(1)
            }
            SettingsView.presentsMenus = false
            // Most checks drive an item per account; `shared` checks the default, one item for all.
            model.setSeparateItems(true)
            // One provider configured until `providers` adds a second.
            model.loadSample(model.accounts.filter { $0.provider == Claude.id })
            await items(model: model, status: status, check: check)

            // The panel's gear closes the panel and opens Settings.
            open(panel, status)
            try? await Task.sleep(for: .milliseconds(500))
            let gear = panel.window.flatMap { views(NSButton.self, in: $0.contentView!).first { $0.accessibilityLabel() == "Settings" } }
            check(gear != nil, "panel has a gear")
            check(panel.window.map { views(ProviderTabs.self, in: $0.contentView!).allSatisfy(\.isHiddenOrHasHiddenAncestor) } == true,
                  "with one provider, the panel has no tabs")
            gear?.performClick(nil)
            try? await Task.sleep(for: .milliseconds(500))
            check(!panel.isOpen && settings.settingsWindow?.isVisible == true, "gear closes the panel and opens Settings")
            settings.show()
            try? await Task.sleep(for: .milliseconds(500))
            guard let root = settings.settingsWindow?.contentView else { check(false, "settings window"); exit(1) }

            // Slider: every tick maps to a step; below the providers' safe interval, Settings says so.
            let slider = views(NSSlider.self, in: root).first!
            check(slider.numberOfTickMarks == 9 && slider.allowsTickMarkValuesOnly, "slider has 9 discrete ticks")
            @MainActor func warned() -> Bool {
                views(NSTextField.self, in: root).contains {
                    $0.stringValue == "May be rate-limited by the provider." && !$0.isHiddenOrHasHiddenAncestor
                }
            }
            var steps: [TimeInterval] = [], warnings: [Bool] = []
            for tick in 0..<9 {
                slider.doubleValue = Double(tick)
                _ = slider.target?.perform(slider.action, with: slider)
                steps.append(model.interval)
                warnings.append(warned())
            }
            check(steps == Interval.steps, "slider steps 15 s … 60 min")
            check(warnings == Interval.steps.map { $0 < 300 }, "the rate-limit note shows below 5 min only")
            slider.doubleValue = Double(Interval.index(of: Interval.defaultValue))
            _ = slider.target?.perform(slider.action, with: slider)
            check(model.interval == 300 && !warned(), "back to the 5-minute default")

            // A Percentage checkbox, on or off, toggles its account's percentages, and back.
            if let box = views(NSButton.self, in: root).first(where: { $0.title == "Percentage" && !$0.isHiddenOrHasHiddenAncestor }) {
                @MainActor func percents() -> [Bool] { blocks(model).map(\.showPercent) }
                let before = percents()
                box.performClick(nil)
                check(before != percents() && percents().filter { $0 }.count == before.filter { $0 }.count + (box.state == .on ? 1 : -1),
                      "a Percentage checkbox toggles its account's percentages")
                box.performClick(nil)
                check(percents() == before, "and back")
            }

            // Drag the first row below the second, with real mouse events.
            let list = views(AccountList.self, in: root).first!
            let order = model.accounts.map(\.id)
            drag(list, from: 20, to: 20 + AccountList.rowHeight * 1.2)
            check(model.accounts.map(\.id) == [order[1], order[0]] + order.dropFirst(2), "drag moves the first account down one")
            try? await Task.sleep(for: .milliseconds(400))

            // VoiceOver's Move Down / Move Up on a row.
            let rows = list.subviews.sorted { $0.frame.minY < $1.frame.minY }
            _ = rows[0].accessibilityCustomActions()?.first { $0.name == "Move Down" }?.handler?()
            check(model.accounts.map(\.id) == order, "Move Down restores the order")
            check(status.all.compactMap(\.account) == model.accounts.inMenuBar.map(\.id), "the status items follow the order")
            check(blocks(model).allSatisfy { $0.brand == nil }, "with one provider, no account is branded")

            await hiding(model: model, status: status, panel: panel, root: root, check: check)
            await limitVisibility(model: model, status: status, panel: panel, check: check)
            await freshness(model: model, status: status, panel: panel, check: check)
            if let org = model.accounts.first(where: { $0.login == Claude.console.id }) {
                await organization(org, model: model, status: status, panel: panel, settings: settings, root: root, check: check)
            }
            await providers(model: model, status: status, panel: panel, settings: settings, check: check)

            FileHandle.standardError.write(Data((failures == 0 ? "ALL PASSED\n" : "\(failures) FAILED\n").utf8))
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Helpers

    private static func blocks(_ model: Model) -> [MenuBarContent.Block] {
        let branded = model.accounts.providers.count > 1
        return model.accounts.inMenuBar.flatMap { StatusBar.content(model, $0, branded: branded).blocks }
    }

    private static func block(_ model: Model, _ id: String) -> MenuBarContent.Block {
        StatusBar.content(model, model.account(id)!, branded: model.accounts.providers.count > 1).blocks[0]
    }

    private static func summary(_ model: Model, _ id: String) -> String { StatusBar.summary(model, model.account(id)!) }

    /// The default: one item for every account, by provider in their fixed order, then as set in Settings. A press
    /// lands on an account and opens the panel at its provider, under it; highlights follow per account.
    private static func shared(model: Model, status: StatusBar, panel: PanelController, settings: SettingsController,
                               claude: [String], examples: [String], check: Check) async {
        let toggle = settings.settingsWindow?.contentView.flatMap { root in
            views(NSSwitch.self, in: root).first { $0.accessibilityLabel() == "Separate menu bar items" }
        }
        check(toggle?.state == .on, "Settings shows separate items, as the self-test set them")
        if let toggle { toggle.state = .off; _ = toggle.target?.perform(toggle.action, with: toggle) } else { model.setSeparateItems(false) }
        try? await Task.sleep(for: .milliseconds(300))
        check(!model.separateItems, "the switch turns separate items off")
        let ordered = model.accounts.inMenuBar.enumerated().sorted {
            (Registry.order(of: $0.element.provider), $0.offset) < (Registry.order(of: $1.element.provider), $1.offset)
        }.map(\.element.id)
        check(status.all.count == 1 && status.all[0].account == nil && status.all[0].accounts == ordered,
              "one item holds every account, by provider, then in order")
        check(claude.allSatisfy { status.item(for: $0) === status.all.first }, "each account is found in it")
        let xs = [Claude.id, Example.id].compactMap { status.all.first?.target(provider: $0)?.x }
        check(xs.count == 2 && xs[0] < xs[1], "each provider's accounts sit at their own place in it")

        status.press(examples[1])
        try? await Task.sleep(for: .milliseconds(300))
        check(panel.isOpen && panel.provider == Example.id && examples.allSatisfy { status.isHighlighted($0) }
              && !claude.contains { status.isHighlighted($0) }, "a press on an account opens its provider, its accounts highlighted")
        status.press(claude[1])
        try? await Task.sleep(for: .milliseconds(300))
        check(panel.provider == Claude.id && claude.allSatisfy { status.isHighlighted($0) }, "a press on another provider's account moves there")
        status.press(claude[0])
        try? await Task.sleep(for: .milliseconds(300))
        check(!panel.isOpen && !claude.contains { status.isHighlighted($0) }, "a press on the shown provider's account closes it")

        model.setSeparateItems(true)
        try? await Task.sleep(for: .milliseconds(200))
        check(status.all.count == model.accounts.inMenuBar.count && status.all.allSatisfy { $0.account != nil },
              "separate again: an item per account")
    }

    private static func open(_ panel: PanelController, _ status: StatusBar, provider: String? = nil) {
        let anchor = status.anchor(for: provider)
        panel.open(below: anchor?.item.anchor, provider: provider ?? anchor?.target.provider, at: anchor?.target.x)
    }

    private static func drag(_ list: AccountList, from start: CGFloat, to end: CGFloat) {
        func event(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
            let point = list.convert(NSPoint(x: 120, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: list.window!.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        list.mouseDown(with: event(.leftMouseDown, start))
        list.mouseDragged(with: event(.leftMouseDragged, start + 1))          // under the 3 pt threshold: still a click
        for y in stride(from: start + 4, through: end, by: 6) { list.mouseDragged(with: event(.leftMouseDragged, y)) }
        list.mouseUp(with: event(.leftMouseUp, end))
    }

    private static func panelTexts(_ panel: PanelController, in section: String? = nil) -> [String] {
        guard let root = panel.window?.contentView else { return [] }
        let scope = section.flatMap { id in views(AccountSection.self, in: root).first { $0.id == id } } ?? root
        return views(NSTextField.self, in: scope).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }

    // MARK: Status items

    /// One item per account shown, each with a stable autosave name of its own; the placeholder only without one.
    private static func items(model: Model, status: StatusBar, check: Check) async {
        let shown = model.accounts.inMenuBar
        check(status.all.count == shown.count && shown.allSatisfy { status.item(for: $0.id) != nil },
              "one status item per account (\(status.all.count))")
        let names = shown.map { AccountItem.autosaveName($0.id) }
        check(Set(names).count == names.count && names.allSatisfy { $0.hasPrefix("tidemark-") }
              && names == shown.map { AccountItem.autosaveName($0.id) } && !names.contains { $0.contains("sample") },
              "each item's autosave name is stable, distinct and carries no account data")
        check(status.all.allSatisfy { $0.button?.image != nil && $0.button?.accessibilityLabel()?.isEmpty == false },
              "every item draws its account and has a VoiceOver label")
    }

    /// Hide from Menu Bar: the account's item goes, its VoiceOver label with it, but it stays in the panel, keeps the
    /// setting through a reorder, and with every account hidden one placeholder item is the three-bar glyph.
    private static func hiding(model: Model, status: StatusBar, panel: PanelController, root: NSView, check: Check) async {
        let first = model.accounts[0], order = model.accounts.map(\.id)
        @MainActor func box(_ title: String, _ label: String) -> NSButton? {
            views(NSButton.self, in: root).first { $0.title == title && $0.accessibilityLabel() == label }
        }
        let barBoxes = views(NSButton.self, in: root).filter { $0.title == "Progress Bars" || $0.title == "Amount" }
        check(barBoxes.count == model.accounts.count && barBoxes.allSatisfy { $0.state == .on && !$0.isHiddenOrHasHiddenAncestor },
              "every account offers its bars (or amount), on")
        check(first.showPercent, "the first sample account shows percentages")
        let wide = status.item(for: first.id)?.button?.image?.size.width ?? 0
        box("Labels", "Show labels in the menu bar for \(first.name)")?.performClick(nil)
        check(model.account(first.id)?.showLabels == false && !block(model, first.id).showLabels
              && (status.item(for: first.id)?.button?.image?.size.width ?? 0) < wide, "without labels, the item is narrower")
        box("Labels", "Show labels in the menu bar for \(first.name)")?.performClick(nil)
        check(model.account(first.id)?.showLabels == true, "and they come back")
        box("Progress Bars", "Show progress bars in the menu bar for \(first.name)")?.performClick(nil)
        check(model.account(first.id)?.showBars == false && status.item(for: first.id) != nil,
              "without bars, an account with percentages keeps its item")
        check(!block(model, first.id).showBars && block(model, first.id).showPercent, "it shows percentages alone")
        box("Percentage", "Show percentage in the menu bar for \(first.name)")?.performClick(nil)
        check(status.item(for: first.id) == nil && status.all.count == model.accounts.count - 1,
              "with neither, its status item is removed")
        open(panel, status)
        try? await Task.sleep(for: .milliseconds(600))
        check(panel.window.map { views(AccountSection.self, in: $0.contentView!).contains { $0.id == first.id } } == true,
              "the panel still shows an account without an item")
        panel.dismiss()
        try? await Task.sleep(for: .milliseconds(300))

        model.reorder(order.reversed())
        check(model.account(first.id)?.inMenuBar == false && status.all.count == model.accounts.count - 1,
              "it stays out of the menu bar through a reorder")
        model.reorder(order)

        let saved = model.accounts.map { ($0.id, $0.showBars, $0.showPercent) }
        for account in model.accounts { model.update(account.id) { $0.showBars = false; $0.showPercent = false } }
        check(status.all.count == 1 && status.all[0].account == nil && status.all[0].button?.image?.isTemplate == true,
              "with no account in the menu bar, one placeholder item shows the three-bar glyph")
        check(status.all[0].button?.accessibilityLabel() == "Tidemark, every account hidden from the menu bar", "VoiceOver says why")
        for (id, bars, percent) in saved where id != first.id { model.update(id) { $0.showBars = bars; $0.showPercent = percent } }
        check(status.all.allSatisfy { $0.account != nil }, "the placeholder goes once an account is shown")
        box("Percentage", "Show percentage in the menu bar for \(first.name)")?.performClick(nil)
        box("Progress Bars", "Show progress bars in the menu bar for \(first.name)")?.performClick(nil)
        check(status.all.compactMap(\.account) == model.accounts.map(\.id), "checking them brings its item back, in order")
    }

    /// Only the meters a response reports show, in the menu bar and the panel, and a meter a fresh response lacks
    /// disappears from both. An account reporting none is a neutral dash, still there to click.
    private static func limitVisibility(model: Model, status: StatusBar, panel: PanelController, check: Check) async {
        guard let account = model.accounts.first(where: { $0.login == Claude.account.id && !$0.needsSignIn && $0.snapshot != nil })
        else { return check(false, "a sample account with usage") }
        let cases: [(String, String, [LimitKind], Bool)] = [
            ("every limit and extra usage", """
             {"five_hour":{"utilization":20},"seven_day":{"utilization":40},
              "limits":[{"kind":"weekly_scoped","percent":60,"scope":{"model":{"display_name":"Fable"}}}],
              "extra_usage":{"is_enabled":true,"used_credits":1200,"monthly_limit":5000,"currency":"USD"}}
             """, [.session, .weekly, .fable], true),
            ("no 5-hour window, another scoped model, extra usage off", """
             {"five_hour":null,"seven_day":{"utilization":40},
              "limits":[{"kind":"weekly_scoped","percent":60,"scope":{"model":{"display_name":"Opus"}}}],
              "extra_usage":{"is_enabled":false,"used_credits":1200}}
             """, [.weekly], false),
            ("a null utilization and fields renamed", """
             {"five_hour":{"utilization":null},"seven_day_v2":{"utilization":40},"limits":[]}
             """, [], false),
        ]
        for (name, json, kinds, extra) in cases {
            guard let usage = try? Usage.decode(Data(json.utf8)) else { check(false, "decodes: \(name)"); continue }
            model.update(account.id) { $0.snapshot = usage.snapshot }
            let shown = block(model, account.id)
            check(shown.rows.map(\.label) == kinds.map(\.menuBarLabel), "menu bar rows, \(name): \(shown.rows.map(\.label))")
            check((status.item(for: account.id)?.button?.image?.size.width ?? 0) > 0, "the item stays clickable, \(name)")
            open(panel, status)
            try? await Task.sleep(for: .milliseconds(600))
            let texts = panelTexts(panel, in: account.id)
            check(LimitKind.allCases.allSatisfy { texts.contains($0.title) == kinds.contains($0) }, "panel rows, \(name)")
            check(texts.contains("Extra usage") == extra, "extra usage \(extra ? "shown" : "hidden"), \(name)")
            if kinds.isEmpty {
                check(texts.contains { $0.hasPrefix("No usage limits reported") } && !texts.contains("0% used"),
                      "an account reporting no limits says so, with no empty bars")
                check(summary(model, account.id).contains("\(account.name): no limits reported"), "VoiceOver says so too")
            }
            panel.dismiss()
            try? await Task.sleep(for: .milliseconds(300))
        }
        model.update(account.id) { $0.snapshot = account.snapshot }

        // 0–3 rows, each block centred on the menu bar's middle (to a device pixel).
        for count in 0...3 {
            let rows = LimitKind.allCases.prefix(count).map { MenuBarContent.Row(label: $0.menuBarLabel, percent: 50, severity: .normal) }
            let content = MenuBarContent(blocks: [.init(rows: Array(rows), showPercent: false, dimmed: false)])
            let (top, bottom) = inkMargins(MenuBarImage.image(content, height: 22, appearance: NSAppearance(named: .aqua)!))
            check(abs(top - bottom) <= 1, "\(count) rows are centred in the menu bar (margins \(top) and \(bottom) px)")
        }
    }

    /// What may be shown: nothing of a signed-out account, no value for a meter that has reset since, nothing beyond
    /// the freshness window and faded only once a refresh was missed. Puts the account back as it was.
    private static func freshness(model: Model, status: StatusBar, panel: PanelController, check: Check) async {
        guard let account = model.accounts.first(where: { $0.login == Claude.account.id && !$0.needsSignIn && $0.snapshot != nil })
        else { return check(false, "a sample account with usage") }
        let id = account.id, now = Date()
        @MainActor func shownTexts() async -> (texts: [String], historyOpen: Bool) {
            open(panel, status)
            try? await Task.sleep(for: .milliseconds(600))
            let texts = panelTexts(panel, in: id)
            let section = panel.window.flatMap { views(AccountSection.self, in: $0.contentView!).first { $0.id == id } }
            let open = section.flatMap { views(Disclosure.self, in: $0).first?.expanded } ?? false
            panel.dismiss()
            try? await Task.sleep(for: .milliseconds(300))
            return (texts, open)
        }
        let full = Usage(limits: [.session: Limit(percent: 83, resetsAt: now + 3600), .weekly: Limit(percent: 77, resetsAt: now + 86400),
                                  .fable: Limit(percent: 0, resetsAt: now + 86400)],
                         extra: ExtraUsage(spentMinor: 1450, limitMinor: 3000, currency: "USD", decimals: 2), fetchedAt: now - 30)

        // Signed out: no rows, no extra usage, no reset text; the status and its button; History closed.
        model.update(id) { $0.snapshot = full.snapshot; $0.historyExpanded = true; $0.needsSignIn = true }
        let signedOut = block(model, id)
        check(signedOut.rows.map(\.label) == ["5h", "w(A)", "w(F)"] && signedOut.rows.allSatisfy { $0.percent == nil } && signedOut.unavailable,
              "a signed-out account keeps its rows, greyed and empty, in the menu bar")
        let wasPercent = account.showPercent
        for on in [true, false] {
            model.update(id) { $0.showPercent = on }
            check(block(model, id).showPercent == on && block(model, id).unavailable,
                  "an unavailable block follows the percentage setting (\(on))")
        }
        model.update(id) { $0.showPercent = wasPercent }
        var (texts, historyOpen) = await shownTexts()
        check(!texts.contains { $0.hasSuffix("used") || $0.hasPrefix("Resets") || $0.hasSuffix("spent") }
              && !texts.contains("Extra usage") && !LimitKind.allCases.contains { texts.contains($0.title) },
              "a signed-out account shows no usage values in the panel")
        check(texts.contains("Signed out. Sign in again to see usage.") && texts.contains("History") && !historyOpen,
              "a signed-out account shows its status, and History closed")
        check(summary(model, id).contains("\(account.name): signed out"), "VoiceOver says it is signed out")

        // Extra usage in US dollars is written "$", like organisation costs.
        model.update(id) { $0.needsSignIn = false }
        (texts, _) = await shownTexts()
        check(texts.contains("$14.50 spent") && texts.contains("of $30.00 monthly limit") && !texts.contains { $0.contains("US$") },
              "extra usage in USD is shown with a plain $")

        // A meter whose reset has passed keeps its row without a value; the others are unchanged.
        var reset = full
        reset.limits[.session]?.resetsAt = now - 30
        model.update(id) { $0.snapshot = reset.snapshot }
        check(block(model, id).rows.map(\.percent) == [nil, 77, 0], "a limit that has reset has no value in the menu bar")
        (texts, _) = await shownTexts()
        check(!texts.contains("83% used") && !texts.contains("Resets now") && texts.contains("77% used")
              && texts.contains { $0.hasPrefix("Reset at ") && $0.hasSuffix("waiting for an update") },
              "the panel withholds a reset limit's old value")
        let (top, bottom) = inkMargins(MenuBarImage.image(MenuBarContent(blocks: [block(model, id)]), height: 22,
                                                          appearance: NSAppearance(named: .aqua)!))
        check(abs(top - bottom) <= 1, "a reset row stays centred (margins \(top) and \(bottom) px)")

        // Within one interval: as is; late (a refresh missed): faded; beyond the window: nothing.
        let interval = model.interval(for: account), window = Freshness.window(interval: interval)
        let late = interval + Freshness.grace + 5
        for (age, dimmed, shown) in [(30.0, false, true), (late, true, true), (window - 5, true, true), (window + 5, false, false)] {
            var aged = full
            aged.fetchedAt = now - age
            model.update(id) { $0.snapshot = aged.snapshot }
            let shownBlock = block(model, id)
            check(shown ? shownBlock.dimmed == dimmed && !shownBlock.unavailable
                        : shownBlock.unavailable && shownBlock.rows.allSatisfy { $0.percent == nil },
                  "data \(Int(age)) s old: \(shown ? dimmed ? "faded" : "shown" : "hidden")")
        }
        (texts, _) = await shownTexts()
        check(!texts.contains { $0.hasSuffix("used") || $0.hasSuffix("spent") } && texts.contains("Waiting for an update…"),
              "the panel shows no values beyond the freshness window")

        model.update(id) { $0.snapshot = account.snapshot; $0.historyExpanded = account.historyExpanded }
    }

    /// Empty pixel rows above and below what an image draws, at 2x.
    private static func inkMargins(_ image: NSImage) -> (Int, Int) {
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return (-1, -99) }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let inked = (0..<height).filter { y in (0..<width).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 } }
        guard let first = inked.first, let last = inked.last else { return (-1, -99) }
        return (first, height - 1 - last)
    }

    /// The sample Console organisation, in every place it shows. Removes it at the end.
    private static func organization(_ org: Account, model: Model, status: StatusBar, panel: PanelController,
                                     settings: SettingsController, root: NSView, check: Check) async {
        let id = org.id
        let figure = block(model, id)
        check(figure.rows.isEmpty && figure.figure?.contains("$") == true && !figure.showPercent,
              "the organisation’s menu bar block is its month to date (\(figure.figure ?? "none"))")
        check(summary(model, id).contains("\(org.name): API organisation, ") && summary(model, id).contains("used this month"),
              "VoiceOver reads the organisation’s cost")
        model.setInterval(15)
        check(model.interval(for: org) == 300, "organisations are read at most every 5 minutes")
        model.setInterval(Interval.defaultValue)

        let boxes = views(NSButton.self, in: root).filter { $0.title == "Percentage" }
        check(boxes.filter { !$0.isHiddenOrHasHiddenAncestor }.count == model.accounts.count - 1,
              "no percentage option for the organisation")
        check(views(NSButton.self, in: root).filter { $0.title == "Amount" && !$0.isHiddenOrHasHiddenAncestor }.count == 1,
              "the organisation offers its amount instead of bars")
        let labels = views(NSTextField.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
        check(labels.contains("API organisation"), "Settings lists the organisation as one")

        open(panel, status)
        try? await Task.sleep(for: .milliseconds(800))
        let shown = panelTexts(panel)
        check(shown.contains("Used this month") && shown.contains("Today so far") && shown.contains("API organisation"),
              "the panel shows the organisation’s month and today")
        check(shown.contains { $0.contains("partial") } && shown.contains { $0.hasPrefix("since ") && $0.contains("as of") },
              "today is marked partial and the month says since when and as of when")
        panel.dismiss()
        try? await Task.sleep(for: .milliseconds(300))

        let history = await model.costHistory(id, from: .distantPast)
        check(history.complete && history.ledger.series(from: .distantPast, through: Date()).count == CostPlan.maximumDays,
              "a year of daily costs for the chart")

        // Add a Console organisation with a workspace key: turned away before any request.
        settings.add(Claude.provider, Claude.console, expecting: nil)
        try? await Task.sleep(for: .milliseconds(500))
        if let sheet = settings.currentFlow as? SecretSheet, let field = sheet.fields.first as? NSTextField {
            check(settings.settingsWindow?.attachedSheet === sheet.sheetWindow && settings.isSigningIn, "the key sheet opens")
            check(!sheet.addButton.isEnabled, "Add waits for a key")
            field.stringValue = "sk-ant-api03-not-an-admin-key"
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            sheet.addButton.performClick(nil)
            check(sheet.message.contains("workspace API key"), "a workspace key is explained, not sent")
            sheet.cancel()
            try? await Task.sleep(for: .milliseconds(300))
            check(!settings.isSigningIn && settings.settingsWindow?.attachedSheet == nil, "Cancel closes the sheet")
        } else {
            check(false, "the key sheet opens")
        }
        // Re-enter Key… from a rejected organisation opens the key sheet, not a sign-in.
        model.update(id) { $0.needsSignIn = true }
        let rejected = block(model, id)
        check(rejected.figure == "$–" && rejected.unavailable, "a rejected key shows a placeholder, not the figure")
        check(summary(model, id).contains("\(org.name): API organisation, key rejected"), "VoiceOver says the key was rejected")
        model.update(id) { $0.needsSignIn = false; $0.snapshot?.fetchedAt = Date() - 3600 }
        check(block(model, id).figure == "$–", "costs older than the freshness window show no figure")
        model.update(id) { $0.needsSignIn = true; $0.snapshot = org.snapshot }
        settings.signIn(expecting: id)
        try? await Task.sleep(for: .milliseconds(300))
        check(settings.currentFlow is SecretSheet, "re-entering the key asks for a key")
        settings.currentFlow?.cancel()
        try? await Task.sleep(for: .milliseconds(300))

        // Adding the same organisation again updates it; removing it deletes its key.
        let count = model.accounts.count, vault = model.vault(Claude.console.secretItem)
        model.add(Sample.organization, credential: Credential(secret: "sk-ant-admin01-sample"), provider: Claude.provider,
                  login: Claude.console)
        let key = (try? await vault.value(id)) ?? nil
        check(model.accounts.count == count && model.account(id)?.needsSignIn == false && key?.secret == "sk-ant-admin01-sample",
              "re-adding the organisation updates it")
        model.remove(id)
        let removed = (try? await vault.value(id)) ?? nil
        check(model.account(id) == nil && removed == nil, "removing the organisation deletes its key")
    }

    // MARK: A second provider

    /// With a fake second provider: frames, tabs, an item each, Settings sections, the Add menu and every kind of
    /// sign-in sheet. Removing its accounts goes back to one provider.
    private static func providers(model: Model, status: StatusBar, panel: PanelController, settings: SettingsController,
                                  check: Check) async {
        let claude = model.accounts.map(\.id)
        let examples = Example.accounts(now: Date())
        model.loadSample(model.accounts + examples)
        check(model.accounts.providers == [Claude.id, Example.id], "providers in their fixed order")
        await items(model: model, status: status, check: check)
        let colours = Set(model.accounts.inMenuBar.compactMap { block(model, $0.id).brand })
        check(blocks(model).allSatisfy { $0.brand != nil } && colours.count == 2,
              "with two providers, every account is branded in its provider's colour")
        let robin = examples[1].id
        check(block(model, robin).figure == "$8.40" && block(model, examples[0].id).rows.map(\.label) == ["day", "mo"],
              "a provider's meters and headline figure reach the menu bar")

        // The panel opens at the clicked item's provider, with a tab per provider; tabs switch freely.
        guard let item = status.item(for: robin) else { return check(false, "the example account's item") }
        panel.open(below: item.anchor, provider: item.provider)
        try? await Task.sleep(for: .milliseconds(600))
        let tabs = panel.window.flatMap { views(ProviderTabs.self, in: $0.contentView!).first }
        check(tabs?.isHiddenOrHasHiddenAncestor == false && tabs?.titles == ["Claude", "Example"], "the panel has a tab per provider")
        check(tabs?.slotsVisible == 2, "a tab per provider fills the strip")
        let unmarked = Registry.providers.filter { $0.id != Example.id }.filter { provider in
            guard let mark = ProviderLogo.mark(provider.id) else { return true }
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">"# + mark.paths.map { #"<path d="\#($0)"/>"# }.joined() + "</svg>"
            return NSImage(data: Data(svg.utf8)) == nil
        }
        check(unmarked.isEmpty, "every provider has a logo AppKit can draw: \(unmarked.map(\.id))")
        @MainActor func sections() -> [String] {
            panel.window.map { views(AccountSection.self, in: $0.contentView!).map(\.id) } ?? []
        }
        check(panel.provider == Example.id && sections() == examples.map(\.id), "it opens at the clicked account's provider")
        check(panelTexts(panel).contains("Credit balance") && panelTexts(panel).contains("Credits left"), "money figures show")
        check(examples.allSatisfy { status.isHighlighted($0.id) } && !claude.contains { status.isHighlighted($0) },
              "every item of the shown provider is highlighted, and no other")
        tabs?.choose(Claude.id)
        try? await Task.sleep(for: .milliseconds(300))
        check(sections() == claude, "the Claude tab lists Claude's accounts, in order")
        check(claude.allSatisfy { status.isHighlighted($0) } && !examples.contains { status.isHighlighted($0.id) },
              "the highlight follows the tab")
        let shortcut = { (characters: String, flags: NSEvent.ModifierFlags, code: UInt16) in
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
        }
        _ = panel.window?.performKeyEquivalent(with: shortcut("2", .command, 19))
        check(panel.provider == Example.id, "⌘2 shows the second tab")
        _ = panel.window?.performKeyEquivalent(with: shortcut("]", [.command, .shift], 30))
        check(panel.provider == Claude.id, "⌘⇧] steps forward, round to the first")
        panel.window?.keyDown(with: shortcut("\t", [.control, .shift], 48))
        check(panel.provider == Example.id, "⌃⇧Tab steps back, round to the last")
        _ = panel.window?.performKeyEquivalent(with: shortcut("1", .command, 18))
        check(panel.provider == Claude.id, "⌘1 shows the first tab")
        // With the keyboard on the strip, as Full Keyboard Access puts it: the arrows move the focus, Space chooses.
        let key = { (code: UInt16, character: Int) in
            shortcut(String(UnicodeScalar(character)!), [], code)
        }
        if let tabs, panel.window?.makeFirstResponder(tabs) == true {
            check(tabs.focusedTitle == "Claude", "the keyboard starts on the chosen tab")
            tabs.keyDown(with: key(124, NSRightArrowFunctionKey))
            check(tabs.focusedTitle == "Example" && panel.provider == Claude.id, "→ moves the focus, not the choice")
            tabs.keyDown(with: key(49, 0x20))
            check(panel.provider == Example.id, "Space chooses the focused tab")
            tabs.keyDown(with: key(115, NSHomeFunctionKey))
            tabs.keyDown(with: key(49, 0x20))
            check(tabs.focusedTitle == "Claude" && panel.provider == Claude.id, "Home goes to the first tab")
            tabs.keyDown(with: key(119, NSEndFunctionKey))
            check(tabs.focusedTitle == "Example", "End goes to the last tab")
            panel.window?.makeFirstResponder(nil)
        } else {
            check(false, "the tab strip takes the keyboard")
        }
        panel.dismiss()
        try? await Task.sleep(for: .milliseconds(300))
        check(!examples.contains { status.isHighlighted($0.id) } && !claude.contains { status.isHighlighted($0) },
              "closed, nothing is highlighted")

        // A press opens the panel at its item's provider, that item highlighted with the rest; a press on any item of
        // that provider closes it, and one of another provider's moves it there.
        status.item(for: robin)?.button?.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        check(panel.isOpen && panel.provider == Example.id && examples.allSatisfy { status.isHighlighted($0.id) },
              "a press opens the panel, every item of its provider highlighted, its own too")
        status.item(for: claude[0])?.button?.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        check(panel.isOpen && panel.provider == Claude.id && status.isHighlighted(claude[0]) && !status.isHighlighted(robin),
              "a press on another provider's item moves the panel there")
        status.item(for: claude.last!)?.button?.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        check(!panel.isOpen && !claude.contains { status.isHighlighted($0) }, "a press on an item of the shown provider closes it")

        await shared(model: model, status: status, panel: panel, settings: settings, claude: claude, examples: examples.map(\.id),
                     check: check)

        // Settings: a section per provider; a drag reorders within its own.
        settings.show()
        try? await Task.sleep(for: .milliseconds(500))
        guard let root = settings.settingsWindow?.contentView else { return check(false, "settings window") }
        let lists = views(AccountList.self, in: root)
        check(lists.count == 2 && lists.map { $0.accessibilityLabel() ?? "" } == ["Claude accounts", "Example accounts"],
              "Settings groups accounts by provider")
        drag(lists[1], from: 20, to: 20 + AccountList.rowHeight * 1.2)
        check(model.accounts.of(Example.id).map(\.id) == examples.map(\.id).reversed() && model.accounts.of(Claude.id).map(\.id) == claude,
              "a drag reorders within its provider only")
        model.reorder(examples.map(\.id))

        // The Add menu: providers in order; several logins as a submenu.
        settings.addAccount()
        let menu = (root as? SettingsView)?.addMenu
        check(menu?.items.map(\.title) == Registry.providers.map { $0.logins.count == 1 ? $0.name + "…" : $0.name },
              "the Add menu lists every provider, in order")
        check(menu?.items.first?.submenu?.items.map(\.title) == ["Claude Account…", "Console Organisation…"]
              && menu?.items.last?.submenu?.items.count == 3, "a provider's logins are its submenu")

        await sheets(model: model, settings: settings, check: check)

        for example in model.accounts.of(Example.id) { model.remove(example.id) }
        check(blocks(model).allSatisfy { $0.brand == nil } && status.all.count == model.accounts.inMenuBar.count,
              "back to one provider: no frames, an item per account")
    }

    /// Each kind of sign-in sheet, against the fake provider.
    private static func sheets(model: Model, settings: SettingsController, check: Check) async {
        // A pasted key with extra fields.
        settings.add(Example.provider, Example.key, expecting: nil)
        try? await Task.sleep(for: .milliseconds(400))
        if let sheet = settings.currentFlow as? SecretSheet, sheet.fields.count == 3,
           let key = sheet.fields[0] as? NSSecureTextField, let team = sheet.fields[1] as? NSTextField,
           let region = sheet.fields[2] as? NSPopUpButton {
            check(region.numberOfItems == 2, "the key sheet has a secure field, a text field and a region pop-up")
            key.stringValue = "nope"
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: key))
            sheet.addButton.performClick(nil)
            check(sheet.message == "Example keys start with ex-.", "a malformed key is explained")
            key.stringValue = "ex-123"
            team.stringValue = " Blue "
            region.selectItem(at: 1)
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: key))
            sheet.addButton.performClick(nil)
            try? await Task.sleep(for: .milliseconds(400))
            let added = model.accounts.first { $0.login == Example.key.id && $0.name == "Team Blue" }
            var stored: Credential?
            if let added { stored = (try? await model.vault(Example.key.secretItem).value(added.id)) ?? nil }
            check(added != nil && stored?.fields == ["team": "Blue", "region": "eu"] && stored?.secret == "ex-123",
                  "the key and its fields are checked, stored and the account added")
        } else {
            check(false, "the key sheet with fields opens")
        }

        // A device code: shown, polled, approved.
        let count = model.accounts.count
        settings.add(Example.provider, Example.account, expecting: nil)
        try? await Task.sleep(for: .milliseconds(300))
        check((settings.currentFlow as? DeviceCodeSheet)?.shownCode == "TIDE-MARK", "the device code sheet shows the code")
        try? await Task.sleep(for: .milliseconds(1600))
        check(settings.currentFlow == nil && model.accounts.count == count && model.account("robin")?.needsSignIn == false,
              "an approved code signs the account in again")

        // A web sign-in: a web view in its own data store, only while the sheet is open.
        settings.add(Example.provider, Example.web, expecting: nil)
        try? await Task.sleep(for: .milliseconds(500))
        let web = settings.currentFlow as? WebSignIn
        check(web?.webView?.configuration.websiteDataStore.isPersistent == true
              && web?.webView?.configuration.websiteDataStore !== WKWebsiteDataStore.default(),
              "the web sign-in uses an isolated data store of its own")
        web?.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        check(settings.currentFlow == nil && web?.webView == nil, "cancelling releases the web view")
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
    }
}
#endif
