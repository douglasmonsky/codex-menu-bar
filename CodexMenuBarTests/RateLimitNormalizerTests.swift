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

    func testMenuBarTextReplacesWeeklyLabelWithResetCountdown() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let weeklyReset = now.addingTimeInterval((3 * 24 + 5) * 3_600)
        let raw = result(map: ["codex": bucket(
            primary: window(used: 32, duration: 300),
            secondary: window(used: 57, duration: 10_080, resetsAt: weeklyReset.timeIntervalSince1970)
        )])
        let snapshot = try XCTUnwrap(RateLimitNormalizer.normalize(raw, fetchedAt: now))

        XCTAssertEqual(
            MenuBarTextFormatter.text(for: snapshot, now: now),
            "5h 68% · 43% · 3d 5h"
        )
    }

    func testMenuBarCountdownRoundsUpPartialHours() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let raw = result(map: ["codex": bucket(primary: window(
            used: 57,
            duration: 10_080,
            resetsAt: now.addingTimeInterval(60).timeIntervalSince1970
        ))])
        let snapshot = try XCTUnwrap(RateLimitNormalizer.normalize(raw, fetchedAt: now))

        XCTAssertEqual(MenuBarTextFormatter.text(for: snapshot, now: now), "43% · 0d 1h")
    }

    func testScriptableExporterWritesAggregateSnapshotAndWidgetScript() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("codex-menu-bar-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let container = home.appendingPathComponent(
            "Library/Mobile Documents/iCloud~dk~simonbs~Scriptable",
            isDirectory: true
        )
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let scriptSource = home.appendingPathComponent("source.js")
        try Data("// Managed by Codex Menu Bar\nScript.complete()".utf8).write(to: scriptSource)

        let now = Date(timeIntervalSince1970: 1_000)
        let raw = result(map: ["codex": bucket(
            primary: window(used: 32, duration: 300),
            secondary: window(
                used: 57,
                duration: 10_080,
                resetsAt: now.addingTimeInterval(3_600).timeIntervalSince1970
            )
        )])
        let snapshot = try XCTUnwrap(RateLimitNormalizer.normalize(raw, fetchedAt: now))
        let exporter = ScriptableExporter(
            homeDirectory: home,
            scriptSourceURL: scriptSource
        )

        let status = await exporter.export(snapshot)
        XCTAssertEqual(status, .exported)

        let documents = container.appendingPathComponent("Documents")
        let data = try Data(contentsOf: documents.appendingPathComponent("codex-usage.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ScriptableExportPayload.self, from: data)
        XCTAssertEqual(payload.updatedAt, now)
        XCTAssertEqual(payload.windows.map(\.remainingPercent), [68, 43])
        XCTAssertEqual(
            try String(contentsOf: documents.appendingPathComponent("Codex Usage.js")),
            "// Managed by Codex Menu Bar\nScript.complete()"
        )
    }

    func testScriptableExporterWaitsForICloudContainer() async {
        let exporter = ScriptableExporter(
            homeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString)")
        )

        let status = await exporter.export(UsageSnapshot(windows: [], fetchedAt: Date()))
        XCTAssertEqual(status, .waitingForICloud)
    }

    func testScriptableExporterPreservesConflictingUserScript() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("codex-menu-bar-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let documents = home.appendingPathComponent(
            "Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents",
            isDirectory: true
        )
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        let destination = documents.appendingPathComponent("Codex Usage.js")
        try Data("// My custom script".utf8).write(to: destination)
        let scriptSource = home.appendingPathComponent("source.js")
        try Data("// Managed by Codex Menu Bar".utf8).write(to: scriptSource)

        let exporter = ScriptableExporter(
            homeDirectory: home,
            scriptSourceURL: scriptSource
        )

        let status = await exporter.export(UsageSnapshot(windows: [], fetchedAt: Date()))
        XCTAssertEqual(status, .scriptNameConflict)
        XCTAssertEqual(try String(contentsOf: destination), "// My custom script")
    }

    private func result(map: [String: RawRateLimitBucket]?, top: RawRateLimitBucket? = nil) -> RateLimitsReadResult {
        RateLimitsReadResult(rateLimits: top, rateLimitsByLimitId: map)
    }

    private func bucket(primary: RawRateLimitWindow? = nil, secondary: RawRateLimitWindow? = nil) -> RawRateLimitBucket {
        RawRateLimitBucket(limitId: "codex", limitName: nil, primary: primary, secondary: secondary, rateLimitReachedType: nil)
    }

    private func window(used: Double, duration: Int?, resetsAt: Double? = nil) -> RawRateLimitWindow {
        RawRateLimitWindow(usedPercent: used, windowDurationMins: duration, resetsAt: resetsAt)
    }
}
