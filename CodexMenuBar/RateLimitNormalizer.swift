import Foundation

struct RateLimitsReadResult: Decodable, Sendable {
    let rateLimits: RawRateLimitBucket?
    let rateLimitsByLimitId: [String: RawRateLimitBucket]?
}

struct RawRateLimitBucket: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: RawRateLimitWindow?
    let secondary: RawRateLimitWindow?
    let rateLimitReachedType: String?
}

struct RawRateLimitWindow: Decodable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}

struct UsageSnapshot: Equatable, Sendable {
    let windows: [UsageWindow]
    let fetchedAt: Date
}

struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let durationMinutes: Int
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Date?
    let compactLabel: String
    let displayLabel: String
}

enum RateLimitNormalizer {
    static func normalize(_ result: RateLimitsReadResult, fetchedAt: Date = Date()) -> UsageSnapshot? {
        let mapBucket = result.rateLimitsByLimitId?["codex"]
        let bucket = usableWindows(in: mapBucket) ? mapBucket : result.rateLimits
        guard let bucket, usableWindows(in: bucket) else { return nil }

        let windows = [
            makeWindow(bucket.primary, role: "primary"),
            makeWindow(bucket.secondary, role: "secondary")
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }

        return UsageSnapshot(
            windows: windows.sorted {
                $0.durationMinutes == $1.durationMinutes
                    ? $0.id == "primary"
                    : $0.durationMinutes < $1.durationMinutes
            },
            fetchedAt: fetchedAt
        )
    }

    private static func usableWindows(in bucket: RawRateLimitBucket?) -> Bool {
        guard let bucket else { return false }
        return makeWindow(bucket.primary, role: "primary") != nil
            || makeWindow(bucket.secondary, role: "secondary") != nil
    }

    private static func makeWindow(_ raw: RawRateLimitWindow?, role: String) -> UsageWindow? {
        guard let raw,
              let used = raw.usedPercent,
              used.isFinite,
              let duration = raw.windowDurationMins,
              duration > 0 else { return nil }

        let remaining = min(100, max(0, 100 - used))
        let labels = labels(for: duration)
        let reset = raw.resetsAt.flatMap { value in
            value.isFinite && value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        return UsageWindow(
            id: role,
            durationMinutes: duration,
            usedPercent: used,
            remainingPercent: remaining,
            resetsAt: reset,
            compactLabel: labels.compact,
            displayLabel: labels.display
        )
    }

    private static func labels(for minutes: Int) -> (compact: String, display: String) {
        if abs(minutes - 300) <= 10 { return ("5h", "5-hour window") }
        if abs(minutes - 10_080) <= 60 { return ("W", "Weekly window") }
        if minutes < 60 { return ("\(minutes)m", "\(minutes)-minute window") }
        if minutes < 2_880, minutes % 60 == 0 {
            let hours = minutes / 60
            return ("\(hours)h", "\(hours)-hour window")
        }
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return ("\(days)d", "\(days)-day window")
        }
        return ("\(minutes)m", "\(minutes)-minute window")
    }
}

struct JSONLineFramer {
    enum FramingError: Error, Equatable { case lineTooLong }

    private var buffer: [UInt8] = []
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 2 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Array(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if buffer.count > maximumLineBytes { throw FramingError.lineTooLong }
        return lines
    }
}
