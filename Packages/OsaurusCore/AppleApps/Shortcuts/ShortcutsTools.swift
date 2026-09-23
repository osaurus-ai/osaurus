//
//  ShortcutsTools.swift
//  osaurus
//
//  Built-in `shortcuts_*` tools over the `/usr/bin/shortcuts` CLI. Input and
//  output go through temp files (`--input-path` / `--output-path`) so
//  arbitrary text round-trips without shell quoting, and each run has a
//  hard budget. No TCC permission of its own — the shortcut's actions
//  prompt for whatever they need.
//
//  Process plumbing lives in `ShortcutsProcessRunner`: stdout/stderr are
//  drained concurrently while the shortcut runs (reading them only after
//  exit deadlocked any shortcut that printed more than the 64 KiB pipe
//  buffer — it blocked on write, we blocked on `waitUntilExit`), the drain
//  is capped, and cancelling the tool call terminates the process instead
//  of leaving it running.
//

import Foundation

struct ShortcutInfo: Codable, Sendable, Equatable {
    let name: String
    /// Stable identifier (UUID) — accepted by `shortcuts_run` too, so a
    /// renamed shortcut keeps working.
    let identifier: String?
    let folder: String?
}

struct ShortcutRunResult: Codable, Sendable, Equatable {
    let name: String
    let output: String?
    let outputIsEmpty: Bool
    /// The shortcut produced non-text output (image, file, …) that cannot
    /// be returned inline; `outputBytes` tells how much.
    let outputIsBinary: Bool
    let outputBytes: Int
    let outputTruncated: Bool
    let durationSeconds: Double
}

protocol ShortcutsServicing: Sendable {
    func list() async throws -> [ShortcutInfo]
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunResult
}

// MARK: - Process runner

/// Result of one CLI invocation.
struct ShortcutsProcessOutput: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// Whether either stream exceeded the drain cap and was cut.
    let truncated: Bool
}

/// Runs a child process with concurrent, capped pipe draining, a wall-clock
/// timeout, and task-cancellation propagation (SIGTERM, then SIGKILL after
/// a grace period). Kept generic (any executable) so the hang / cancel
/// contract is testable with `/bin/sh`.
enum ShortcutsProcessRunner {
    /// Bytes kept per stream; anything beyond is discarded (still drained,
    /// so the child never blocks on a full pipe).
    static let outputCap = 1 << 20
    /// Time between SIGTERM and SIGKILL when the child ignores the former.
    static let killGrace: TimeInterval = 2

    /// Lock-guarded one-shot flag so a continuation is resumed exactly once.
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Thread-safe capped byte sink fed by `readabilityHandler`.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var truncated = false
        private let cap: Int
        init(cap: Int) { self.cap = cap }
        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let room = cap - data.count
            if room <= 0 {
                truncated = true
            } else if chunk.count > room {
                data.append(chunk.prefix(room))
                truncated = true
            } else {
                data.append(chunk)
            }
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Shared handle so the cancellation handler (which runs on whatever
    /// thread cancels) can reach the process.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var killTimer: DispatchSourceTimer?
        private var cancelled = false
        /// Set by the task-cancellation handler so the termination handler
        /// (which runs outside any task) can tell a cancel from a crash.
        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func markCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        func set(_ p: Process) {
            lock.lock()
            process = p
            lock.unlock()
        }
        /// SIGTERM now, SIGKILL after `killGrace` if still running.
        func terminate() {
            lock.lock()
            defer { lock.unlock() }
            guard let process, process.isRunning else { return }
            process.terminate()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + killGrace)
            timer.setEventHandler { [weak process] in
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            timer.resume()
            killTimer = timer
        }
        func cancelKillTimer() {
            lock.lock()
            killTimer?.cancel()
            killTimer = nil
            lock.unlock()
        }
    }

