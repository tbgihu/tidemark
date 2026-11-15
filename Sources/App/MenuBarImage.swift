import AppKit

/// What the menu bar shows, reduced to what is drawn, so an unchanged value never causes a redraw.
struct MenuBarContent: Equatable {
    struct Row: Equatable {
        /// The meter's short label: "5h".
        let label: String
        /// Nil once the meter has reset since the data was read: its row shows a dash instead of a bar.
        let percent: Int?
        let severity: Severity
    }
    struct Block: Equatable {
        let rows: [Row]
        let showPercent: Bool
        /// The labels ("5h") before each row.
        var showLabels = true
        /// Bars beside the labels; without them, labels and percentages alone.
        var showBars = true
        /// The data missed a refresh but is still within the freshness window: drawn faded. Beyond it, or signed out,
        /// a block has no rows or figure at all.
        let dimmed: Bool
        /// The headline figure of an account without meters ("$412"), drawn instead of rows.
        var figure: String? = nil
        /// Nothing may be shown, but the last known layout is: labels and empty tracks, `-%` for a percentage, `$–` for
        /// a figure. Never values.
        var unavailable = false
        /// The provider's colour, for the mark down the block's left; nil for none (a single provider is configured).
        var brand: BrandColor? = nil
        /// One of the accounts the open panel shows: drawn on a soft highlight, the shape of the menu bar's own.
        var highlighted = false
    }
    var blocks: [Block]
}

