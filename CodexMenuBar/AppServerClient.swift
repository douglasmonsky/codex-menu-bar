import Foundation
import os

enum ServerNotification: Sendable {
    case rateLimitsUpdated
    case accountUpdated
}

enum ClientEvent: Sendable {
    case transportFailed(String)
    case stopped
}

enum AppServerError: LocalizedError, Sendable {
    case notRunning
    case timedOut(String)
    case protocolError(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Codex App Server is not running."
        case .timedOut(let method): return "Timed out waiting for \(method)."
        case .protocolError(let message): return message
        case .notAuthenticated: return "Codex is not signed in for ChatGPT usage."
        }
    }
}

actor AppServerClient {
    nonisolated let notifications: AsyncStream<ServerNotification>
    nonisolated let events: AsyncStream<ClientEvent>

    private let executableURL: URL
    private let logger = Logger(subsystem: "com.codex.menubar", category: "protocol")
    private var notificationContinuation: AsyncStream<ServerNotification>.Continuation?
    private var eventContinuation: AsyncStream<ClientEvent>.Continuation?
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextRequestID = 0
    private var framer = JSONLineFramer()
    private var malformedLines = 0

    init(executableURL: URL) {
        self.executableURL = executableURL
        var notificationContinuation: AsyncStream<ServerNotification>.Continuation?
        self.notifications = AsyncStream { notificationContinuation = $0 }
        self.notificationContinuation = notificationContinuation
        var eventContinuation: AsyncStream<ClientEvent>.Continuation?
        self.events = AsyncStream { eventContinuation = $0 }
        self.eventContinuation = eventContinuation
    }

    func start() async throws {
        guard process == nil else { return }
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task { await self?.processTerminated(status: process.terminationStatus) }
        }
        try process.run()
        self.process = process
        input = (process.standardInput as? Pipe)?.fileHandleForWriting
        startReader(stdout.fileHandleForReading, isError: false)
        startReader(stderr.fileHandleForReading, isError: true)
        logger.debug("Started app-server pid=\(process.processIdentifier)")

        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "codex_menu_bar", "title": "Codex Menu Bar", "version": "0.1.0"]]
        )
        try send(method: "initialized", params: [:], id: nil)
    }

    func readAccount() async throws -> AccountReadResponse {
        let data = try await request(method: "account/read", params: ["refreshToken": false])
        return try JSONDecoder().decode(AccountReadResponse.self, from: data)
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        let data = try await request(method: "account/rateLimits/read", params: nil)
        return try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
    }

    func shutdown() {
        notificationContinuation?.finish()
        eventContinuation?.yield(.stopped)
        eventContinuation?.finish()
        for continuation in pending.values { continuation.resume(throwing: AppServerError.notRunning) }
        pending.removeAll()
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
    }

    private func request(method: String, params: [String: Any]?) async throws -> Data {
        guard process?.isRunning == true else { throw AppServerError.notRunning }
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(method: method, params: params, id: id)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self?.timeout(requestID: id, method: method)
            }
        }
    }

    private func timeout(requestID: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: AppServerError.timedOut(method))
    }

    private func send(method: String, params: [String: Any]?, id: Int?) throws {
        var object: [String: Any] = ["method": method]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw AppServerError.notRunning }
        try input.write(contentsOf: data + Data([0x0A]))
    }

    private func startReader(_ handle: FileHandle, isError: Bool) {
        Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let data = try handle.read(upToCount: 4096), !data.isEmpty else {
                        if !isError { await self?.transportFailed("stdout closed") }
                        return
                    }
                    if isError { continue }
                    await self?.receive(data)
                }
            } catch {
                if !isError { await self?.transportFailed("stdout read failed") }
            }
        }
    }

    private func receive(_ data: Data) {
        do {
            for line in try framer.append(data) { receiveLine(line) }
        } catch {
            transportFailed("stdout framing failed")
        }
    }

    private func receiveLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            malformedLines += 1
            logger.error("Malformed protocol line")
            if malformedLines >= 3 { transportFailed("too many malformed protocol lines") }
            return
        }
        malformedLines = 0
        if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                continuation.resume(throwing: AppServerError.protocolError(message))
            } else {
                continuation.resume(returning: line)
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        if let id = object["id"] as? Int {
            try? sendUnsupportedResponse(id: id)
            logger.debug("Ignored unsupported server request method=\(method, privacy: .public)")
        } else if method == "account/rateLimits/updated" {
            notificationContinuation?.yield(.rateLimitsUpdated)
        } else if method == "account/updated" {
            notificationContinuation?.yield(.accountUpdated)
        }
    }

    private func sendUnsupportedResponse(id: Int) throws {
        let object: [String: Any] = ["id": id, "error": ["code": -32601, "message": "Method not supported"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        try input?.write(contentsOf: data + Data([0x0A]))
    }

    private func processTerminated(status: Int32) {
        guard process != nil else { return }
        transportFailed("app-server exited (\(status))")
    }

    private func transportFailed(_ message: String) {
        guard process != nil else { return }
        for continuation in pending.values { continuation.resume(throwing: AppServerError.protocolError(message)) }
        pending.removeAll()
        eventContinuation?.yield(.transportFailed(message))
        process = nil
    }
}

struct AccountReadResponse: Decodable, Sendable {
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool
}

struct AccountInfo: Decodable, Sendable {
    let type: String
}
