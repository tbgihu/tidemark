import Foundation

/// Tidemark's own record of how an account's meters evolved, one small file per account.
///
/// The file is a 4-byte magic followed by fixed 8-byte records: a little-endian UInt32 of Unix seconds, one byte per
/// slot (up to three meters, in the order the login charts them) holding 0–100 or 255 for "not reported", and a
/// reserved byte. Appending is a single
/// write; reading tolerates a torn last record and skips records that are malformed or out of order. Compaction keeps
/// a year of history in roughly 150 KB: every sample for 48 hours, the maximum of each 5 minutes for 30 days, and the
/// maximum of each hour beyond.
enum History {
    /// Values per slot: the login's charted meters (`HistoryKind.meters`), in order.
    static let slots = 3

    struct Sample: Equatable, Sendable {
        var time: Date
        /// One value per slot, 0–100, nil where the meter wasn't reported.
        var values: [UInt8?]

        init(time: Date, _ values: [UInt8?] = []) {
            self.time = Date(timeIntervalSince1970: time.timeIntervalSince1970.rounded(.down))
            self.values = (0..<History.slots).map { $0 < values.count ? values[$0] : nil }
        }

        /// The meters `charted` names, from a snapshot.
        init(_ snapshot: Snapshot, charted: [ChartedMeter]) {
            self.init(time: snapshot.fetchedAt, charted.prefix(History.slots).map { snapshot[meter: $0.id].map { UInt8($0.rounded) } })
        }

        subscript(slot: Int) -> UInt8? { values.indices.contains(slot) ? values[slot] : nil }

        var isEmpty: Bool { values.allSatisfy { $0 == nil } }
        func sameValues(as other: Sample) -> Bool { values == other.values }
    }

    static let magic: [UInt8] = Array("TDH1".utf8)
    static let recordSize = 8
    /// An unchanged value is still recorded this often, so the chart can tell "flat" from "not running".
    static let heartbeat: TimeInterval = 300
    /// A longer silence than this between samples is drawn as a gap.
    static let gap: TimeInterval = 2 * 3600

    /// Whether `sample` is worth recording after `last`.
    static func shouldAppend(_ sample: Sample, after last: Sample?) -> Bool {
        guard !sample.isEmpty else { return false }
        guard let last else { return true }
        if sample.time <= last.time { return false }
        return !sample.sameValues(as: last) || sample.time.timeIntervalSince(last.time) >= heartbeat
    }

    // MARK: Encoding

    static func encode(_ sample: Sample) -> [UInt8] {
        let seconds = UInt32(clamping: Int64(sample.time.timeIntervalSince1970))
        func byte(_ value: UInt8?) -> UInt8 { value.map { min($0, 100) } ?? 255 }
        return [UInt8(seconds & 0xFF), UInt8(seconds >> 8 & 0xFF), UInt8(seconds >> 16 & 0xFF), UInt8(seconds >> 24),
                byte(sample[0]), byte(sample[1]), byte(sample[2]), 0]
    }

    static func encode(_ samples: [Sample]) -> Data {
        var data = Data(magic)
        data.reserveCapacity(magic.count + samples.count * recordSize)
        for sample in samples { data.append(contentsOf: encode(sample)) }
        return data
    }