/// Draws an account's status item: a block of up to three rows (label, bar, optional percentage), centred as a
/// group on the menu bar's middle, every edge on a device pixel. Labels and percentages use the menu bar's label
/// colour and the tracks a neutral tint of it; the fills are that colour too, orange or red as a limit runs low, as
/// in the panel. A late block is faded, its fills grey: old data never raises the alarm, nor looks current; an account
/// with nothing that may be shown keeps its rows greyed out and empty (labels, tracks, `-%`) when its layout is known,
/// else is a neutral dash. An account without meters is a single figure (an organisation's month to date, a
/// balance) in the same type and neutral colour (money has no grade), centred on the middle. Once accounts of more
/// than one provider are configured, a hairline of its provider's colour runs down the left of every block, so they
/// tell apart at a glance; a faded block's fades with it. Every account the open panel shows sits on a faint rounded
/// rectangle. The image is drawn for one appearance (light, dark, Increase Contrast); StatusItem draws it again
/// when that changes.
@MainActor
enum MenuBarImage {
    static let rowPitch: CGFloat = 6.5
    static let barWidth: CGFloat = 20
    static let barHeight: CGFloat = 3
    static let gap: CGFloat = 3
    /// Between one block and the next.
    static let blockGap: CGFloat = 2
    /// The highlight: as tall as the menu bar allows, its corners gently rounded, so it fits right up to its content.
    static let highlightHeight: CGFloat = 22
    static let highlightRadius: CGFloat = 4
    /// The provider's mark and the space after it, before a block's content.
    static let markSpace: CGFloat = 4
    static let font = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold)
    /// Parentheses at the labels' size reach well above the capitals and below the baseline; smaller ones, centred
    /// on the capitals, keep three rows of labels inside the highlight.
    private static let parenthesis = NSFont.systemFont(ofSize: 6, weight: .semibold)
    private static let parenthesisOffset: CGFloat = {
        let ink = NSAttributedString(string: "(", attributes: [.font: parenthesis])
            .boundingRect(with: .zero, options: [.usesDeviceMetrics, .usesFontLeading])
        return font.capHeight / 2 - ink.midY
    }()

    static func image(_ content: MenuBarContent, height: CGFloat, appearance: NSAppearance) -> NSImage {
        // Nothing to show and no provider to tell: the plain three-bar glyph. With a provider, its mark and a dash.
        if content.blocks.allSatisfy({ $0.rows.isEmpty && $0.figure == nil && $0.brand == nil }) { return empty(height: height) }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let widths = widths(content)
        let total = widths.reduce(0, +) + blockGap * CGFloat(widths.count - 1)
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { rect in
            let scale = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for (block, width) in zip(content.blocks, widths) {
                    if block.highlighted {
                        highlight(x: x, width: width, height: rect.height, scale: max(scale, 1), contrast: contrast)
                    }
                    var left = x + padding(block).left
                    if let brand = block.brand {
                        mark(brand, block: block, x: left, height: rect.height, scale: max(scale, 1), contrast: contrast)
                        left += markSpace
                    }
                    draw(block, x: left, height: rect.height, scale: max(scale, 1), contrast: contrast)
                    x += width + blockGap
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Each block's width, padding and provider mark included.
    private static func widths(_ content: MenuBarContent) -> [CGFloat] {
        content.blocks.map { block in
            let (left, right) = padding(block)
            return left + (block.brand == nil ? 0 : markSpace) + width(block) + right
        }
    }

    /// Where each block sits across the image, left to right: what a click on a shared item lands on.
    static func spans(_ content: MenuBarContent) -> [ClosedRange<CGFloat>] {
        var x: CGFloat = 0
        return widths(content).map { width in
            defer { x += width + blockGap }
            return x...(x + width)
        }
    }

    /// A row's label, its parentheses smaller and centred on the capitals.
    private static func label(_ label: String, color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        for (index, character) in label.utf16.enumerated() where character == 0x28 || character == 0x29 {
            text.addAttributes([.font: parenthesis, .baselineOffset: parenthesisOffset],
                               range: NSRange(location: index, length: 1))
        }
        return text
    }

    private static func labelWidth(_ block: MenuBarContent.Block) -> CGFloat {
        block.rows.map { ceil(label($0.label, color: .labelColor).size().width) }.max() ?? 0
    }

    /// The figure a row shows beside its bar, or in its place: nil where there is none.
    private static func percentText(_ row: MenuBarContent.Row, _ block: MenuBarContent.Block) -> String? {
        if block.unavailable { return block.showBars && !block.showPercent ? nil : "-%" }
        guard block.showPercent || !block.showBars else { return nil }
        return row.percent.map(Format.percent) ?? (block.showBars ? nil : "–")
    }

    /// As wide as the widest figure the rows show now, not the widest one could: "8%" takes less than "100%".
    private static func percentWidth(_ block: MenuBarContent.Block) -> CGFloat {
        block.rows.compactMap { percentText($0, block) }
            .map { ceil(($0 as NSString).size(withAttributes: [.font: digits]).width) }.max() ?? 0
    }

    private static func width(_ block: MenuBarContent.Block) -> CGFloat {
        if let figure = block.figure { return ceil((figure as NSString).size(withAttributes: [.font: digits]).width) }
        if block.rows.isEmpty { return 9 }
        // Labels, bars and percentages, as chosen, one gap apart.
        let figures = percentWidth(block)
        let parts = [block.showLabels ? labelWidth(block) : nil, block.showBars ? barWidth : nil,
                     figures > 0 ? figures : nil].compactMap(\.self)
        return parts.reduce(0, +) + gap * CGFloat(max(parts.count - 1, 0))
    }

    private static func draw(_ block: MenuBarContent.Block, x: CGFloat, height: CGFloat, scale: CGFloat, contrast: Bool) {
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let alpha: CGFloat = block.dimmed ? (contrast ? 0.6 : 0.45) : 1
        let ink = NSColor.labelColor
        if let figure = block.figure {
            let attributes: [NSAttributedString.Key: Any] = [.font: digits, .foregroundColor: ink.withAlphaComponent(alpha)]
            let baseline = pixel(height / 2 - digits.capHeight / 2)
            (figure as NSString).draw(at: NSPoint(x: x, y: baseline + digits.descender), withAttributes: attributes)
            return
        }
        guard !block.rows.isEmpty else {
            ink.withAlphaComponent(alpha * 0.5).setFill()
            dash(x: x, height: height, scale: scale)
            return
        }
        // Where the bars, or the percentages without them, start: after the labels, when they are shown.
        let start = x + (block.showLabels ? labelWidth(block) + gap : 0)
        let count = CGFloat(block.rows.count)
        // Row centres, top to bottom, symmetric around the middle of the bar.
        let middle = height / 2
        for (index, row) in block.rows.enumerated() {
            let centre = middle + (count - 1) / 2 * rowPitch - CGFloat(index) * rowPitch
            let baseline = pixel(centre - font.capHeight / 2)
            if block.showLabels {
                label(row.label, color: ink.withAlphaComponent(alpha)).draw(at: NSPoint(x: x, y: baseline + font.descender))
            }

            let bar = NSRect(x: pixel(start), y: pixel(centre - barHeight / 2),
                             width: block.showBars ? barWidth : 0, height: pixel(barHeight))
            let percentX = block.showBars ? bar.maxX + gap : start
            if !block.showBars {
                let text = percentText(row, block) ?? "–"
                // Without a bar to fill, the figure itself turns orange or red as the limit runs low.
                let warned = !block.dimmed && !block.unavailable && row.percent != nil && row.severity != .normal
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: digits, .foregroundColor: warned ? row.severity.color : ink.withAlphaComponent(alpha),
                ]
                (text as NSString).draw(at: NSPoint(x: percentX, y: baseline + digits.descender), withAttributes: attributes)
                continue
            }
            if block.unavailable {
                ink.withAlphaComponent(alpha * (contrast ? 0.4 : 0.22)).setFill()
                NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
                if block.showPercent {
                    let attributes: [NSAttributedString.Key: Any] = [.font: digits, .foregroundColor: ink.withAlphaComponent(alpha)]
                    ("-%" as NSString).draw(at: NSPoint(x: bar.maxX + gap, y: baseline + digits.descender), withAttributes: attributes)
                }
                continue
            }
            guard let percent = row.percent else {
                // Reset since: no value, so no track to read as one; a short neutral dash in the bar's place.
                ink.withAlphaComponent(alpha * 0.6).setFill()
                let stub = NSRect(x: pixel(bar.midX - 3), y: bar.minY, width: 6, height: bar.height)
                NSBezierPath(roundedRect: stub, xRadius: stub.height / 2, yRadius: stub.height / 2).fill()
                continue
            }
            ink.withAlphaComponent(alpha * (contrast ? 0.4 : 0.22)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            let fraction = CGFloat(min(max(percent, 0), 100)) / 100
            var filled = pixel(bar.width * fraction)
            if percent > 0 { filled = max(filled, 1 / scale) }
            if filled > 0 {
                (block.dimmed ? ink.withAlphaComponent(alpha * 0.7) : row.severity.color).setFill()
                let fill = NSRect(x: bar.minX, y: bar.minY, width: filled, height: bar.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).addClip()
                fill.fill(using: .sourceOver)                      // over the track, not in place of it
                NSGraphicsContext.restoreGraphicsState()
            }
            if block.showPercent {
                let text = Format.percent(percent) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: digits, .foregroundColor: ink.withAlphaComponent(alpha)]
                text.draw(at: NSPoint(x: bar.maxX + gap, y: baseline + digits.descender), withAttributes: attributes)
            }
        }
    }

    /// The provider's mark: a thin rounded line down the left of a block, a point wide (one and a half with Increase
    /// Contrast), a little shorter than its rows (or figure) and centred on them, on device pixels. Faded with a faded block,
    /// less so with Increase Contrast.
    private static func mark(_ brand: BrandColor, block: MenuBarContent.Block, x: CGFloat, height: CGFloat,
                             scale: CGFloat, contrast: Bool) {
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let line = contrast ? 1.5 : 1
        // A little shorter than the rows it marks, so it reads as a mark beside them rather than a rule; never so short
        // that a single row's is hard to see.
        let rows = CGFloat(max(block.rows.count, 1))
        let tall = pixel(max(((rows - 1) * rowPitch + font.capHeight) * 0.8, 8))
        let dimmed = block.dimmed || block.rows.isEmpty && block.figure == nil
        NSColor(srgbRed: brand.red, green: brand.green, blue: brand.blue,
                alpha: dimmed ? (contrast ? 0.6 : 0.4) : 1).setFill()
        let bar = NSRect(x: pixel(x), y: pixel((height - tall) / 2), width: line, height: tall)
        NSBezierPath(roundedRect: bar, xRadius: line / 2, yRadius: line / 2).fill()
    }

    /// The highlight under an account the open panel shows: the label colour, faint, a rounded rectangle as tall as
    /// the menu bar allows.
    private static func highlight(x: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat, contrast: Bool) {
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let tall = pixel(min(height, highlightHeight))
        NSColor.labelColor.withAlphaComponent(contrast ? 0.24 : 0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: pixel(x), y: pixel((height - tall) / 2), width: pixel(width), height: tall),
                     xRadius: highlightRadius, yRadius: highlightRadius).fill()
    }

    /// Left and right of a block's content, inside its highlight: just enough that the highlight frames it.
    static func padding(_ block: MenuBarContent.Block) -> (left: CGFloat, right: CGFloat) { (2.5, 2.5) }

    /// An account with nothing to show yet, among others that have: the three-bar glyph in miniature, dimmed.
    private static func dash(x: CGFloat, height: CGFloat, scale: CGFloat) {
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        for (index, width) in [9.0, 6.0, 4.0].enumerated() {
            let centre = height / 2 + 4 - CGFloat(index) * 4
            let line = NSRect(x: x, y: pixel(centre - 1), width: width, height: pixel(2))
            NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()
        }
    }

    /// No accounts: three tide lines, like empty bars. A template image, so macOS tints it like any other.
    static func empty(height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: height), flipped: false) { rect in
            let scale = max(NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2, 1)
            func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
            for (index, width) in [16.0, 12.0, 8.0].enumerated() {
                let centre = rect.height / 2 + rowPitch - CGFloat(index) * rowPitch
                let line = NSRect(x: 0, y: pixel(centre - 1.25), width: width, height: pixel(2.5))
                NSColor.black.withAlphaComponent(index == 0 ? 0.85 : 0.5).setFill()
                NSBezierPath(roundedRect: line, xRadius: line.height / 2, yRadius: line.height / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
