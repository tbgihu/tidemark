import Foundation
import Testing
@testable import TidemarkCore

@Suite struct HistoryTests {
    typealias Sample = History.Sample
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tidemark-tests/\(UUID().uuidString)/h.bin")
    }

    @Test func encodingRoundTrips() {
        let samples = [Sample(time: now, [0, 100, nil]), Sample(time: now + 1, [55, nil, nil])]
        let data = History.encode(samples)
        #expect(data.count == 4 + 2 * 8)
        #expect(History.decode(data) == samples)
    }

    @Test func sampleFromUsage() {
        let usage = Usage(limits: [.session: Limit(percent: 47.6, resetsAt: nil), .fable: Limit(percent: 120, resetsAt: nil)],
                          fetchedAt: now + 0.7)
        #expect(Sample(usage.snapshot, charted: Claude.account.history.charted) == Sample(time: now, [48, nil, 100]))
    }

    @Test func appendOnlyOnChangeOrHeartbeat() {
        let first = Sample(time: now, [10, nil, nil])
        #expect(History.shouldAppend(first, after: nil))
        #expect(!History.shouldAppend(Sample(time: now + 60, [10, nil, nil]), after: first))
        #expect(History.shouldAppend(Sample(time: now + 60, [11, nil, nil]), after: first))
        #expect(History.shouldAppend(Sample(time: now + 60, [10, 1, nil]), after: first))
        #expect(History.shouldAppend(Sample(time: now + 300, [10, nil, nil]), after: first))
        #expect(!History.shouldAppend(Sample(time: now - 1, [99, nil, nil]), after: first))
        #expect(!History.shouldAppend(Sample(time: now + 999), after: first))
    }

    @Test func appendReadAndLast() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(History.read(url).isEmpty)
        #expect(History.last(url) == nil)
        for index in 0..<5 { try History.append(Sample(time: now + Double(index) * 60, [nil, UInt8(index)]), to: url) }
        #expect(History.read(url).map { $0[1] } == [0, 1, 2, 3, 4])
        #expect(History.last(url) == Sample(time: now + 240, [nil, 4, nil]))
        #expect(try Data(contentsOf: url).count == 4 + 5 * 8)
    }

    @Test func toleratesCorruption() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var data = History.encode([Sample(time: now, [1, nil, nil]), Sample(time: now + 10, [2, nil, nil])])
        data.append(contentsOf: [1, 2, 3])                                     // a torn record
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        #expect(History.read(url).map { $0[0] } == [1, 2])
        try History.append(Sample(time: now + 20, [3, nil, nil]), to: url)       // cuts the torn bytes first
        #expect(History.read(url).map { $0[0] } == [1, 2, 3])

        var bad = History.encode([Sample(time: now, [1, nil, nil])])
        bad.append(contentsOf: History.encode(Sample(time: now + 5, [1, nil, nil])).map { $0 } .enumerated().map { $0.offset == 4 ? 200 : $0.element })
        bad.append(contentsOf: History.encode(Sample(time: now - 5, [7, nil, nil])))   // out of order
        bad.append(contentsOf: [0, 0, 0, 0, 5, 5, 5, 0])                           // zero time
        bad.append(contentsOf: History.encode(Sample(time: now + 9, [9, nil, nil])))
        #expect(History.decode(bad).map { $0[0] } == [1, 9])
        #expect(History.decode(Data("nope, not history".utf8)).isEmpty)
        #expect(History.decode(Data()).isEmpty)
    }

    @Test func appendRepairsAFileWithoutHeader() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: url)
        try History.append(Sample(time: now, [nil, nil, 4]), to: url)
        #expect(History.read(url) == [Sample(time: now, [nil, nil, 4])])
    }

    @Test func compactionTiers() {
        var samples: [Sample] = []
        // 40 days, one sample a minute; every 50 minutes a 99
        let start = now - 40 * 86400
        for minute in stride(from: 0, to: 40 * 1440, by: 1) {
            samples.append(Sample(time: start + Double(minute) * 60, [nil, minute % 50 == 7 ? 99 : UInt8(minute % 40)]))
        }
        let kept = History.compact(samples, now: now)
        let rawCount = kept.filter { $0.time >= now - 48 * 3600 }.count
        let fineCount = kept.filter { $0.time < now - 48 * 3600 && $0.time >= now - 30 * 86400 }.count
        let coarseCount = kept.filter { $0.time < now - 30 * 86400 }.count
        #expect(rawCount == 48 * 60)
        #expect(abs(fineCount - 28 * 288) <= 1)
        #expect(abs(coarseCount - 10 * 24) <= 1)
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $0.time < $1.time })
        // buckets keep the maximum
        #expect(kept.filter { $0.time < now - 30 * 86400 }.dropFirst().dropLast().allSatisfy { $0[1] == 99 })   // the first and last hours are partial
        // compacting again changes nothing
        #expect(History.compact(kept, now: now) == kept)
        #expect(History.encode(kept).count < 100_000)
    }

    @Test func compactFile() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for hour in 0..<(24 * 40) { try History.append(Sample(time: now - Double(hour) * 3600 - 1, [50]), to: url) }
        // appended newest first: only the first is in order, but nothing crashes
        #expect(History.read(url).count == 1)
        try FileManager.default.removeItem(at: url)
        for minute in stride(from: 40 * 1440, to: 0, by: -10) { try History.append(Sample(time: now - Double(minute) * 60, [5]), to: url) }
        let before = History.read(url).count
        let kept = try History.compactFile(url, now: now)
        #expect(kept.count < before)
        #expect(History.read(url) == kept)
    }

    @Test func rangeIncludesTheSampleBefore() {
        let samples = (0..<10).map { Sample(time: now + Double($0) * 3600, [UInt8($0)]) }
        #expect(History.range(samples, from: now + 5 * 3600 - 1).map { $0[0] } == [4, 5, 6, 7, 8, 9])
        #expect(History.range(samples, from: now - 100).count == 10)
        #expect(History.range(samples, from: now + 100 * 3600).map { $0[0] } == [9])
        #expect(History.range([], from: now).isEmpty)
    }

    @Test func downsampleKeepsPeaks() {
        let samples = (0..<1000).map { Sample(time: now + Double($0) * 60, [nil, $0 == 437 ? 97 : 10]) }
        let reduced = History.downsample(samples, to: 100)
        #expect(reduced.count <= 101)
        #expect(reduced.contains { $0[1] == 97 })
        #expect(History.downsample(samples, to: 5000) == samples)
    }

    @Test func peaks() {
        let samples = [Sample(time: now, [10, 70, nil]), Sample(time: now + 1, [92, nil, 3])]
        #expect(History.peaks(samples) == [0: 92, 1: 70, 2: 3])
        #expect(History.peaks([]).isEmpty)
    }
}
