//
//  WhatsAppRPCClient.swift
//  osaurus
//
//  Local JSON-RPC transport over the `osaurus-wa rpc` helper (the whatsmeow
//  WhatsApp Web bridge).
//
//  The helper is a long-lived child process that speaks newline-framed
//  JSON-RPC 2.0 on stdin/stdout, exactly like the pinned `imsg` helper. This
//  actor owns the `Process`, matches responses to requests by id, enforces
//  per-call timeouts, isolates stderr, routes helper-initiated notifications
//  (watch messages, rotating QR codes, login results), and kills a wedged
//  process on timeout so the next call gets a fresh helper. Restart backoff
//  and watch resubscription live in the receive runtime.
//
//  Everything the connection service needs goes through `WhatsAppRPCTransport`
//  so tests can inject a fake transport without spawning a process.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Errors

enum WhatsAppRPCError: LocalizedError, Equatable, Sendable {
    case helperUnavailable(String)
    case helperUnverified(String)
    case spawnFailed(String)
    case notRunning
    case timeout(method: String)
    case decodeFailed(String)
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let detail):
            return "The WhatsApp helper is unavailable: \(detail)"
        case .helperUnverified(let detail):
            return "The WhatsApp helper failed integrity verification: \(detail)"
        case .spawnFailed(let detail):
            return "Could not launch the WhatsApp helper: \(detail)"
        case .notRunning:
            return "The WhatsApp helper is not running."
        case .timeout(let method):
            return "The WhatsApp helper did not respond to `\(method)` in time."
        case .decodeFailed(let detail):
            return "The WhatsApp helper returned an unreadable response: \(detail)"
        case .rpc(let code, let message):
            return "WhatsApp helper error \(code): \(message)"
        }
    }
}

// MARK: - Response value

/// A decoded JSON-RPC `result` object. Wraps the raw payload so the
/// connection service can pull typed fields without re-parsing.
struct WhatsAppRPCResponse: Sendable {
    let resultJSON: Data

    func object() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: resultJSON)) as? [String: Any] ?? [:]
    }

    func array(_ key: String) -> [[String: Any]] {
        object()[key] as? [[String: Any]] ?? []
    }

    func string(_ key: String) -> String? {
        object()[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        object()[key] as? Bool
    }
}

// MARK: - Link status

/// Result of `osaurus-wa status --json` (one-shot CLI probe that never
/// connects to WhatsApp — it only inspects the local session store), or of
/// the RPC `status` method on a running helper.
struct WhatsAppLinkStatus: Equatable, Sendable {
    var helperVersion: String?
    /// A device session exists in the local store (QR pairing completed and
    /// not logged out).
    var linked: Bool
    /// Own JID (`<phone>.<agent>:<device>@s.whatsapp.net`) when linked.
    var selfJID: String?
    /// Own phone number in `+E.164` form when linked.
    var selfNumber: String?
    var rpcMethods: Set<String>
    /// True when a probe actually completed.
    var probed: Bool

    static let empty = WhatsAppLinkStatus(
        helperVersion: nil,
        linked: false,
        selfJID: nil,
        selfNumber: nil,
        rpcMethods: [],
        probed: false
    )

    var dictionary: [String: Any] {
        [
            "helper_version": helperVersion ?? "",
            "linked": linked,
            "self_jid": selfJID ?? "",
            "self_number": selfNumber ?? "",
            "rpc_methods": rpcMethods.sorted(),
            "probed": probed,
        ]
    }

    /// Parse one `status --json` line (or RPC `status` result).
    static func parse(statusJSON data: Data) -> WhatsAppLinkStatus? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let version = object["version"] as? String, !version.isEmpty else { return nil }
        let methods = (object["rpc_methods"] as? [String]).map(Set.init) ?? []
        let selfJID = (object["self_jid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let selfNumber = (object["self_number"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WhatsAppLinkStatus(
            helperVersion: version,
            linked: (object["linked"] as? Bool) ?? false,
            selfJID: selfJID,
            selfNumber: selfNumber,
            rpcMethods: methods,
            probed: true
        )
    }
}

