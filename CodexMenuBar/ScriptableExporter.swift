import Foundation

struct ScriptableExportPayload: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let durationMinutes: Int
        let remainingPercent: Double
        let resetsAt: Date?
        let compactLabel: String
    }

    struct Tasks: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            let title: String
            let date: Date
        }

        let runningCount: Int
        let finishedCount: Int
        let running: [Item]
        let finished: [Item]
    }

    let updatedAt: Date
    let windows: [Window]
    let tasks: Tasks

    init(snapshot: UsageSnapshot, taskActivity: TaskActivitySnapshot) {
        updatedAt = snapshot.fetchedAt
        windows = snapshot.windows.map {
            Window(
                durationMinutes: $0.durationMinutes,
                remainingPercent: $0.remainingPercent,
                resetsAt: $0.resetsAt,
                compactLabel: $0.compactLabel
            )
        }
        let running = Array(taskActivity.running.prefix(4))
        let remainingSlots = 4 - running.count
        let finished = Array(taskActivity.finished.prefix(remainingSlots))
        tasks = Tasks(
            runningCount: taskActivity.running.count,
            finishedCount: taskActivity.finished.count,
            running: running.map {
                Tasks.Item(title: $0.title, date: $0.date)
            },
            finished: finished.map {
                Tasks.Item(title: $0.title, date: $0.date)
            }
        )
    }
}

actor ScriptableExporter {
    enum Status: Equatable, Sendable {
        case exported
        case waitingForICloud
        case scriptNameConflict
        case failed
    }

    private static let ownershipMarker = "// Managed by Codex Menu Bar"
    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let scriptSourceURL: URL?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        scriptSourceURL: URL? = Bundle.main.url(forResource: "Codex Usage", withExtension: "js")
    ) {
        self.homeDirectory = homeDirectory
        self.scriptSourceURL = scriptSourceURL
    }

    func export(
        _ snapshot: UsageSnapshot,
        taskActivity: TaskActivitySnapshot = .empty
    ) -> Status {
        let container = homeDirectory
            .appendingPathComponent("Library/Mobile Documents/iCloud~dk~simonbs~Scriptable")
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: container.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .waitingForICloud
        }

        do {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                ScriptableExportPayload(snapshot: snapshot, taskActivity: taskActivity)
            )
            try data.write(
                to: documents.appendingPathComponent("codex-usage.json"),
                options: .atomic
            )

            if let scriptSourceURL {
                let destination = documents.appendingPathComponent("Codex Usage.js")
                let sourceData = try Data(contentsOf: scriptSourceURL)
                let existingData = try? Data(contentsOf: destination)
                var destinationData = sourceData
                if let existingData, existingData != sourceData {
                    let marker = Data(Self.ownershipMarker.utf8)
                    guard let markerRange = existingData.range(of: marker),
                          markerRange.lowerBound < 512 else {
                        return .scriptNameConflict
                    }
                    destinationData = existingData[..<markerRange.lowerBound] + sourceData
                }
                if existingData != destinationData {
                    try destinationData.write(to: destination, options: .atomic)
                }
            }
            return .exported
        } catch {
            return .failed
        }
    }
}
