import Foundation

struct CodexThreadSummary: Decodable, Sendable {
    let id: String
    let name: String?
    let path: String?
    let updatedAt: Int64
}

struct TaskActivitySnapshot: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let id: String
        let title: String
        let date: Date
    }

    static let empty = TaskActivitySnapshot(running: [], finished: [])

    let running: [Item]
    let finished: [Item]
}

actor TaskActivityScanner {
    private static let chunkSize: UInt64 = 64 * 1_024
    private let fileManager = FileManager.default

    func scan(
        threads: [CodexThreadSummary],
        now: Date = Date(),
        recentInterval: TimeInterval = 2 * 60 * 60
    ) -> TaskActivitySnapshot {
        let cutoff = now.addingTimeInterval(-recentInterval)
        var running: [TaskActivitySnapshot.Item] = []
        var finished: [TaskActivitySnapshot.Item] = []

        for thread in threads {
            guard Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)) >= cutoff,
                  let path = thread.path,
                  let activity = activity(at: URL(fileURLWithPath: path)) else {
                continue
            }
            let title = displayTitle(for: thread)

            if let lastUserMessage = activity.lastUserMessage,
               lastUserMessage > (activity.lastCompletion ?? .distantPast),
               lastUserMessage >= cutoff {
                running.append(.init(id: thread.id, title: title, date: lastUserMessage))
            } else if let lastCompletion = activity.lastCompletion,
                      lastCompletion >= (activity.lastUserMessage ?? .distantPast),
                      lastCompletion >= cutoff {
                finished.append(.init(id: thread.id, title: title, date: lastCompletion))
            }
        }

        return TaskActivitySnapshot(
            running: running.sorted { $0.date > $1.date },
            finished: finished.sorted { $0.date > $1.date }
        )
    }

    private func activity(at url: URL) -> Activity? {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            var lastUserMessage: Date?
            var lastCompletion: Date?
            var end = size
            var carriedPrefix = Data()
            let fractionalDecoder = ISO8601DateFormatter()
            fractionalDecoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standardDecoder = ISO8601DateFormatter()

            while end > 0, lastUserMessage == nil || lastCompletion == nil {
                let start = end > Self.chunkSize ? end - Self.chunkSize : 0
                try handle.seek(toOffset: start)
                var data = try handle.read(upToCount: Int(end - start)) ?? Data()
                data.append(carriedPrefix)
                var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                if start > 0 {
                    carriedPrefix = Data(lines.removeFirst())
                } else {
                    carriedPrefix.removeAll(keepingCapacity: false)
                }

                for line in lines.reversed() where !line.isEmpty {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          object["type"] as? String == "event_msg",
                          let payload = object["payload"] as? [String: Any],
                          let type = payload["type"] as? String,
                          let timestampText = object["timestamp"] as? String,
                          let timestamp = fractionalDecoder.date(from: timestampText)
                            ?? standardDecoder.date(from: timestampText) else {
                        continue
                    }
                    if type == "user_message", lastUserMessage == nil {
                        lastUserMessage = timestamp
                    } else if type == "task_complete", lastCompletion == nil {
                        let completedAt: Date?
                        if let seconds = payload["completed_at"] as? NSNumber {
                            completedAt = Date(timeIntervalSince1970: seconds.doubleValue)
                        } else if let text = payload["completed_at"] as? String {
                            completedAt = fractionalDecoder.date(from: text)
                                ?? standardDecoder.date(from: text)
                        } else {
                            completedAt = nil
                        }
                        lastCompletion = max(completedAt ?? timestamp, timestamp)
                    }
                }
                end = start
            }

            guard lastUserMessage != nil || lastCompletion != nil else { return nil }
            return Activity(lastUserMessage: lastUserMessage, lastCompletion: lastCompletion)
        } catch {
            return nil
        }
    }

    private func displayTitle(for thread: CodexThreadSummary) -> String {
        let raw = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (raw?.isEmpty == false ? raw : nil) ?? "Untitled task"
        let collapsed = source
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 48 else { return collapsed }
        return String(collapsed.prefix(47)) + "…"
    }

    private struct Activity {
        let lastUserMessage: Date?
        let lastCompletion: Date?
    }
}