    static func run(
        executable: String, arguments: [String], timeout: TimeInterval, outputCap: Int = outputCap
    ) async throws -> ShortcutsProcessOutput {
        try Task.checkCancellation()
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShortcutsProcessOutput, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice
                let outSink = Sink(cap: outputCap), errSink = Sink(cap: outputCap)
                let gate = OnceGate()
                // Drain both pipes as data arrives so the child never blocks
                // on a full pipe buffer.
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil } else { outSink.append(chunk) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil } else { errSink.append(chunk) }
                }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    guard gate.claim() else { return }
                    box.terminate()
                    continuation.resume(
                        throwing: AppleToolError.timeout("Shortcut run exceeded \(Int(timeout))s and was stopped."))
                }
                process.terminationHandler = { p in
                    timer.cancel()
                    box.cancelKillTimer()
                    // Collect whatever is left in the pipes, then detach.
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if !restOut.isEmpty { outSink.append(restOut) }
                    if !restErr.isEmpty { errSink.append(restErr) }
                    guard gate.claim() else { return }
                    let wasSignalled = p.terminationReason == .uncaughtSignal
                    if box.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(
                        returning: ShortcutsProcessOutput(
                            exitCode: wasSignalled ? -Int32(p.terminationStatus) : p.terminationStatus,
                            stdout: outSink.text, stderr: errSink.text,
                            truncated: outSink.truncated || errSink.truncated
                        ))
                }
                box.set(process)
                do {
                    try process.run()
                    timer.resume()
                } catch {
                    // A never-resumed DispatchSource traps when released:
                    // resume, then cancel.
                    timer.resume()
                    timer.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    guard gate.claim() else { return }
                    continuation.resume(
                        throwing: AppleToolError.unavailable(
                            "Could not launch `\(executable)`: \(error.localizedDescription)", retryable: true))
                }
            }
        } onCancel: {
            box.markCancelled()
            box.terminate()
        }
    }
}

// MARK: - Service

final class ShortcutsCLIService: ShortcutsServicing, @unchecked Sendable {
    static let executable = "/usr/bin/shortcuts"

