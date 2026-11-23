//
//  CodeNodeExecutor.swift
//  osaurus
//
//  Parent side of workflow code nodes. Each run launches a fresh
//  `osaurus-js-host` under a deny-default Seatbelt profile (no network, no
//  file writes, reads limited to system frameworks), feeds it the source
//  and input, and serves its two reverse calls:
//    - `fetch`  only to hosts on the node's allowlist, over HTTPS, through
//               an ephemeral session (no cookies, no cache) that re-checks
//               every redirect hop and caps the body at 4 MB;
//    - `secret` only for keys the node declares, resolved through Keys
//      (`WorkflowCredentials`).
//  The process is killed when the node timeout elapses or its physical
//  footprint passes the node memory limit. A fresh process per run means
//  no state leaks between runs and a kill never strands anything.
//

import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "workflow.code")

public enum JSHostLocator {
    public static let executableName = "osaurus-js-host"

    /// Env override (tests, dev), the app's Helpers directory (release),
    /// then next to the running executable (SwiftPM build layouts).
    public static func executableURL() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["OSAURUS_JS_HOST_PATH"],
            fm.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(executableName)")
        if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        let siblings = [Bundle.main.executableURL, Bundle(for: BundleToken.self).executableURL]
            .compactMap { $0?.deletingLastPathComponent() }
            + [Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()]
        for dir in siblings {
            let candidate = dir.appendingPathComponent(executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private final class BundleToken {}
}

public enum CodeNodeError: Error, LocalizedError, Equatable {
    case runtimeMissing
    case launchFailed(String)
    case timedOut(seconds: Int)
    case memoryLimit(mb: Int)
    case scriptError(message: String, stack: String)
    case crashed(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "The JavaScript runtime helper (osaurus-js-host) is missing from this build."
        case .launchFailed(let reason):
            return "Could not start the code runtime: \(reason)"
        case .timedOut(let seconds):
            return "The code ran longer than its \(seconds)s timeout and was stopped."
        case .memoryLimit(let mb):
            return "The code used more than its \(mb) MB memory limit and was stopped."
        case .scriptError(let message, _):
            return message
        case .crashed(let reason):
            return "The code runtime exited unexpectedly: \(reason)"
        }
    }
}

public struct CodeNodeResult: Sendable {
    public let output: JSONValue
    public let logs: [String]
    public let fetches: [String]
}

/// What a code node may touch, resolved before launch.
public struct CodeNodeGrants: Sendable {
    public var allowedHosts: Set<String>
    /// Declared key → value. Undeclared keys are refused even if present.
    public var secrets: [String: String]
    /// The run workspace. File handles are names relative to it.
    public var workspace: URL?

    public init(allowedHosts: Set<String>, secrets: [String: String], workspace: URL? = nil) {
        self.allowedHosts = allowedHosts
        self.secrets = secrets
        self.workspace = workspace
    }
}

/// What `ctx.fetch` hands back to the script.
public struct CodeNodeFetchResponse: Sendable, Equatable {
    public var status: Int
    /// Lowercased header names.
    public var headers: [String: String]
    public var body: String
    /// The body was cut at `CodeNodeExecutor.maxResponseBytes`.
    public var truncated: Bool

    public init(status: Int, headers: [String: String], body: String, truncated: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.truncated = truncated
    }
}

/// Performs an allowlisted request. Injectable so tests need no network.
public typealias CodeNodeFetcher = @Sendable (URLRequest) async throws -> CodeNodeFetchResponse

public enum CodeNodeFetchError: Error, LocalizedError, Equatable {
    /// A redirect left the node's allowlist (or HTTPS).
    case redirectRefused(host: String)

    public var errorDescription: String? {
        switch self {
        case .redirectRefused(let host):
            return "The server redirected to \(host), which is not on this node's network allowlist (HTTPS only)."
        }
    }
}

public enum CodeNodeExecutor {

    static let maxResponseBytes = 4 * 1024 * 1024
    public static let defaultMemoryLimitMB = 256
    static let pollInterval: UInt64 = 100_000_000

