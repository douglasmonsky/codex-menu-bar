import XCTest
@testable import CodexMenuBar

final class RateLimitNormalizerTests: XCTestCase {
    func testCodexMapWinsAndComputesRemaining() {
        let result = result(map: ["codex": bucket(primary: window(used: 32, duration: 300), secondary: window(used: 57, duration: 10_080)), "codex_other": bucket(primary: window(used: 1, duration: 60))])
        let snapshot = RateLimitNormalizer.normalize(result, fetchedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot?.windows.map(\.compactLabel), ["5h", "W"])
        XCTAssertEqual(snapshot?.windows.map(\.remainingPercent), [68, 43])
    }

    func testTopLevelFallbackAndUnknownBucketUnavailable() {
        XCTAssertNotNil(RateLimitNormalizer.normalize(result(map: nil, top: bucket(primary: window(used: 10, duration: 15)))))
        XCTAssertNil(RateLimitNormalizer.normalize(result(map: ["codex_other": bucket(primary: window(used: 10, duration: 15))], top: nil)))
    }

    func testInvalidAndClampedWindows() {
        let raw = result(map: ["codex": bucket(primary: window(used: -10, duration: 60), secondary: window(used: 150, duration: nil))])
        let snapshot = RateLimitNormalizer.normalize(raw)
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertEqual(snapshot?.windows.first?.remainingPercent, 100)
        XCTAssertNil(RateLimitNormalizer.normalize(result(map: ["codex": bucket(primary: window(used: .nan, duration: 60))])))
    }

    func testPrimaryPrecedesSecondaryWhenDurationsMatch() {
        let raw = result(map: ["codex": bucket(primary: window(used: 10, duration: 60), secondary: window(used: 20, duration: 60))])
        XCTAssertEqual(RateLimitNormalizer.normalize(raw)?.windows.map(\.id), ["primary", "secondary"])
    }

    private func result(map: [String: RawRateLimitBucket]?, top: RawRateLimitBucket? = nil) -> RateLimitsReadResult {
        RateLimitsReadResult(rateLimits: top, rateLimitsByLimitId: map)
    }

    private func bucket(primary: RawRateLimitWindow? = nil, secondary: RawRateLimitWindow? = nil) -> RawRateLimitBucket {
        RawRateLimitBucket(limitId: "codex", limitName: nil, primary: primary, secondary: secondary, rateLimitReachedType: nil)
    }

    private func window(used: Double, duration: Int?) -> RawRateLimitWindow {
        RawRateLimitWindow(usedPercent: used, windowDurationMins: duration, resetsAt: nil)
    }
}