// MARK: - Notifications

/// Helper-initiated JSON-RPC notification method names (no `id`).
/// `helperTerminated` is synthesized locally when the child process exits so
/// stream consumers can end their sessions and resubscribe.
enum WhatsAppRPCNotification {
    /// One inbound message from a live `watch.subscribe` session.
    static let message = "message"
    /// Rotating QR pairing code (`code`, `timeout_ms`) during `login.start`.
    static let qr = "qr"
    /// Passkey linking gate progress during `login.start`
    /// (`stage`: challenge / confirm). Non-terminal.
    static let passkey = "passkey"
    /// Terminal pairing result (`status`: success / timeout / error).
    static let login = "login"
    /// Connection state changes (`state`: connected / disconnected).
    static let status = "status"
    /// Fatal stream error (e.g. the phone unlinked this device).
    static let error = "error"
    static let helperTerminated = "__helper_terminated__"
}

// MARK: - Transport protocol

protocol WhatsAppRPCTransport: Sendable {
    /// Perform one JSON-RPC call. `params` values must be JSON-serializable.
    func call(method: String, params: [String: any Sendable], timeout: TimeInterval) async throws
        -> WhatsAppRPCResponse
    /// Probe link status without holding a long-lived helper. Never throws;
    /// failure is reported as `.empty` (probed == false).
    func probeLinkStatus() async -> WhatsAppLinkStatus
    /// Whether a helper is present and verified enough to spawn at all.
    func isHelperAvailable() -> Bool
    /// Route helper-initiated notifications to `handler`; nil to stop.
    /// Exactly one consumer at a time — the connection service owns the
    /// subscription and demultiplexes by method.
    func setNotificationHandler(
        _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
    ) async
    func shutdown() async
}

extension WhatsAppRPCTransport {
    func call(method: String, params: [String: any Sendable] = [:]) async throws -> WhatsAppRPCResponse {
        try await call(method: method, params: params, timeout: 15)
    }
}

// MARK: - Framing (pure, testable)

enum WhatsAppRPCFraming {
    /// Encode a JSON-RPC 2.0 request as a single newline-terminated line.
    static func encodeRequest(id: Int, method: String, params: [String: Any]) throws -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if !params.isEmpty {
            payload["params"] = params
        }
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0A)  // newline frame
        return data
    }

    struct ParsedResponse: Equatable {
        var id: Int?
        var resultJSON: Data?
        var errorCode: Int?
        var errorMessage: String?
    }

    static func parseResponseLine(_ line: Data) -> ParsedResponse? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return nil }
        let id = object["id"] as? Int
        if let error = object["error"] as? [String: Any] {
            return ParsedResponse(
                id: id,
                resultJSON: nil,
                errorCode: error["code"] as? Int ?? -1,
                errorMessage: error["message"] as? String ?? "unknown error"
            )
        }
        let result = object["result"] ?? [:]
        let resultJSON = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        return ParsedResponse(id: id, resultJSON: resultJSON, errorCode: nil, errorMessage: nil)
    }

    struct ParsedNotification: Equatable {
        var method: String
        var paramsJSON: Data
    }

    static func parseNotificationLine(_ line: Data) -> ParsedNotification? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            object["id"] == nil,
            let method = object["method"] as? String, !method.isEmpty
        else { return nil }
        let params = object["params"] ?? [:]
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        return ParsedNotification(method: method, paramsJSON: paramsJSON)
    }
}

// MARK: - Redaction

