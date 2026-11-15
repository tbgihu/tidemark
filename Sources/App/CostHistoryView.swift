import AppKit
import Charts
import SwiftUI

/// Hosts an organisation's cost chart, like `HistoryHost`: built when History is expanded, released when it closes.
@MainActor
final class CostHistoryHost: NSHostingView<CostHistoryView> {
    init(load: @escaping CostHistoryView.Load) {
        super.init(rootView: CostHistoryView(load: load))
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = false
    }

    @MainActor required init(rootView: CostHistoryView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}

/// An organisation's daily costs in USD, from the cost report: bars for a week or a month, a line for longer. The
/// time frames are the subscription history's, without 24 hours (a day is the report's smallest unit); the choice is
/// shared with it. Days are UTC days, labelled as such; today, still counting, is drawn lighter. Older days are read
/// when a longer frame is first chosen and cached, a year at most.
struct CostHistoryView: View {
    typealias Load = @MainActor (Date) async -> (ledger: CostLedger, complete: Bool)
    let load: Load

    // SwiftUI's state, declared without the @State macro, whose plugin the Command Line Tools don't include.
    private let loaded = State<CostLedger?>(initialValue: nil)
    private let incomplete = State(initialValue: false)
    private let loading = State(initialValue: false)
    private let selected = State(initialValue: Self.storedRange)
    private let hovered = State<Date?>(initialValue: nil)

    static let ranges: [HistoryRange] = [.week, .month, .year, .all]
    private static var storedRange: HistoryRange {
        let stored = HistoryRange(rawValue: Preferences.historyRange) ?? .week
        return ranges.contains(stored) ? stored : .week
    }

    private var range: HistoryRange { selected.wrappedValue }
    private var hover: Date? {
        get { hovered.wrappedValue }
        nonmutating set { hovered.wrappedValue = newValue }
    }

