//
//  IMessageRPCClient.swift
//  osaurus
//
//  Local JSON-RPC transport over the pinned `imsg rpc` helper.
//
//  The helper is a long-lived child process that speaks newline-framed
//  JSON-RPC 2.0 on stdin/stdout. This actor owns the `Process`, matches
//  responses to requests by id, enforces per-call timeouts, isolates stderr,
//  routes helper-initiated notifications (watch subscriptions), and kills a
//  wedged process on timeout so the next call gets a fresh helper. Restart
//  backoff and watch resubscription live in the receive runtime, which owns
//  the persisted cursor. All diagnostics are path/secret redacted before
//  they leave the actor.
//
//  Everything the connection service needs goes through `IMessageRPCTransport`
//  so tests can inject a fake transport without spawning a process.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Errors

enum IMessageRPCError: LocalizedError, Equatable, Sendable {
    case helperUnavailable(String)
    case helperUnverified(String)
    case spawnFailed(String)
    case notRunning
    case timeout(method: String)
    case decodeFailed(String)
    case rpc(code: Int, message: String)
    case capabilityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let detail):
            return "The iMessage helper is unavailable: \(detail)"
        case .helperUnverified(let detail):
            return "The iMessage helper failed integrity verification: \(detail)"
        case .spawnFailed(let detail):
            return "Could not launch the iMessage helper: \(detail)"
        case .notRunning:
            return "The iMessage helper is not running."
        case .timeout(let method):
            return "The iMessage helper did not respond to `\(method)` in time."
        case .decodeFailed(let detail):
            return "The iMessage helper returned an unreadable response: \(detail)"
        case .rpc(let code, let message):
            return "iMessage helper error \(code): \(message)"
        case .capabilityUnavailable(let capability):
            return "The iMessage helper does not expose `\(capability)`. This capability needs the private-API bridge (SIP + Library Validation disabled)."
        }
    }
}

// MARK: - Response value

/// A decoded JSON-RPC `result` object. Wraps the raw dictionary so the
/// connection service can pull typed fields without re-parsing.
struct IMessageRPCResponse: Sendable {
    /// JSON-encoded result payload; decoded lazily by callers that need a
    /// dictionary so we never move a non-Sendable `[String: Any]` across the
    /// actor boundary.
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

// MARK: - Capabilities

/// Result of `imsg status --json` (a one-shot CLI probe — the RPC server has
/// no `status` method and won't even start without Full Disk Access, so this
/// is the only capability signal available before permissions are granted).
///
/// Real schema (see `StatusCommand`/`StatusPayload` in the pinned imsg
/// release): `version`, `basic_features`, `advanced_features`,
/// `typing_indicators`, `read_receipts`, `sip`, `message`, `bridge_version`,
/// `v2_ready`, `selectors`, `rpc_methods`. Note: imsg does NOT expose
/// Messages sign-in state anywhere; callers must treat it as unknown.
struct IMessageCapabilities: Equatable, Sendable {
    var helperVersion: String?
    /// `advanced_features`: the private-API bridge is injected and reachable.
    var bridgeAvailable: Bool
    /// `rpc_methods`: the full JSON-RPC surface of the installed binary.
    /// Bridge-only methods are listed even when the bridge is inactive, so
    /// advanced gating is `bridgeAvailable && contains(method)`.
    var rpcMethods: Set<String>
    /// `sip`: "enabled" / "disabled" / "unknown" as reported by the helper.
    var sipStatus: String?
    /// True when a probe actually completed (distinguishes "helper answered
    /// with no advanced features" from "probe failed/unavailable").
    var probed: Bool

    static let empty = IMessageCapabilities(
        helperVersion: nil,
        bridgeAvailable: false,
        rpcMethods: [],
        sipStatus: nil,
        probed: false
    )

    func supportsAdvanced(_ method: String) -> Bool {
        bridgeAvailable && rpcMethods.contains(method)
    }

    var dictionary: [String: Any] {
        [
            "helper_version": helperVersion ?? "",
            "bridge_available": bridgeAvailable,
            "rpc_methods": rpcMethods.sorted(),
            "sip": sipStatus ?? "unknown",
            "probed": probed,
        ]
    }