    /// The live fetcher for a node: an ephemeral session with no cookie jar
    /// or cache, every redirect hop re-checked against the allowlist (script
    /// headers dropped when the hop changes host), and the body read in a
    /// stream that stops at `maxResponseBytes`.
    public static func makeFetcher(
        allowedHosts: Set<String>, configuration: URLSessionConfiguration = .ephemeral
    ) -> CodeNodeFetcher {
        let hosts = Set(allowedHosts.map { $0.lowercased() })
        return { request in
            // swiftlint:disable:next force_cast
            let config = configuration.copy() as! URLSessionConfiguration
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let delegate = RedirectGuard(allowedHosts: hosts)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            let (bytes, response) = try await session.bytes(for: request)
            var data = Data()
            var truncated = false
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxResponseBytes {
                    truncated = true
                    bytes.task.cancel()
                    break
                }
            }
            if let refused = delegate.refusedHost {
                throw CodeNodeFetchError.redirectRefused(host: refused)
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return CodeNodeFetchResponse(
                status: http?.statusCode ?? 0, headers: headers,
                body: String(decoding: data, as: UTF8.self), truncated: truncated)
        }
    }

    /// Re-checks each redirect hop. A hop off the allowlist is refused: the
    /// task completes with the redirect response itself and the fetcher
    /// turns that into an error. A hop to another allowed host loses every
    /// header the script set, so credentials never travel across hosts.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let allowedHosts: Set<String>
        private let lock = NSLock()
        private var refused: String?

        init(allowedHosts: Set<String>) { self.allowedHosts = allowedHosts }

        var refusedHost: String? { lock.withLock { refused } }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            switch Self.follow(request, from: task.originalRequest?.url, hosts: allowedHosts) {
            case .continue(let next):
                completionHandler(next)
            case .refuse(let host):
                lock.withLock { refused = host }
                completionHandler(nil)
            }
        }

        enum Hop: Equatable {
            case `continue`(URLRequest)
            case refuse(host: String)
        }

