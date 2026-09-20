//
//  ShortcutsTools.swift
//  osaurus
//
//  Built-in `shortcuts_*` tools over the `/usr/bin/shortcuts` CLI. Input and
//  output go through temp files (`--input-path` / `--output-path`) so
//  arbitrary text round-trips without shell quoting, and each run has a
//  hard 300 s budget. No TCC permission of its own — the shortcut's actions
//  prompt for whatever they need.
//

import Foundation

struct ShortcutInfo: Codable, Sendable, Equatable {
    let name: String
    let folder: String?
}

struct ShortcutRunResult: Codable, Sendable, Equatable {
    let name: String
    let output: String?
    let outputIsEmpty: Bool
    let durationSeconds: Double
}

protocol ShortcutsServicing: Sendable {
    func list() async throws -> [ShortcutInfo]
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunResult
}

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

final class ShortcutsCLIService: ShortcutsServicing, @unchecked Sendable {
    static let executable = "/usr/bin/shortcuts"

    private func ensureAvailable() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw AppleToolError.unavailable("The `shortcuts` command-line tool is not available on this Mac.", retryable: false)
        }
    }

    /// Run the CLI with a timeout; returns (exit code, stdout, stderr).
    private func exec(_ arguments: [String], timeout: TimeInterval) async throws -> (Int32, String, String) {
        try ensureAvailable()
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.executable)
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let gate = OnceGate()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard gate.claim() else { return }
                process.terminate()
                continuation.resume(throwing: AppleToolError.timeout("Shortcut run exceeded \(Int(timeout))s and was stopped."))
            }
            process.terminationHandler = { p in
                timer.cancel()
                guard gate.claim() else { return }
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (p.terminationStatus, o, e))
            }
            do {
                try process.run()
                timer.resume()
            } catch {
                timer.cancel()
                guard gate.claim() else { return }
                continuation.resume(throwing: AppleToolError.unavailable("Could not launch `shortcuts`: \(error.localizedDescription)", retryable: true))
            }
        }
    }

    func list() async throws -> [ShortcutInfo] {
        let (code, out, err) = try await exec(["list", "--show-identifiers"], timeout: 30)
        guard code == 0 else {
            throw AppleToolError.execution("`shortcuts list` failed (\(code)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Lines look like `Name (UUID)`; folders are not exposed by the CLI.
        return out.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            var name = text
            if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
                name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            }
            return ShortcutInfo(name: name, folder: nil)
        }
    }

    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osaurus-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var args = ["run", name, "--output-type", "public.plain-text"]
        if let input {
            let inURL = dir.appendingPathComponent("input.txt")
            try input.write(to: inURL, atomically: true, encoding: .utf8)
            args += ["--input-path", inURL.path]
        }
        let outURL = dir.appendingPathComponent("output.txt")
        args += ["--output-path", outURL.path]
        let started = Date()
        let (code, stdout, stderr) = try await exec(args, timeout: timeout)
        let duration = Date().timeIntervalSince(started)
        guard code == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("could not find") || message.localizedCaseInsensitiveContains("no shortcut") {
                throw AppleToolError.notFound("No shortcut named `\(name)`. Call `shortcuts_list` for the exact names.")
            }
            throw AppleToolError.execution("Shortcut `\(name)` failed (\(code)): \(message.isEmpty ? stdout : message)")
        }
        var output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if output.isEmpty { output = stdout }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortcutRunResult(name: name, output: trimmed.isEmpty ? nil : trimmed, outputIsEmpty: trimmed.isEmpty, durationSeconds: duration)
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
            description: "List the user's Shortcuts by exact name (use with shortcuts_run).",
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
            description: "Run a Shortcut by exact name, optionally passing text as its input, and return its text output. Runs can take a while (up to 5 minutes) and may show the shortcut's own prompts.",
            parameters: AppleSchema.object(
                [
                    "name": AppleSchema.string("Exact shortcut name from shortcuts_list."),
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
        return AppleToolPayload(["result": result])
    }
}