    private func ensureAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw AppleToolError.unavailable("The `shortcuts` command-line tool is not available on this Mac.", retryable: false)
        }
    }

    private func exec(_ arguments: [String], timeout: TimeInterval) async throws -> ShortcutsProcessOutput {
        try ensureAvailable()
        return try await ShortcutsProcessRunner.run(executable: Self.executable, arguments: arguments, timeout: timeout)
    }

    /// `shortcuts list --show-identifiers` prints `Name (UUID)` per line.
    static let listLinePattern = try? NSRegularExpression(
        pattern: "^(.*?)\\s*\\(([0-9A-Fa-f-]{36})\\)\\s*$", options: [])

    static func parseListLine(_ line: String) -> ShortcutInfo? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let pattern = listLinePattern,
            let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let nameRange = Range(match.range(at: 1), in: text), let idRange = Range(match.range(at: 2), in: text)
        {
            return ShortcutInfo(name: String(text[nameRange]).trimmingCharacters(in: .whitespaces), identifier: String(text[idRange]), folder: nil)
        }
        return ShortcutInfo(name: text, identifier: nil, folder: nil)
    }

    func list() async throws -> [ShortcutInfo] {
        let result = try await exec(["list", "--show-identifiers"], timeout: 30)
        guard result.exitCode == 0 else {
            throw AppleToolError.execution(
                "`shortcuts list` failed (\(result.exitCode)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.split(separator: "\n").compactMap { Self.parseListLine(String($0)) }
    }

    /// `shortcuts run` reports a missing shortcut as e.g. “Couldn’t find
    /// shortcut ‘X’” (U+2019, localized on non-English systems). Match the
    /// stable pieces only.
    static func isNotFoundStderr(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        let normalized = lower.replacingOccurrences(of: "\u{2019}", with: "'")
        if normalized.range(of: #"couldn'?t\s+find\s+(the\s+)?shortcut"#, options: .regularExpression) != nil { return true }
        if normalized.range(of: #"no\s+shortcut\s+(named|with|found)"#, options: .regularExpression) != nil { return true }
        return normalized.contains("shortcut not found")
    }

    /// Resolve `name` (exact name, case-insensitive name, or identifier)
    /// against the installed shortcuts. A miss is a typed `notFound` with
    /// close matches — the CLI's own error text varies by OS version.
    static func resolve(_ name: String, in shortcuts: [ShortcutInfo]) -> ShortcutInfo? {
        if let exact = shortcuts.first(where: { $0.name == name || $0.identifier == name }) { return exact }
        return shortcuts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunResult {
        let installed = try await list()
        guard let shortcut = Self.resolve(name, in: installed) else {
            let close = installed.filter { AppleServiceSupport.matches($0.name, query: name) }.prefix(5).map(\.name)
            var message = "No shortcut named `\(name)`."
            if !close.isEmpty { message += " Close matches: \(close.joined(separator: ", "))." }
            message += " Call `shortcuts_list` for the exact names."
            throw AppleToolError.notFound(message)
        }
        let target = shortcut.identifier ?? shortcut.name

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `--` keeps a name that starts with `-` from being parsed as a flag.
        var args = ["run", "--output-type", "public.plain-text"]
        if let input {
            let inURL = dir.appendingPathComponent("input.txt")
            try input.write(to: inURL, atomically: true, encoding: .utf8)
            args += ["--input-path", inURL.path]
        }
        let outURL = dir.appendingPathComponent("output.txt")
        args += ["--output-path", outURL.path, "--", target]
        let started = Date()
        let result = try await exec(args, timeout: timeout)
        let duration = Date().timeIntervalSince(started)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // The pre-check above catches misses before launch; this covers a
            // shortcut deleted between `list` and `run` (the CLI's text is
            // localized and uses a curly apostrophe, hence the regex).
            if Self.isNotFoundStderr(message) {
                throw AppleToolError.notFound("Shortcut `\(shortcut.name)` was not found by the Shortcuts CLI. Call `shortcuts_list` to refresh the names.")
            }
            throw AppleToolError.execution(
                "Shortcut `\(shortcut.name)` failed (\(result.exitCode)): \(message.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : message)"
            )
        }
        let fileData = (try? Data(contentsOf: outURL)) ?? Data()
        var outputIsBinary = false
        var output: String
        if fileData.isEmpty {
            output = result.stdout
        } else if let text = String(data: fileData, encoding: .utf8) {
            output = text
        } else {
            outputIsBinary = true
            output = ""
        }
        var truncated = result.truncated
        if output.utf8.count > ShortcutsProcessRunner.outputCap {
            output = String(decoding: output.utf8.prefix(ShortcutsProcessRunner.outputCap), as: UTF8.self)
            truncated = true
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutRunResult(
            name: shortcut.name, output: trimmed.isEmpty ? nil : trimmed, outputIsEmpty: trimmed.isEmpty && !outputIsBinary,
            outputIsBinary: outputIsBinary, outputBytes: outputIsBinary ? fileData.count : trimmed.utf8.count,
            outputTruncated: truncated, durationSeconds: duration
        )
    }
}

// MARK: - Tools

enum ShortcutsToolFactory {
    static func makeTools(service: ShortcutsServicing = ShortcutsCLIService()) -> [OsaurusTool] {
        [ShortcutsListTool(service: service), ShortcutsRunTool(service: service)]
    }
}

final class ShortcutsListTool: AppleToolBase, @unchecked Sendable {
    private let service: ShortcutsServicing
    init(service: ShortcutsServicing) {
        self.service = service
        super.init(
            app: .shortcuts, name: "shortcuts_list",
            description: "List the user's Shortcuts with their exact names and identifiers (either works with shortcuts_run).",
            parameters: AppleSchema.object([
                "query": AppleSchema.string("Only shortcuts whose name contains this text."),
                "limit": AppleSchema.limit(default: 100, max: 500),
            ]),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.string(args, "query")
        let limit = try AppleArgs.limit(args, default: 100, max: 500)
        var items = try await service.list()
        if let query, !query.isEmpty { items = items.filter { AppleServiceSupport.matches($0.name, query: query) } }
        let page = AppleServiceSupport.page(items, limit: limit)
        return AppleToolPayload(["shortcuts": page.items, "count": page.items.count, "total": page.total, "truncated": page.truncated])
    }
}

final class ShortcutsRunTool: AppleToolBase, @unchecked Sendable {
    private let service: ShortcutsServicing
    static let defaultTimeout: TimeInterval = 300
    init(service: ShortcutsServicing) {
        self.service = service
        super.init(
            app: .shortcuts, name: "shortcuts_run",
            description: "Run a Shortcut by exact name or identifier (from shortcuts_list), optionally passing text as its input, and return its text output. Runs can take a while (default budget 5 minutes, max 10) and the shortcut may show its own prompts — an Ask Each Time or Show Result step blocks until the user acts on it; stopping the chat stops the shortcut. Non-text output is reported as binary, not returned.",
            parameters: AppleSchema.object(
                [
                    "name": AppleSchema.string("Exact shortcut name or identifier from shortcuts_list."),
                    "input": AppleSchema.string("Text passed as the shortcut's input."),
                    "timeout_seconds": AppleSchema.integer("Abort after this many seconds (default 300, max 600)."),
                ],
                required: ["name"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let name = try AppleArgs.requiredString(args, "name", expected: "a shortcut name")
        let input = try AppleArgs.string(args, "input")
        let timeout = TimeInterval(min(max(try AppleArgs.int(args, "timeout_seconds") ?? Int(Self.defaultTimeout), 5), 600))
        let result = try await service.run(name: name, input: input, timeout: timeout)
        var warnings: [String] = []
        if result.outputIsBinary { warnings.append("The shortcut returned non-text output (\(result.outputBytes) bytes); only text output can be returned.") }
        if result.outputTruncated { warnings.append("The shortcut's output exceeded 1 MiB and was truncated.") }
        return AppleToolPayload(["result": result], warnings: warnings)
    }
}