    /// Parse one `imsg status --json` line. Pure and unit-tested against a
    /// live-captured payload.
    static func parse(statusJSON data: Data) -> IMessageCapabilities? {
        guard
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // `version` is the one key every release of the schema carries.
        guard let version = object["version"] as? String, !version.isEmpty else { return nil }
        let methods = (object["rpc_methods"] as? [String]).map(Set.init) ?? []
        return IMessageCapabilities(
            helperVersion: version,
            bridgeAvailable: (object["advanced_features"] as? Bool) ?? false,
            rpcMethods: methods,
            sipStatus: object["sip"] as? String,
            probed: true
        )
    }
}

// MARK: - Notifications

/// Helper-initiated JSON-RPC notification method names (no `id`). `message`
/// and `error` come from live `watch.subscribe` sessions; `helperTerminated`
/// is synthesized locally when the child process exits so a stream consumer
/// can end its session and resubscribe from the persisted cursor.
enum IMessageRPCNotification {
    static let message = "message"
    static let error = "error"
    static let helperTerminated = "__helper_terminated__"
}

// MARK: - Transport protocol

protocol IMessageRPCTransport: Sendable {
    /// Perform one JSON-RPC call. `params` values must be JSON-serializable
    /// (String / Int / Bool / arrays thereof); the type is `any Sendable`
    /// so calls can cross the actor boundary of the process client.
    func call(method: String, params: [String: any Sendable], timeout: TimeInterval) async throws
        -> IMessageRPCResponse
    /// Probe helper status/capabilities. Never throws for a merely-missing
    /// bridge — that is reported through `IMessageCapabilities`.
    func probeCapabilities() async -> IMessageCapabilities
    /// Whether a helper is present and verified enough to spawn at all.
    func isHelperAvailable() -> Bool
    /// Route helper-initiated notifications (watch events) to `handler`.
    /// The handler receives the method name and the raw params JSON; pass
    /// nil to stop receiving. Exactly one consumer at a time — the receive
    /// runtime owns the subscription.
    func setNotificationHandler(
        _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
    ) async
    func shutdown() async
}

extension IMessageRPCTransport {
    func call(method: String, params: [String: any Sendable] = [:]) async throws -> IMessageRPCResponse {
        try await call(method: method, params: params, timeout: 15)
    }
}

// MARK: - Framing (pure, testable)

enum IMessageRPCFraming {
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

    /// Parse one JSON-RPC response line. Notifications (no id) parse with a
    /// nil id; the reader routes those through `parseNotificationLine`.
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

    /// Parse one helper-initiated notification line: a JSON-RPC message with
    /// a `method` and no `id` (e.g. watch subscription events).
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

enum IMessageRPCSecurity {
    /// Redact absolute home-relative paths from diagnostics so a helper error
    /// never leaks the user's file layout to model/user-visible surfaces.
    static func redact(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

#if os(macOS)

    // MARK: - Process-backed client

    /// Long-lived `imsg rpc` child process speaking newline-framed JSON-RPC.
    actor IMessageProcessRPCClient: IMessageRPCTransport {
        private struct PendingCall {
            let continuation: CheckedContinuation<IMessageRPCResponse, Error>
            var timeoutTask: Task<Void, Never>?
        }

        private var process: Process?
        private var stdinHandle: FileHandle?
        private var nextRequestId = 1
        private var pending: [Int: PendingCall] = [:]
        private var readBuffer = Data()
        private var notificationHandler: (@Sendable (String, Data) -> Void)?
        /// Cap on buffered, un-newline-terminated helper output. A helper
        /// that streams garbage without frame boundaries is wedged; kill it
        /// instead of growing the buffer without bound.
        private static let maxReadBufferBytes = 4 * 1024 * 1024

        func setNotificationHandler(
            _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
        ) {
            notificationHandler = handler
        }

        nonisolated func isHelperAvailable() -> Bool {
            switch IMessageRuntimeAssets.verifyBundledExecutable() {
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
        ) async throws -> IMessageRPCResponse {
            try await ensureRunning()
            guard let stdinHandle else { throw IMessageRPCError.notRunning }
            let id = nextRequestId
            nextRequestId += 1
            let frame = try IMessageRPCFraming.encodeRequest(id: id, method: method, params: params)

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
                        with: .failure(IMessageRPCError.spawnFailed(error.localizedDescription))
                    )
                }
            }
        }

        /// One-shot `imsg status --json`. Runs the CLI subcommand rather than
        /// JSON-RPC: the RPC server has no `status` method, and spawning
        /// `imsg rpc` requires Full Disk Access (it opens chat.db at startup)
        /// while the CLI status probe does not — so capabilities stay
        /// reportable before permissions are granted.
        func probeCapabilities() async -> IMessageCapabilities {
            guard case let verification = IMessageRuntimeAssets.verifyBundledExecutable(),
                let executable = verification.trustedURL
            else { return .empty }
            return await Self.runStatusProbe(executable: executable)
        }