        /// Whether to follow a hop, and with which request.
        static func follow(_ request: URLRequest, from origin: URL?, hosts: Set<String>) -> Hop {
            guard let url = request.url, CodeNodeExecutor.isAllowed(url, hosts: hosts) else {
                return .refuse(host: request.url?.host ?? request.url?.absoluteString ?? "an unknown host")
            }
            if url.host?.lowercased() != origin?.host?.lowercased() {
                var stripped = request
                for name in (request.allHTTPHeaderFields ?? [:]).keys {
                    stripped.setValue(nil, forHTTPHeaderField: name)
                }
                return .continue(stripped)
            }
            return .continue(request)
        }
    }

    /// Seatbelt profile for the helper: deny everything, then allow only
    /// what dyld and JavaScriptCore need to start and run.
    static func profile(helperPath: String) -> String {
        let helper = helperPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
            (version 1)
            (deny default)
            (allow process-exec (literal "\(helper)"))
            (allow process-info* (target self))
            (allow sysctl-read)
            (allow file-read-metadata)
            (allow file-read* (literal "\(helper)")
              (subpath "/usr/lib")
              (subpath "/usr/share")
              (subpath "/System")
              (subpath "/Library/Apple")
              (subpath "/private/var/db/timezone")
              (literal "/")
              (literal "/private")
              (literal "/dev/urandom")
              (literal "/dev/random")
              (literal "/dev/null"))
            (allow file-map-executable (subpath "/usr/lib") (subpath "/System") (literal "\(helper)"))
            (allow file-write-data (literal "/dev/null"))
            (allow dynamic-code-generation)
            (deny network*)
            """
    }

    /// The helper's path with every symlink resolved, as Seatbelt matches
    /// it. `resolvingSymlinksInPath()` strips a leading `/private`, so an
    /// app under `/private/tmp` or a translocated one under `/private/var`
    /// would get a `literal` the exec never matches.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func run(
        source: String,
        input: JSONValue,
        grants: CodeNodeGrants,
        timeout: TimeInterval,
        memoryLimitMB: Int,
        run runInfo: JSONValue = .object([:]),
        caller: JSONValue = .object([:]),
        fetcher: CodeNodeFetcher? = nil
    ) async throws -> CodeNodeResult {
        guard let located = JSHostLocator.executableURL() else {
            throw CodeNodeError.runtimeMissing
        }
        let helper = realPath(located.path)
        let fetcher = fetcher ?? makeFetcher(allowedHosts: grants.allowedHosts)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile(helperPath: helper), helper]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let session = HostSession(
            process: process, stdin: stdin.fileHandleForWriting, grants: grants, fetcher: fetcher)

        do {
            try process.run()
        } catch {
            throw CodeNodeError.launchFailed(error.localizedDescription)
        }

        let initLine: JSONValue = .object([
            "source": .string(source), "input": input, "run": runInfo, "caller": caller,
        ])
        session.send(initLine)

        let reader = Task.detached { () -> Result<JSONValue, CodeNodeError> in
            await session.readUntilDone(stdout.fileHandleForReading)
        }
        let watchdog = Task.detached { () -> CodeNodeError? in
            let started = Date()
            while process.isRunning {
                if Task.isCancelled { return nil }
                if Date().timeIntervalSince(started) > timeout {
                    session.kill()
                    return .timedOut(seconds: timeout.clampedInt())
                }
                if let footprint = physicalFootprintMB(pid: process.processIdentifier), footprint > memoryLimitMB {
                    session.kill()
                    return .memoryLimit(mb: memoryLimitMB)
                }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
            return nil
        }

        let outcome = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            session.kill()
        }
        let watchdogError = await { () async -> CodeNodeError? in
            watchdog.cancel()
            return await watchdog.value
        }()
        if Task.isCancelled { throw CancellationError() }
        if let watchdogError { throw watchdogError }

        switch outcome {
        case .success(let output):
            return CodeNodeResult(output: output, logs: session.logs, fetches: session.fetches)
        case .failure(let error):
            if case .crashed = error {
                let tail = String(decoding: stderr.fileHandleForReading.availableData.suffix(2000), as: UTF8.self)
                if !tail.isEmpty { logger.error("osaurus-js-host stderr: \(tail, privacy: .public)") }
            }
            throw error
        }
    }

    static func physicalFootprintMB(pid: pid_t) -> Int? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return Int(info.ri_phys_footprint / 1_048_576)
    }

    /// A handle is a single path component naming a file in the workspace.
    static func workspaceFile(_ handle: String?, in workspace: URL) -> URL? {
        guard let handle, !handle.isEmpty, !handle.contains("/"), handle != ".", handle != ".." else {
            return nil
        }
        return workspace.appendingPathComponent(handle)
    }

    /// Exact host or a subdomain of an allowlisted host; HTTPS only.
    static func isAllowed(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { allowed in
            let a = allowed.lowercased()
            return host == a || host.hasSuffix("." + a)
        }
    }
}

/// One helper process's conversation. Lines are handled in order on the
/// reader task; writes are serialized by the lock.
private final class HostSession: @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    let grants: CodeNodeGrants
    let fetcher: CodeNodeFetcher
    private let lock = NSLock()
    private(set) var logs: [String] = []
    private(set) var fetches: [String] = []
    private var killed = false

    init(process: Process, stdin: FileHandle, grants: CodeNodeGrants, fetcher: @escaping CodeNodeFetcher) {
        self.process = process
        self.stdin = stdin
        self.grants = grants
        self.fetcher = fetcher
    }

    func send(_ value: JSONValue) {
        lock.lock()
        defer { lock.unlock() }
        guard !killed, process.isRunning else { return }
        var data = Data(value.compactJSONString.utf8)
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    func kill() {
        lock.lock()
        killed = true
        lock.unlock()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        }
    }

    func readUntilDone(_ handle: FileHandle) async -> Result<JSONValue, CodeNodeError> {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                process.waitUntilExit()
                return .failure(.crashed("exit status \(process.terminationStatus)"))
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newline])
                buffer.removeSubrange(buffer.startIndex ... newline)
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line).objectValue else { continue }
                if message["done"] == .bool(true) {
                    if let error = message["error"]?.objectValue {
                        return .failure(
                            .scriptError(
                                message: error["message"]?.stringValue ?? "Error",
                                stack: error["stack"]?.stringValue ?? ""))
                    }
                    return .success(message["result"] ?? .null)
                }
                await respond(to: message)
            }
        }
    }

    private func respond(to message: [String: JSONValue]) async {
        let method = message["method"]?.stringValue
        let params = message["params"]?.objectValue ?? [:]
        guard let id = message["id"] else {
            if method == "log", let text = params["message"]?.stringValue {
                lock.withLock { logs.append(String(text.prefix(4000))) }
            }
            return
        }
        switch method {
        case "secret":
            let key = params["key"]?.stringValue ?? ""
            if let value = grants.secrets[key] {
                reply(id, result: .string(value))
            } else {
                reply(id, error: "Secret \(key) is not declared by this node.")
            }
        case "fetch":
            await fetch(id: id, params: params)
        case "files.list", "files.read", "files.write":
            files(method ?? "", id: id, params: params)
        default:
            reply(id, error: "Unknown method \(method ?? "")")
        }
    }

    private func fetch(id: JSONValue, params: [String: JSONValue]) async {
        guard let raw = params["url"]?.stringValue, let url = URL(string: raw) else {
            reply(id, error: "Invalid URL")
            return
        }
        guard CodeNodeExecutor.isAllowed(url, hosts: grants.allowedHosts) else {
            reply(
                id,
                error: "\(url.host ?? raw) is not on this node's network allowlist (HTTPS only).")
            return
        }
        let options = params["options"]?.objectValue ?? [:]
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = options["method"]?.stringValue?.uppercased() ?? "GET"
        for (key, value) in options["headers"]?.objectValue ?? [:] {
            if let text = value.stringValue { request.setValue(text, forHTTPHeaderField: key) }
        }
        if let body = options["body"] {
            request.httpBody = Data((body.stringValue ?? body.compactJSONString).utf8)
        }
        lock.withLock { fetches.append("\(request.httpMethod ?? "GET") \(url.host ?? "")\(url.path)") }
        do {
            let response = try await fetcher(request)
            reply(
                id,
                result: .object([
                    "status": .number(Double(response.status)),
                    "headers": .object(response.headers.mapValues(JSONValue.string)),
                    "body": .string(response.body),
                    "truncated": .bool(response.truncated),
                ]))
        } catch {
            reply(id, error: error.localizedDescription)
        }
    }

    private func files(_ method: String, id: JSONValue, params: [String: JSONValue]) {
        guard let workspace = grants.workspace else {
            reply(id, error: "This run has no workspace.")
            return
        }
        let fm = FileManager.default
        switch method {
        case "files.list":
            let names = (try? fm.contentsOfDirectory(atPath: workspace.path))?.sorted() ?? []
            reply(id, result: .array(names.map(JSONValue.string)))
        case "files.read":
            guard let url = CodeNodeExecutor.workspaceFile(params["handle"]?.stringValue, in: workspace),
                let data = fm.contents(atPath: url.path)
            else {
                reply(id, error: "No such file in the run workspace.")
                return
            }
            guard data.count <= CodeNodeExecutor.maxResponseBytes else {
                reply(id, error: "The file is larger than 4 MB.")
                return
            }
            reply(id, result: .string(String(decoding: data, as: UTF8.self)))
        default:
            guard let url = CodeNodeExecutor.workspaceFile(params["name"]?.stringValue, in: workspace) else {
                reply(id, error: "File names must be plain names inside the run workspace.")
                return
            }
            let text = params["text"]?.stringValue ?? ""
            guard text.utf8.count <= CodeNodeExecutor.maxResponseBytes else {
                reply(id, error: "Files are limited to 4 MB.")
                return
            }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                reply(id, result: .string(url.lastPathComponent))
            } catch {
                reply(id, error: error.localizedDescription)
            }
        }
    }

    private func reply(_ id: JSONValue, result: JSONValue) {
        send(.object(["id": id, "result": result]))
    }

    private func reply(_ id: JSONValue, error: String) {
        send(.object(["id": id, "error": .object(["message": .string(error)])]))
    }
}
