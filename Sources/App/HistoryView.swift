import AppKit
import Charts
import SwiftUI

/// Hosts the history chart. Created when History is expanded and released when it collapses or the panel closes,
/// so SwiftUI and the samples are in memory only while the chart is on screen.
@MainActor
final class HistoryHost: NSHostingView<HistoryView> {
    init(account: String, charted: [ChartedMeter]) {
        super.init(rootView: HistoryView(account: account, charted: charted))
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = false
    }

    @MainActor required init(rootView: HistoryView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}

/// The time frames the history can show.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month, year, all
    var id: Self { self }

    var title: String {
        switch self {
        case .day: "24h"
        case .week: "1w"
        case .month: "1m"
        case .year: "1y"
        case .all: "All"
        }
    }

    var spoken: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last week"
        case .month: "Last month"
        case .year: "Last year"
        case .all: "All history"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .year: 365 * 86400
        case .all: nil
        }
    }
}

/// How an account's charted meters (Claude's 5-hour, weekly and Fable limits) evolved, from the samples Tidemark
/// recorded. Steps, not slopes: a limit
/// holds its value until the next sample and drops at a reset. Longer silences (Tidemark not running) are gaps.
///
/// As on the bars, a line is drawn in the foreground colour and turns orange, then red, where the limit ran low
/// (graded by percentage: the samples keep no server grade). The limits are told apart by their stroke, solid,
/// dashed and dotted, so colour is free to carry the grade and never has to name the meter.
struct HistoryView: View {
    let account: String
    /// The meters in the file's slots, in order.
    let charted: [ChartedMeter]
    // SwiftUI's state, declared without the @State macro, whose plugin the Command Line Tools don't include.
    private let loaded = State<[History.Sample]?>(initialValue: nil)
    private let selected = State(initialValue: HistoryRange(rawValue: Preferences.historyRange) ?? .day)
    private let hovered = State<Date?>(initialValue: nil)

    private var samples: [History.Sample]? {
        get { loaded.wrappedValue }
        nonmutating set { loaded.wrappedValue = newValue }
    }
    private var range: HistoryRange { selected.wrappedValue }
    private var hover: Date? {
        get { hovered.wrappedValue }
        nonmutating set { hovered.wrappedValue = newValue }
    }

    struct Point: Identifiable {
        let id: Int
        let time: Date
        let slot: Int
        let value: Int
        let severity: Severity
        /// Which line the point is on: a new one after each gap and each change of grade, as a line has one colour.
        let series: String
        /// Added where the grade changes, so the line before and the line after join up: drawn, but not data.
        var bridge = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Time frame", selection: selected.projectedValue) {
                ForEach(HistoryRange.allCases) { Text($0.title).accessibilityLabel($0.spoken).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .onChange(of: range) { _, value in Preferences.historyRange = value.rawValue; hover = nil }

            if let samples {
                let shown = visible(samples)
                if shown.count < 2 {
                    empty
                } else {
                    chart(shown)
                    peaks(shown)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 140)
            }
        }
        .frame(width: PanelContent.width - 2 * PanelContent.inset)      // a fixed width, so layout never probes wider
        .foregroundStyle(Color(nsColor: .labelColor))                   // the panel's, in either appearance
        .task { samples = await HistoryRecorder.load(account) }
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.title3).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text("History builds up as Tidemark runs").font(.callout).foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private var now: Date { Date() }

    private func start(_ samples: [History.Sample]) -> Date {
        if let seconds = range.seconds { return now.addingTimeInterval(-seconds) }
        // Never after now (samples recorded before the clock was set back), or the chart's domain `from...now` traps.
        guard let first = samples.first?.time else { return now.addingTimeInterval(-86400) }
        return min(first, now.addingTimeInterval(-60))
    }

    private func visible(_ samples: [History.Sample]) -> [History.Sample] {
        History.downsample(History.range(samples, from: start(samples)), to: 360)
    }

    /// One point per limit and sample, a new line after every gap and every change of grade, and the last value
    /// carried to now when the latest sample is recent.
    private func points(_ samples: [History.Sample], from: Date) -> [Point] {
        var points: [Point] = []
        var segment = 0
        var previous: Date?
        // Per limit: the line being drawn (its grade, number and segment) and its last value.
        var lines: [Int: (severity: Severity, run: Int, segment: Int, value: Int)] = [:]
        func add(_ kind: Int, _ sampled: UInt8, at time: Date) {
            let value = Int(sampled), severity = Severity(percent: Double(sampled))
            func point(_ value: Int, _ severity: Severity, run: Int, bridge: Bool = false) {
                points.append(Point(id: points.count, time: time, slot: kind, value: value, severity: severity,
                                    series: "\(kind)-\(run)", bridge: bridge))
            }
            var line = lines[kind] ?? (severity, 0, segment, value)
            if line.segment != segment {
                line = (severity, line.run + 1, segment, value)
            } else if line.severity != severity {
                // A step line holds its value up to the next point, then steps to it. The step is drawn in the calmer
                // of the two grades, so only time spent running low is coloured: a rise steps up on the old line, a
                // fall (a reset) steps down on the new one.
                if severity > line.severity {
                    point(value, line.severity, run: line.run, bridge: true)
                } else {
                    point(line.value, line.severity, run: line.run, bridge: true)
                    point(line.value, severity, run: line.run + 1, bridge: true)
                }
                line = (severity, line.run + 1, segment, value)
            }
            line.value = value
            lines[kind] = line
            point(value, severity, run: line.run)
        }
        for sample in samples {
            if let previous, sample.time.timeIntervalSince(previous) > History.gap { segment += 1 }
            previous = sample.time
            let time = max(sample.time, from)
            for slot in slots {
                if let value = sample[slot] { add(slot, value, at: time) }
            }
        }
        if let last = samples.last, now.timeIntervalSince(last.time) < History.gap {
            for slot in slots {
                if let value = last[slot] { add(slot, value, at: now) }
            }
        }
        return points
    }

