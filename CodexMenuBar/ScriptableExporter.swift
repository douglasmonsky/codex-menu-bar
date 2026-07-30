import Foundation

struct ScriptableExportPayload: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let durationMinutes: Int
        let remainingPercent: Double
        let resetsAt: Date?
        let compactLabel: String
    }

    let updatedAt: Date
    let windows: [Window]

    init(snapshot: UsageSnapshot) {
        updatedAt = snapshot.fetchedAt
        windows = snapshot.windows.map {
            Window(
                durationMinutes: $0.durationMinutes,
                remainingPercent: $0.remainingPercent,
                resetsAt: $0.resetsAt,
                compactLabel: $0.compactLabel
            )
        }
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

    func export(_ snapshot: UsageSnapshot) -> Status {
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
            let data = try encoder.encode(ScriptableExportPayload(snapshot: snapshot))
            try data.write(
                to: documents.appendingPathComponent("codex-usage.json"),
                options: .atomic
            )

            if let scriptSourceURL {
                let destination = documents.appendingPathComponent("Codex Usage.js")
                let sourceData = try Data(contentsOf: scriptSourceURL)
                if let existingData = try? Data(contentsOf: destination),
                   existingData != sourceData,
                   !existingData.starts(with: Data(Self.ownershipMarker.utf8)) {
                    return .scriptNameConflict
                }
                if (try? Data(contentsOf: destination)) != sourceData {
                    try sourceData.write(to: destination, options: .atomic)
                }
            }
            return .exported
        } catch {
            return .failed
        }
    }
}