enum WhatsAppRPCSecurity {
    /// Redact absolute home-relative paths from diagnostics so a helper
    /// error never leaks the user's file layout.
    static func redact(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

#if os(macOS)

    // MARK: - Process-backed client

    /// Long-lived `osaurus-wa rpc` child process speaking newline-framed
    /// JSON-RPC.
    actor WhatsAppProcessRPCClient: WhatsAppRPCTransport {
        private struct PendingCall {
            let continuation: CheckedContinuation<WhatsAppRPCResponse, Error>
            var timeoutTask: Task<Void, Never>?
        }

        private var process: Process?
        private var stdinHandle: FileHandle?
        private var nextRequestId = 1
        private var pending: [Int: PendingCall] = [:]
        private var readBuffer = Data()
        private var notificationHandler: (@Sendable (String, Data) -> Void)?
        /// Cap on buffered, un-newline-terminated helper output; a helper
        /// streaming garbage without frame boundaries is wedged.
        private static let maxReadBufferBytes = 4 * 1024 * 1024

        func setNotificationHandler(
            _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
        ) {
            notificationHandler = handler
        }

        nonisolated func isHelperAvailable() -> Bool {
            switch WhatsAppRuntimeAssets.verifyExecutable() {
            case .verified, .overridden:
                return true
            case .missing, .digestMismatch, .unpinned:
                return false
            }
        }

        func call(
            method: String,
            params: [String: any Sendable],
            timeout: TimeInterval
        ) async throws -> WhatsAppRPCResponse {
            try await ensureRunning()
            guard let stdinHandle else { throw WhatsAppRPCError.notRunning }
            let id = nextRequestId
            nextRequestId += 1
            let frame = try WhatsAppRPCFraming.encodeRequest(id: id, method: method, params: params)

            return try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    if Task.isCancelled { return }
                    await self?.resolveTimeout(id: id, method: method)
                }
                pending[id] = PendingCall(continuation: continuation, timeoutTask: timeoutTask)
                do {
                    try stdinHandle.write(contentsOf: frame)
                } catch {
                    resolve(
                        id: id,
                        with: .failure(WhatsAppRPCError.spawnFailed(error.localizedDescription))
                    )
                }
            }
        }

        /// One-shot `osaurus-wa status --json`. Runs the CLI subcommand
        /// rather than JSON-RPC so link status stays probeable without
        /// keeping a helper process alive (it only reads the local session
        /// store; it never connects to WhatsApp).
        func probeLinkStatus() async -> WhatsAppLinkStatus {
            guard let executable = WhatsAppRuntimeAssets.verifyExecutable().trustedURL else {
                return .empty
            }
            return await Self.runStatusProbe(executable: executable)
        }