    /// The values at `time`: the last sample at or before it.
    private func values(at time: Date, in samples: [History.Sample]) -> History.Sample? {
        guard let index = samples.lastIndex(where: { $0.time <= time }) else { return nil }
        if index == samples.count - 1, time.timeIntervalSince(samples[index].time) > History.gap { return nil }
        if index + 1 < samples.count, samples[index + 1].time.timeIntervalSince(samples[index].time) > History.gap,
           time.timeIntervalSince(samples[index].time) > History.gap { return nil }
        return samples[index]
    }

    private var slots: Range<Int> { 0..<min(charted.count, History.slots) }

    private func label(_ slot: Int) -> String { charted.indices.contains(slot) ? charted[slot].label : "" }
    private func title(_ slot: Int) -> String { charted.indices.contains(slot) ? charted[slot].title : "" }

    /// The stroke of a slot's line in the chart and its key: solid, dashed or dotted.
    static func stroke(_ slot: Int) -> StrokeStyle {
        switch slot {
        case 0: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        case 1: StrokeStyle(lineWidth: 1.6, lineCap: .butt, lineJoin: .round, dash: [5, 3])
        default: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [0, 3.5])
        }
    }

    // MARK: Chart

    private func chart(_ samples: [History.Sample]) -> some View {
        let from = start(samples)
        let data = points(samples, from: from)
        let present = Set(data.map(\.slot))
        return Chart {
            ForEach(data) { point in
                LineMark(x: .value("Time", point.time), y: .value("Used", point.value),
                         series: .value("Series", point.series))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color(nsColor: point.severity.color))
                    .lineStyle(by: .value("Limit", label(point.slot)))
            }
            if let hover, let sample = values(at: hover, in: samples) {
                RuleMark(x: .value("Time", hover))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(sample, at: hover)
                    }
            }
        }
        .chartLineStyleScale(domain: slots.map(label), range: slots.map(Self.stroke))
        .chartLegend(present.count > 1 ? .visible : .hidden)
        // Drawn here, as Charts would draw the strokes' key in the accent colour, which reads as a grade. Inside the
        // panel, styles relative to the foreground (.secondary, .quaternary) don't follow the appearance: colours are explicit.
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForEach(slots.filter(present.contains), id: \.self) { slot in
                    HStack(spacing: 4) {
                        Swatch(slot: slot)
                        Text(label(slot)).font(.caption2).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
        }
        .chartXScale(domain: from...now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
            }
        }
        .chartXAxis {
            if range == .week {
                // A grid line at each midnight, and each day's name centred on the part of it that is shown, when
                // that is at least half a day.
                let bounds = Self.days(from: from, to: now)
                let weekdays = WeekdayLabels(days: 7, calendar: .autoupdatingCurrent)
                AxisMarks(values: bounds.dropFirst().dropLast().map { $0 }) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                }
                AxisMarks(values: bounds) { value in
                    AxisValueLabel(centered: true, collisionResolution: .disabled) {
                        if let start = value.as(Date.self), let end = bounds.first(where: { $0 > start }),
                           end.timeIntervalSince(start) >= 12 * 3600 {
                            weekdays.label(start)
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                    AxisValueLabel(format: axisFormat(from: from), collisionResolution: .greedy)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            hover = proxy.value(atX: x, as: Date.self).map { min(max($0, from), now) }
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .frame(height: 140)
        .accessibilityChartDescriptor(HistoryDescriptor(range: range, from: from, to: now, points: data,
                                                        titles: slots.map(title)))
    }

    /// `from`, every local midnight after it and before `to`, and `to`: the edges of the days the range shows.
    private static func days(from: Date, to: Date) -> [Date] {
        let calendar = Calendar.autoupdatingCurrent
        var edges = [from]
        var day = calendar.startOfDay(for: from)
        while let next = calendar.date(byAdding: .day, value: 1, to: day), next < to {
            edges.append(next)
            day = next
        }
        return edges + [to]
    }

    /// Hours for a day, days and months for a month, months beyond, with the year once the span passes a year (a
    /// two-digit year would read as a day: "Nov 25").
    private func axisFormat(from: Date) -> Date.FormatStyle {
        let span = now.timeIntervalSince(from)
        if span <= 2 * 86400 { return .dateTime.hour() }
        if span <= 120 * 86400 { return .dateTime.day().month(.abbreviated) }
        if span <= 366 * 86400 { return .dateTime.month(.abbreviated) }
        return .dateTime.month(.abbreviated).year()
    }

    private func tooltip(_ sample: History.Sample, at time: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(time, format: range == .day ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                .font(.caption2).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            ForEach(slots, id: \.self) { slot in
                if let value = sample[slot] {
                    HStack(spacing: 4) {
                        Swatch(slot: slot)
                        Text(label(slot)).font(.caption2)
                        Spacer(minLength: 6)
                        Text("\(value)%").font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color(nsColor: Severity(percent: Double(value)).color))
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(minWidth: 90)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    private func peaks(_ samples: [History.Sample]) -> some View {
        let peaks = History.peaks(samples)
        return HStack(spacing: 6) {
            Text("Peak").font(.caption2).foregroundStyle(Color(nsColor: .secondaryLabelColor)).fixedSize()
            ForEach(slots.filter { peaks[$0] != nil }, id: \.self) { slot in
                let peak = peaks[slot] ?? 0
                let severity = Severity(percent: Double(peak))
                HStack(spacing: 4) {
                    Text(label(slot)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    Text("\(peak)%").monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(Color(nsColor: severity.color))
                }
                .lineLimit(1)
                .fixedSize()
                .font(.caption2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color(nsColor: .quaternarySystemFill), in: .capsule)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title(slot)) peak \(peak)%" + (severity.spoken.map { ", \($0)" } ?? ""))
            }
        }
    }
}

/// A meter's line in miniature, for the chart's key and the tooltip.
private struct Swatch: View {
    let slot: Int

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 3))
            path.addLine(to: CGPoint(x: 13, y: 3))
        }
        .stroke(Color(nsColor: .labelColor), style: HistoryView.stroke(slot))
        .frame(width: 14, height: 6)
        .accessibilityHidden(true)
    }
}

/// VoiceOver's description of the chart: time against percentage, one series per meter.
private struct HistoryDescriptor: AXChartDescriptorRepresentable {
    let range: HistoryRange
    let from: Date
    let to: Date
    let points: [HistoryView.Point]
    /// Each slot's spoken title.
    let titles: [String]

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXNumericDataAxisDescriptor(title: "Time", range: from.timeIntervalSince1970...max(to.timeIntervalSince1970, from.timeIntervalSince1970 + 1),
                                            gridlinePositions: []) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
        let y = AXNumericDataAxisDescriptor(title: "Used", range: 0...100, gridlinePositions: [0, 50, 100]) { "\(Int($0))%" }
        let series = titles.indices.compactMap { slot -> AXDataSeriesDescriptor? in
            let values = points.filter { $0.slot == slot && !$0.bridge }
            guard !values.isEmpty else { return nil }
            return AXDataSeriesDescriptor(name: titles[slot], isContinuous: true, dataPoints: values.map {
                AXDataPoint(x: $0.time.timeIntervalSince1970, y: Double($0.value))
            })
        }
        return AXChartDescriptor(title: "Usage history, \(range.spoken)", summary: nil, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: series)
    }
}

/// A week's x-axis: one label per day, the weekday as the locale abbreviates it ("Mon"), set smaller, or narrow
/// ("M"), when the locale's names don't fit a day's width in the panel. Never rotated.
@MainActor
struct WeekdayLabels {
    private let symbols: [String]
    private let size: CGFloat
    private let calendar: Calendar

    /// `days` labels across the chart; `calendar` says which day a date is in (UTC for costs).
    init(days: Int, calendar: Calendar, locale: Locale = .autoupdatingCurrent) {
        var names = Calendar(identifier: .gregorian)
        names.locale = locale
        // The plot is the panel's width less the trailing y-axis labels; each label keeps a little air around it.
        let slot = (PanelContent.width - 2 * PanelContent.inset - 34) / CGFloat(max(days, 1)) - 4
        func fits(_ symbols: [String], _ size: CGFloat) -> Bool {
            let font = NSFont.systemFont(ofSize: size)
            return symbols.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= slot }
        }
        let short = names.shortWeekdaySymbols
        let options = [(short, CGFloat(10)), (short, 9), (names.veryShortWeekdaySymbols, 10)]
        (symbols, size) = options.first { fits($0.0, $0.1) } ?? options[2]
        self.calendar = calendar
    }

    func label(_ date: Date) -> Text {
        let index = calendar.component(.weekday, from: date) - 1
        return Text(symbols.indices.contains(index) ? symbols[index] : "").font(.system(size: size))
    }
}