        private static func runStatusProbe(executable: URL) async -> IMessageCapabilities {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = ["status", "--json"]
                    let stdout = Pipe()
                    process.standardOutput = stdout
                    process.standardError = Pipe()
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: .empty)
                        return
                    }
                    // The probe is local and fast; anything hung past 10s is
                    // killed so a wedged helper can't stall diagnostics.
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
                        let capabilities = IMessageCapabilities.parse(statusJSON: data)
                    else {
                        continuation.resume(returning: .empty)
                        return
                    }
                    continuation.resume(returning: capabilities)
                }
            }
        }

        func shutdown() async {
            let running = process
            process = nil
            try? stdinHandle?.close()
            stdinHandle = nil
            failAllPending(with: IMessageRPCError.notRunning)
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
            let verification = IMessageRuntimeAssets.verifyBundledExecutable()
            guard let executableURL = verification.trustedURL else {
                switch verification {
                case .missing:
                    throw IMessageRPCError.helperUnavailable(
                        "no imsg helper is installed — download it from iMessage settings")
                case .unpinned:
                    throw IMessageRPCError.helperUnverified("release digests are not pinned")
                case .digestMismatch(let expected, let actual):
                    throw IMessageRPCError.helperUnverified(
                        "digest mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
                    )
                case .verified, .overridden:
                    throw IMessageRPCError.helperUnavailable("unexpected verification state")
                }
            }
            // Re-verify the bridge dylib at every spawn (skipped for the dev
            // override, whose locally-built dylib matches no pin). The
            // downloaded install is user-writable, so install-time checks
            // alone would not catch a dylib swapped after installation.
            if case .verified = verification,
                case .mismatch = IMessageRuntimeAssets.verifyBridgeDylib(nextTo: executableURL)
            {
                throw IMessageRPCError.helperUnverified(
                    "the bridge dylib next to the helper failed integrity verification"
                )
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["rpc"]
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            // Drain and discard stderr: a chatty helper must never block on a
            // full pipe, and its stderr may contain user paths that must not
            // reach model/user-visible surfaces.
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
                throw IMessageRPCError.spawnFailed(error.localizedDescription)
            }
            self.process = process
            self.stdinHandle = stdin.fileHandleForWriting
        }

        private func handleTermination() {
            process = nil
            try? stdinHandle?.close()
            stdinHandle = nil
            readBuffer.removeAll()
            failAllPending(with: IMessageRPCError.notRunning)
            // Tell the watch consumer its session died so it can resubscribe
            // from the persisted cursor (backfill makes the restart lossless).
            notificationHandler?(IMessageRPCNotification.helperTerminated, Data("{}".utf8))
        }

        // MARK: - Reader

        private func ingest(_ data: Data) {
            readBuffer.append(data)
            while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[readBuffer.startIndex ..< newlineIndex]
                readBuffer.removeSubrange(readBuffer.startIndex ... newlineIndex)
                guard !line.isEmpty else { continue }
                guard let parsed = IMessageRPCFraming.parseResponseLine(Data(line)),
                    let id = parsed.id
                else {
                    if let notification = IMessageRPCFraming.parseNotificationLine(Data(line)) {
                        notificationHandler?(notification.method, notification.paramsJSON)
                    }
                    continue
                }
                if let code = parsed.errorCode {
                    resolve(
                        id: id,
                        with: .failure(
                            IMessageRPCError.rpc(
                                code: code,
                                message: IMessageRPCSecurity.redact(parsed.errorMessage ?? "error")
                            )
                        )
                    )
                } else {
                    resolve(
                        id: id,
                        with: .success(
                            IMessageRPCResponse(resultJSON: parsed.resultJSON ?? Data("{}".utf8))
                        )
                    )
                }
            }
            if readBuffer.count > Self.maxReadBufferBytes {
                Task { await self.killWedgedProcess() }
            }
        }

        /// Resolve exactly one pending call, cancelling its timeout watchdog.
        private func resolve(id: Int, with result: Result<IMessageRPCResponse, Error>) {
            guard let call = pending.removeValue(forKey: id) else { return }
            call.timeoutTask?.cancel()
            call.continuation.resume(with: result)
        }

        private func resolveTimeout(id: Int, method: String) async {
            guard let call = pending.removeValue(forKey: id) else { return }
            call.timeoutTask?.cancel()
            call.continuation.resume(throwing: IMessageRPCError.timeout(method: method))
            // The helper answers strictly sequentially: a request that missed
            // its deadline is still occupying the process, and every queued
            // call behind it would time out too. Kill the process so the next
            // call gets a fresh helper instead of a permanently wedged one.
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