    /// The samples in `data`, oldest first. A missing or wrong header, a torn tail and bad records are skipped.
    static func decode(_ data: Data) -> [Sample] {
        guard data.count >= magic.count, Array(data.prefix(magic.count)) == magic else { return [] }
        var samples: [Sample] = []
        samples.reserveCapacity((data.count - magic.count) / recordSize)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = magic.count
            while offset + recordSize <= raw.count {
                let seconds = UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8 | UInt32(raw[offset + 2]) << 16
                    | UInt32(raw[offset + 3]) << 24
                let bytes = (raw[offset + 4], raw[offset + 5], raw[offset + 6])
                offset += recordSize
                func value(_ byte: UInt8) -> UInt8?? { byte == 255 ? .some(nil) : byte <= 100 ? .some(byte) : nil }
                guard seconds > 0, let s = value(bytes.0), let w = value(bytes.1), let f = value(bytes.2) else { continue }
                let sample = Sample(time: Date(timeIntervalSince1970: TimeInterval(seconds)), [s, w, f])
                if sample.isEmpty { continue }
                if let last = samples.last, sample.time <= last.time { continue }
                samples.append(sample)
            }
        }
        return samples
    }

    // MARK: Compaction and queries

    /// Every sample of the last 48 hours, the maximum of each 5 minutes for 30 days, and the maximum of each hour
    /// before that. Buckets keep the time of their first sample, so the order holds.
    static func compact(_ samples: [Sample], now: Date) -> [Sample] {
        let raw = now.addingTimeInterval(-48 * 3600), fine = now.addingTimeInterval(-30 * 86400)
        var result: [Sample] = []
        result.reserveCapacity(samples.count)
        var bucket: (key: Int64, sample: Sample)?
        func flush() { if let current = bucket { result.append(current.sample); bucket = nil } }
        for sample in samples {
            if sample.time >= raw { flush(); result.append(sample); continue }
            let width: Int64 = sample.time >= fine ? 300 : 3600
            let key = Int64(sample.time.timeIntervalSince1970) / width * width + (width == 300 ? 0 : 1)
            if let current = bucket, current.key == key {
                bucket = (key, merge(current.sample, sample))
            } else {
                flush()
                bucket = (key, sample)
            }
        }
        flush()
        return result
    }

    /// The samples from `start` on, with the one just before it so a step chart starts at the right level.
    static func range(_ samples: [Sample], from start: Date) -> [Sample] {
        guard let first = samples.firstIndex(where: { $0.time >= start }) else { return samples.suffix(1).map { $0 } }
        return Array(samples[max(first - 1, 0)...])
    }

    /// At most about `count` samples, keeping the maximum of each slice, so peaks survive downsampling.
    static func downsample(_ samples: [Sample], to count: Int) -> [Sample] {
        guard count > 0, samples.count > count, let first = samples.first, let last = samples.last else { return samples }
        let span = max(last.time.timeIntervalSince(first.time), 1), width = span / Double(count)
        var result: [Sample] = []
        var current: (slot: Int, sample: Sample)?
        for sample in samples {
            let slot = Int(sample.time.timeIntervalSince(first.time) / width)
            if let bucket = current, bucket.slot == slot {
                current = (slot, merge(bucket.sample, sample))
            } else {
                if let bucket = current { result.append(bucket.sample) }
                current = (slot, sample)
            }
        }
        if let bucket = current { result.append(bucket.sample) }
        return result
    }

    /// The highest value of each slot in `samples`.
    static func peaks(_ samples: [Sample]) -> [Int: UInt8] {
        var peaks: [Int: UInt8] = [:]
        for sample in samples {
            for slot in 0..<slots { if let value = sample[slot] { peaks[slot] = max(peaks[slot] ?? 0, value) } }
        }
        return peaks
    }

    private static func merge(_ a: Sample, _ b: Sample) -> Sample {
        func top(_ x: UInt8?, _ y: UInt8?) -> UInt8? { x.map { v in y.map { max(v, $0) } ?? v } ?? y }
        return Sample(time: a.time, (0..<slots).map { top(a[$0], b[$0]) })
    }

    // MARK: Files

    /// Reads a history file; a missing or unreadable one is empty.
    static func read(_ url: URL) -> [Sample] {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).map(decode) ?? []
    }

    /// The last sample in a file, read from its end without loading the rest.
    static func last(_ url: URL) -> Sample? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= UInt64(magic.count + recordSize) else { return nil }
        let records = (size - UInt64(magic.count)) / UInt64(recordSize)
        let start = UInt64(magic.count) + (records - 1) * UInt64(recordSize)
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.read(upToCount: recordSize) else { return nil }
        return decode(Data(magic) + tail).first
    }

    /// Appends one sample, creating the file (and its folder) the first time. A torn record left by an earlier
    /// crash is cut off first, so the file stays aligned.
    static func append(_ sample: Sample, to url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode([sample]).write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= UInt64(magic.count) else { try handle.close(); try encode([sample]).write(to: url, options: .atomic); return }
        let aligned = UInt64(magic.count) + (size - UInt64(magic.count)) / UInt64(recordSize) * UInt64(recordSize)
        if aligned != size { try handle.truncate(atOffset: aligned) }
        try handle.write(contentsOf: encode(sample))
    }

    /// Rewrites a file compacted, atomically. Returns the samples kept.
    @discardableResult
    static func compactFile(_ url: URL, now: Date = Date()) throws -> [Sample] {
        let samples = read(url)
        let kept = compact(samples, now: now)
        if kept.count != samples.count || (try? Data(contentsOf: url).count) != magic.count + samples.count * recordSize {
            try encode(kept).write(to: url, options: .atomic)
        }
        return kept
    }
}
