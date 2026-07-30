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
        XCTAssertTrue(payload.tasks.running.isEmpty)
        XCTAssertTrue(payload.tasks.finished.isEmpty)
        XCTAssertEqual(
            try String(
                contentsOf: documents.appendingPathComponent("Codex Usage.js"),
                encoding: .utf8
            ),
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
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "// My custom script")
    }

    func testScriptableExporterPreservesScriptableMetadataWhenUpdatingManagedScript() async throws {
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
        let metadata = "// Variables used by Scriptable.\n// icon-color: purple;\n"
        try Data("\(metadata)// Managed by Codex Menu Bar\nold".utf8).write(to: destination)
        let scriptSource = home.appendingPathComponent("source.js")
        try Data("// Managed by Codex Menu Bar\nnew".utf8).write(to: scriptSource)
        let exporter = ScriptableExporter(
            homeDirectory: home,
            scriptSourceURL: scriptSource
        )

        let status = await exporter.export(UsageSnapshot(windows: [], fetchedAt: Date()))

        XCTAssertEqual(status, .exported)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "\(metadata)// Managed by Codex Menu Bar\nnew"
        )
    }

    func testTaskActivityScannerFindsRunningAndRecentlyFinishedTasks() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-task-activity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 10_000)
        let runningPath = directory.appendingPathComponent("running.jsonl")
        let finishedPath = directory.appendingPathComponent("finished.jsonl")
        let oldPath = directory.appendingPathComponent("old.jsonl")
        try writeRollout(
            [
                event("task_complete", at: now.addingTimeInterval(-3_600)),
                event("user_message", at: now.addingTimeInterval(-300)),
                event("token_count", at: now.addingTimeInterval(-240))
            ],
            to: runningPath
        )
        try writeRollout(
            [
                event("user_message", at: now.addingTimeInterval(-1_800)),
                event("task_complete", at: now.addingTimeInterval(-1_740))
            ],
            to: finishedPath
        )
        try writeRollout(
            [
                event("user_message", at: now.addingTimeInterval(-14_400)),
                event("task_complete", at: now.addingTimeInterval(-10_800))
            ],
            to: oldPath
        )

        let scanner = TaskActivityScanner()
        let snapshot = await scanner.scan(
            threads: [
                thread(id: "running", name: "Build the widget", path: runningPath),
                thread(id: "finished", name: "Ship the menu app", path: finishedPath),
                thread(id: "old", name: "Old task", path: oldPath)
            ],
            now: now
        )

        XCTAssertEqual(snapshot.running.map(\.title), ["Build the widget"])
        XCTAssertEqual(snapshot.finished.map(\.title), ["Ship the menu app"])
    }

    func testTaskActivityScannerNeverUsesPreviewAsTitle() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-task-privacy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("unnamed.jsonl")
        let now = Date(timeIntervalSince1970: 10_000)
        try writeRollout([event("user_message", at: now)], to: path)
        let scanner = TaskActivityScanner()

        let snapshot = await scanner.scan(
            threads: [thread(id: "unnamed", name: nil, path: path)],
            now: now
        )

        XCTAssertEqual(snapshot.running.map(\.title), ["Untitled task"])
    }

    func testTaskActivityScannerUsesNumericCompletionTimestampForOrdering() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-task-ordering-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ordering.jsonl")
        let now = Date(timeIntervalSince1970: 10_000)
        var completion = event("task_complete", at: now.addingTimeInterval(-300))
        completion["payload"] = [
            "type": "task_complete",
            "completed_at": now.addingTimeInterval(-60).timeIntervalSince1970
        ]
        try writeRollout(
            [completion, event("user_message", at: now.addingTimeInterval(-120))],
            to: path
        )
        let scanner = TaskActivityScanner()

        let snapshot = await scanner.scan(
            threads: [thread(id: "finished", name: "Finished", path: path)],
            now: now
        )

        XCTAssertTrue(snapshot.running.isEmpty)
        XCTAssertEqual(snapshot.finished.map(\.title), ["Finished"])
    }

    func testTaskActivityScannerFindsUserMessageBeyondFirstTailChunk() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-task-long-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("long.jsonl")
        let now = Date(timeIntervalSince1970: 10_000)
        let filler = String(repeating: "x", count: 600_000)
        try writeRollout(
            [
                event("user_message", at: now.addingTimeInterval(-300)),
                [
                    "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
                    "type": "event_msg",
                    "payload": ["type": "token_count", "filler": filler]
                ]
            ],
            to: path
        )
        let scanner = TaskActivityScanner()

        let snapshot = await scanner.scan(
            threads: [thread(id: "long", name: "Long task", path: path)],
            now: now
        )

        XCTAssertEqual(snapshot.running.map(\.title), ["Long task"])
    }

    func testTaskActivityScannerIgnoresOldUserMessageWithRecentIncidentalEvent() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("codex-task-stale-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let path = directory.appendingPathComponent("stale.jsonl")
        let now = Date(timeIntervalSince1970: 10_000)
        try writeRollout(
            [
                event("user_message", at: now.addingTimeInterval(-10_800)),
                event("token_count", at: now.addingTimeInterval(-60))
            ],
            to: path
        )
        let scanner = TaskActivityScanner()

        let snapshot = await scanner.scan(
            threads: [thread(id: "stale", name: "Stale task", path: path)],
            now: now
        )

        XCTAssertEqual(snapshot, .empty)
    }

    func testScriptablePayloadIncludesBoundedTaskTitles() {
        let now = Date(timeIntervalSince1970: 1_000)
        let activity = TaskActivitySnapshot(
            running: (0..<5).map {
                .init(id: "running-\($0)", title: "Running \($0)", date: now)
            },
            finished: (0..<5).map {
                .init(id: "finished-\($0)", title: "Finished \($0)", date: now)
            }
        )

        let payload = ScriptableExportPayload(
            snapshot: UsageSnapshot(windows: [], fetchedAt: now),
            taskActivity: activity
        )

        XCTAssertEqual(payload.tasks.running.map(\.title), ["Running 0", "Running 1", "Running 2", "Running 3"])
        XCTAssertTrue(payload.tasks.finished.isEmpty)
        XCTAssertLessThanOrEqual(
            payload.tasks.running.count + payload.tasks.finished.count,
            4
        )
        XCTAssertEqual(payload.tasks.runningCount, 5)
        XCTAssertEqual(payload.tasks.finishedCount, 5)
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

    private func thread(id: String, name: String?, path: URL) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            name: name,
            path: path.path,
            updatedAt: 10_000
        )
    }

    private func event(_ type: String, at date: Date) -> [String: Any] {
        [
            "timestamp": ISO8601DateFormatter().string(from: date),
            "type": "event_msg",
            "payload": ["type": type]
        ]
    }

    private func writeRollout(_ events: [[String: Any]], to url: URL) throws {
        let data = try events.reduce(into: Data()) { result, event in
            result.append(try JSONSerialization.data(withJSONObject: event))
            result.append(0x0A)
        }
        try data.write(to: url)
    }
}