        private static func runStatusProbe(executable: URL) async -> WhatsAppLinkStatus {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = [
                        "status", "--json",
                        "--store-dir", WhatsAppRuntimeAssets.sessionStoreDirectoryURL().path,
                    ]
                    let stdout = Pipe()
                    process.standardOutput = stdout
                    process.standardError = Pipe()
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: .empty)
                        return
                    }
                    // The probe is local and fast; kill anything hung past 10s.
                    let watchdog = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + 10, execute: watchdog
                    )
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    watchdog.cancel()
                    guard process.terminationStatus == 0,
                        let status = WhatsAppLinkStatus.parse(statusJSON: data)
                    else {
                        continuation.resume(returning: .empty)
                        return
                    }
                    continuation.resume(returning: status)
                }
            }
        }

        func shutdown() async {
            let running = process
            process = nil
            try? stdinHandle?.close()
            stdinHandle = nil
            failAllPending(with: WhatsAppRPCError.notRunning)
            if let running, running.isRunning {
                running.terminate()
                let deadline = Date().addingTimeInterval(2)
                while running.isRunning && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if running.isRunning {
                    kill(running.processIdentifier, SIGKILL)
                }
            }
        }

        // MARK: - Lifecycle

        private func ensureRunning() async throws {
            if let process, process.isRunning { return }
            let verification = WhatsAppRuntimeAssets.verifyExecutable()
            guard let executableURL = verification.trustedURL else {
                switch verification {
                case .missing:
                    throw WhatsAppRPCError.helperUnavailable(
                        "no osaurus-wa helper is installed — download it in WhatsApp settings, or build it with `make wa-helper` and set OSAURUS_WA_PATH (DEBUG)")
                case .unpinned:
                    throw WhatsAppRPCError.helperUnverified("release digests are not pinned")
                case .digestMismatch(let expected, let actual):
                    throw WhatsAppRPCError.helperUnverified(
                        "digest mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
                    )
                case .verified, .overridden:
                    throw WhatsAppRPCError.helperUnavailable("unexpected verification state")
                }
            }

            let storeDir = WhatsAppRuntimeAssets.sessionStoreDirectoryURL()
            OsaurusPaths.ensureExistsSilent(storeDir)

            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["rpc", "--store-dir", storeDir.path]
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            // Drain and discard stderr: a chatty helper must never block on
            // a full pipe, and stderr may contain user paths.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                Task { await self?.ingest(data) }
            }
            process.terminationHandler = { [weak self] _ in
                Task { await self?.handleTermination() }
            }

            do {
                try process.run()
            } catch {
                throw WhatsAppRPCError.spawnFailed(error.localizedDescription)
            }
            self.process = process
            self.stdinHandle = stdin.fileHandleForWriting
        }

        private func handleTermination() {
            process = nil
            try? stdinHandle?.close()
            stdinHandle = nil
            readBuffer.removeAll()
            failAllPending(with: WhatsAppRPCError.notRunning)
            // Tell stream consumers their session died so they can
            // resubscribe against a fresh helper.
            notificationHandler?(WhatsAppRPCNotification.helperTerminated, Data("{}".utf8))
        }

        // MARK: - Reader

        private func ingest(_ data: Data) {
            readBuffer.append(data)
            while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[readBuffer.startIndex ..< newlineIndex]
                readBuffer.removeSubrange(readBuffer.startIndex ... newlineIndex)
                guard !line.isEmpty else { continue }
                guard let parsed = WhatsAppRPCFraming.parseResponseLine(Data(line)),
                    let id = parsed.id
                else {
                    if let notification = WhatsAppRPCFraming.parseNotificationLine(Data(line)) {
                        notificationHandler?(notification.method, notification.paramsJSON)
                    }
                    continue
                }
                if let code = parsed.errorCode {
                    resolve(
                        id: id,
                        with: .failure(
                            WhatsAppRPCError.rpc(
                                code: code,
                                message: WhatsAppRPCSecurity.redact(parsed.errorMessage ?? "error")
                            )
                        )
                    )
                } else {
                    resolve(
                        id: id,
                        with: .success(
                            WhatsAppRPCResponse(resultJSON: parsed.resultJSON ?? Data("{}".utf8))
                        )
                    )
                }
            }
            if readBuffer.count > Self.maxReadBufferBytes {
                Task { await self.killWedgedProcess() }
            }
        }

        private func resolve(id: Int, with result: Result<WhatsAppRPCResponse, Error>) {
            guard let call = pending.removeValue(forKey: id) else { return }
            call.timeoutTask?.cancel()
            call.continuation.resume(with: result)
        }

        private func resolveTimeout(id: Int, method: String) async {
            guard let call = pending.removeValue(forKey: id) else { return }
            call.timeoutTask?.cancel()
            call.continuation.resume(throwing: WhatsAppRPCError.timeout(method: method))
            // A request past its deadline is still occupying the helper;
            // kill the process so the next call gets a fresh one.
            await killWedgedProcess()
        }

        private func killWedgedProcess() async {
            guard process != nil else { return }
            await shutdown()
        }

        private func failAllPending(with error: Error) {
            let calls = pending
            pending.removeAll()
            for (_, call) in calls {
                call.timeoutTask?.cancel()
                call.continuation.resume(throwing: error)
            }
        }
    }

#endif

#if !os(macOS)
    /// Non-macOS placeholder so the package still compiles; WhatsApp is a
    /// macOS-only channel.
    struct WhatsAppUnavailableTransport: WhatsAppRPCTransport {
        func call(method: String, params: [String: any Sendable], timeout: TimeInterval) async throws
            -> WhatsAppRPCResponse
        {
            throw WhatsAppRPCError.helperUnavailable("WhatsApp is only available on macOS")
        }
        func probeLinkStatus() async -> WhatsAppLinkStatus { .empty }
        func isHelperAvailable() -> Bool { false }
        func setNotificationHandler(
            _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
        ) async {}
        func shutdown() async {}
    }
#endif
