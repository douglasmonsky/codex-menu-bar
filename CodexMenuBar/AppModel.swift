import Foundation
import Combine

enum ConnectionState: Equatable, Sendable {
    case starting
    case connecting
    case connected
    case degraded
    case unavailable
    case notAuthenticated
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var connectionState: ConnectionState = .starting
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private var lifecycleTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var client: AppServerClient?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        start()
    }

    deinit {
        lifecycleTask?.cancel()
        notificationTask?.cancel()
    }

    var menuBarText: String {
        guard let snapshot else {
            switch connectionState {
            case .starting, .connecting: return "Codex …"
            default: return "Codex ?"
            }
        }
        let values = snapshot.windows.map { "\($0.compactLabel) \(Int($0.remainingPercent.rounded()))%" }
        return values.joined(separator: " · ") + (connectionState == .connected ? "" : " !")
    }

    var statusText: String {
        switch connectionState {
        case .starting, .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .degraded: return "Disconnected or degraded"
        case .unavailable: return "Codex executable not found"
        case .notAuthenticated: return "Codex is not signed in for ChatGPT usage"
        }
    }

    var shouldShowLocate: Bool { connectionState == .unavailable }
    var shouldShowRetry: Bool { connectionState != .connected }

    func refreshNow() {
        Task { await refresh() }
    }

    func selectExecutable(_ url: URL) {
        defaults.set(url.standardizedFileURL.path, forKey: "codexExecutablePath")
        restart()
    }

    func restart() {
        lifecycleTask?.cancel()
        notificationTask?.cancel()
        Task { await client?.shutdown() }
        client = nil
        connectionState = .starting
        start()
    }

    func shutdownSynchronously() {
        lifecycleTask?.cancel()
        notificationTask?.cancel()
        let currentClient = client
        client = nil
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await currentClient?.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private func start() {
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle()
        }
    }

    private func runLifecycle() async {
        let backoff: [UInt64] = [1, 2, 5, 10, 30]
        var attempt = 0
        while !Task.isCancelled {
            guard let executable = resolveExecutable() else {
                connectionState = .unavailable
                return
            }
            let newClient = AppServerClient(executableURL: executable)
            client = newClient
            connectionState = .connecting
            do {
                try await newClient.start()
                connectionState = .connected
                await refresh(using: newClient)
                attempt = 0
                notificationTask?.cancel()
                notificationTask = Task { [weak self, newClient] in
                    for await notification in newClient.notifications {
                        guard !Task.isCancelled else { return }
                        await self?.handle(notification)
                    }
                }
                let event = await waitForSession(newClient)
                if case .transportFailed(let message) = event {
                    throw AppServerError.protocolError(message)
                }
            } catch AppServerError.notAuthenticated {
                connectionState = .notAuthenticated
                lastError = AppServerError.notAuthenticated.localizedDescription
                await newClient.shutdown()
                return
            } catch {
                if Task.isCancelled { return }
                connectionState = snapshot == nil ? .degraded : .degraded
                lastError = error.localizedDescription
                await newClient.shutdown()
                let seconds = backoff[min(attempt, backoff.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func waitForSession(_ client: AppServerClient) async -> ClientEvent {
        await withTaskGroup(of: ClientEvent.self) { group in
            group.addTask {
                for await event in client.events { return event }
                return .stopped
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { return .stopped }
                    await self?.refresh(using: client)
                }
                return .stopped
            }
            let event = await group.next() ?? .stopped
            group.cancelAll()
            return event
        }
    }

    private func refresh() async {
        guard let client else { return }
        await refresh(using: client)
    }

    private func refresh(using client: AppServerClient) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let account = try await client.readAccount()
            if account.account == nil && account.requiresOpenaiAuth { throw AppServerError.notAuthenticated }
            let raw = try await client.readRateLimits()
            guard let normalized = RateLimitNormalizer.normalize(raw) else {
                connectionState = .degraded
                lastError = "No usable Codex rate-limit window was returned."
                return
            }
            snapshot = normalized
            connectionState = .connected
            lastError = nil
        } catch AppServerError.notAuthenticated {
            connectionState = .notAuthenticated
            lastError = AppServerError.notAuthenticated.localizedDescription
        } catch {
            connectionState = .degraded
            lastError = error.localizedDescription
        }
    }

    private func handle(_ notification: ServerNotification) async {
        if case .rateLimitsUpdated = notification {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await refresh()
    }

    private func resolveExecutable() -> URL? {
        var candidates: [String] = []
        if let stored = defaults.string(forKey: "codexExecutablePath") { candidates.append(stored) }
        let path = ProcessInfo.processInfo.environment["PATH", default: ""]
        candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex"]
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
