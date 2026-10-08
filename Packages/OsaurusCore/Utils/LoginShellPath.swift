//
//  LoginShellPath.swift
//  osaurus
//
//  The user's login-shell PATH, resolved once off the main thread.
//
//  A GUI app inherits launchd's sparse PATH, not the one the user's shell builds. Version managers (mise,
//  nvm, asdf, fnm, direnv, Volta) only add their bin directories inside the shell's startup files, so
//  `npx` — and the `node` its `#!/usr/bin/env node` shebang needs — are invisible to stdio MCP servers and the
//  Claude Code launcher (#3024). VS Code solves the same problem the same way: ask the login shell.
//

import Foundation

public actor LoginShellPath {
    public static let shared = LoginShellPath()

    private var task: Task<[String]?, Never>?
    private nonisolated(unsafe) static var cachedValue: [String]?
    private static let cacheLock = NSLock()

    /// Resolved entries once the probe has finished, without waiting. `nil` before that or when the probe
    /// failed — callers then keep the inherited PATH plus `ExecutableLocator`'s fallbacks.
    public nonisolated static var cachedEntries: [String]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedValue
    }

    /// Start the probe early (app launch) so the first MCP connect doesn't wait for it.
    public nonisolated static func prewarm() {
        Task.detached(priority: .utility) { _ = await LoginShellPath.shared.entries() }
    }

    /// The login shell's PATH entries. Runs the probe once; later calls reuse the result.
    public func entries() async -> [String]? {
        if let task { return await task.value }
        let probe = Task.detached(priority: .utility) { () -> [String]? in
            Self.probe(shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", timeout: 5)
        }
        task = probe
        let value = await probe.value
        Self.store(value)
        return value
    }

    private nonisolated static func store(_ value: [String]?) {
        cacheLock.lock()
        cachedValue = value
        cacheLock.unlock()
    }

    private static let marker = "__OSAURUS_LOGIN_PATH__"

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Runs `<shell> -ilc` (interactive, because nvm/mise/asdf activate in `.zshrc`/`.bashrc`) and extracts
    /// PATH between sentinels, so anything the startup files print cannot corrupt it. Bounded by `timeout`; a
    /// hung or failing shell yields `nil`, never a block.
    static func probe(shell: String, timeout: TimeInterval) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let isFish = (shell as NSString).lastPathComponent == "fish"
        let script = isFish
            ? "printf '%s%s%s' \(marker) (string join : $PATH) \(marker)"
            : "printf '%s%s%s' \(marker) \"$PATH\" \(marker)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = isFish ? ["-l", "-c", script] : ["-ilc", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment
        // Drain stdout concurrently: a chatty rc file must not fill the pipe and stall the shell.
        let reader = output.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        let box = DataBox()
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            drained.signal()
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            try? output.fileHandleForWriting.close()
            return nil
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        try? output.fileHandleForWriting.close()
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        return parse(String(decoding: box.data, as: UTF8.self))
    }

    /// Entries between the last pair of sentinels, empty and duplicate entries removed, order kept.
    static func parse(_ text: String) -> [String]? {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var seen = Set<String>()
        let entries = parts[parts.count - 2].split(separator: ":").map(String.init).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        return entries.isEmpty ? nil : entries
    }
}