    struct Day: Identifiable {
        let day: Date
        let cents: Decimal
        var id: Date { day }
        /// For drawing only: every figure shown as text comes from `cents`.
        var dollars: Double { NSDecimalNumber(decimal: cents).doubleValue / 100 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Time frame", selection: selected.projectedValue) {
                    ForEach(Self.ranges) { Text($0.title).accessibilityLabel($0.spoken).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                if loading.wrappedValue, loaded.wrappedValue != nil {
                    ProgressView().controlSize(.mini).accessibilityLabel("Loading older costs")
                }
            }
            .onChange(of: range) { _, value in Preferences.historyRange = value.rawValue; hover = nil }

            if let ledger = loaded.wrappedValue {
                let days = visible(ledger)
                if days.count < 2 {
                    empty
                } else {
                    chart(days)
                    totals(days)
                }
                if incomplete.wrappedValue, !loading.wrappedValue {
                    Text("Older costs couldn’t be read right now.").font(.caption2).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .frame(width: PanelContent.width - 2 * PanelContent.inset)
        .foregroundStyle(Color(nsColor: .labelColor))                   // the panel's, in either appearance
        .task(id: range) {
            loading.wrappedValue = true
            if loaded.wrappedValue == nil { loaded.wrappedValue = await load(.distantFuture).ledger }   // the cache first
            let result = await load(start)
            guard !Task.isCancelled else { return }
            loaded.wrappedValue = result.ledger
            incomplete.wrappedValue = !result.complete
            loading.wrappedValue = false
        }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.bar.xaxis").font(.title3).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text("No costs to show yet").font(.callout).foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private var today: Date { CostCalendar.day(Date()) }

    /// The first day of the frame: 7 or 30 days, or a year; All starts at the first day anything was spent.
    private var start: Date {
        let days = switch range {
        case .week: 6
        case .month: 29
        default: CostPlan.maximumDays - 1
        }
        return CostCalendar.add(days: -days, to: today)
    }

    private func visible(_ ledger: CostLedger) -> [Day] {
        var days = ledger.series(from: start, through: today).map { Day(day: $0.day, cents: $0.cents) }
        if range == .all, let first = days.firstIndex(where: { $0.cents != 0 }) { days.removeFirst(first) }
        return days
    }

    private var bars: Bool { range == .week || range == .month }

    // MARK: Chart

    private static let utc = TimeZone(identifier: "UTC")!

    private static func dayFormat(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var style = style
        style.timeZone = utc
        style.calendar = CostCalendar.utc
        return style
    }

    private func chart(_ days: [Day]) -> some View {
        let ink = Color(nsColor: .labelColor)
        let lower = days.first?.day ?? today
        let upper = CostCalendar.add(days: 1, to: days.last?.day ?? today)
        return Chart {
            ForEach(days) { day in
                if bars {
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.dollars))
                        .foregroundStyle(ink.opacity(day.day == today ? 0.35 : 0.8))
                        .cornerRadius(1.5)
                } else {
                    AreaMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.dollars))
                        .interpolationMethod(.stepCenter)
                        .foregroundStyle(ink.opacity(0.12))
                    LineMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.dollars))
                        .interpolationMethod(.stepCenter)
                        .foregroundStyle(ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }
            if let hover, let day = days.first(where: { $0.day == CostCalendar.day(hover) }) {
                RuleMark(x: .value("Day", day.day, unit: .day))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(day) }
            }
        }
        .chartXScale(domain: lower...upper)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(Format.compactMoney(cents: Decimal(dollars) * 100))
                    }
                }
            }
        }
        .chartXAxis {
            if range == .week {
                // Every bar named, centred under it: a label centred between each midnight and the next (the range's
                // end included, so the last one has its next), and no grid line between bars.
                let weekdays = WeekdayLabels(days: days.count, calendar: CostCalendar.utc)
                AxisMarks(values: days.map(\.day) + [upper]) { value in
                    AxisValueLabel(centered: true, collisionResolution: .disabled) {
                        if let day = value.as(Date.self), day < upper { weekdays.label(day) }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                    AxisValueLabel(format: Self.dayFormat(range == .month ? .dateTime.day().month(.abbreviated)
                                                          : .dateTime.month(.abbreviated)), collisionResolution: .greedy)
                }
            }
        }
        // The report's days are UTC days: bins, ticks and labels are too, so a bar is never shown a day off.
        .environment(\.timeZone, Self.utc)
        .environment(\.calendar, CostCalendar.utc)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            hover = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .frame(height: 140)
        .accessibilityChartDescriptor(CostDescriptor(range: range, days: days))
    }

    private func tooltip(_ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.day.formatted(Self.dayFormat(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) + " (UTC)")
                .font(.caption2).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Text(Format.money(cents: day.cents) + (day.day == today ? " so far" : ""))
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(minWidth: 90, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    private func totals(_ days: [Day]) -> some View {
        let total = days.reduce(Decimal(0)) { $0 + $1.cents }
        let peak = days.max { $0.cents < $1.cents }
        return HStack(spacing: 6) {
            capsule("Total", Format.money(cents: total), spoken: "Total \(Format.money(cents: total))")
            if let peak, peak.cents > 0 {
                let date = peak.day.formatted(Self.dayFormat(.dateTime.day().month(.abbreviated)))
                capsule("Peak", "\(Format.money(cents: peak.cents)) · \(date)",
                        spoken: "Highest day \(date), \(Format.money(cents: peak.cents))")
            }
        }
    }

    private func capsule(_ title: String, _ value: String, spoken: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Text(value).monospacedDigit().fontWeight(.semibold)
        }
        .lineLimit(1)
        .fixedSize()
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .quaternarySystemFill), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// VoiceOver's description of the chart: one value per UTC day, in dollars.
private struct CostDescriptor: AXChartDescriptorRepresentable {
    let range: HistoryRange
    let days: [CostHistoryView.Day]

    func makeChartDescriptor() -> AXChartDescriptor {
        let from = days.first?.day.timeIntervalSince1970 ?? 0
        let to = max(days.last?.day.timeIntervalSince1970 ?? 0, from + 1)
        let x = AXNumericDataAxisDescriptor(title: "Day (UTC)", range: from...to, gridlinePositions: []) {
            var style = Date.FormatStyle.dateTime.day().month().year()
            style.timeZone = TimeZone(identifier: "UTC")!
            return Date(timeIntervalSince1970: $0).formatted(style)
        }
        let top = max(days.map(\.dollars).max() ?? 0, 1)
        let y = AXNumericDataAxisDescriptor(title: "Cost", range: 0...top, gridlinePositions: []) {
            Format.money(cents: Decimal($0) * 100)
        }
        let series = AXDataSeriesDescriptor(name: "Daily cost", isContinuous: false, dataPoints: days.map {
            AXDataPoint(x: $0.day.timeIntervalSince1970, y: $0.dollars)
        })
        return AXChartDescriptor(title: "Daily costs, \(range.spoken)", summary: nil, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}
