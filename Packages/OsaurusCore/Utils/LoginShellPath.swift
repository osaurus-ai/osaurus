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
import Darwin

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
        // Nonblocking reads keep both elapsed time and retained output bounded. A
        // background read-to-EOF can outlive a timeout when an rc child inherits stdout.
        let reader = output.fileHandleForReading
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { return nil }
        defer {
            try? output.fileHandleForWriting.close()
            try? reader.close()
        }
        do { try process.run() } catch { return nil }
        let pid = process.processIdentifier
        // Foundation launches a dedicated process group on macOS. Only signal a
        // group when that ownership is verified; never signal the app's group.
        let ownsGroup = getpgid(pid) == pid
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func drain() {
            // A continuously writing rc must not prevent checking the deadline.
            for _ in 0 ..< 16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 256 * 1024 { data.removeFirst(data.count - 256 * 1024) }
            }
        }
        while process.isRunning {
            drain()
            if Date() >= deadline {
                if ownsGroup { _ = kill(-pid, SIGTERM) } else { process.terminate() }
                let grace = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < grace { usleep(10_000) }
                // Kill remaining owned descendants too, even if the shell exited on TERM.
                if ownsGroup { _ = kill(-pid, SIGKILL) }
                else if process.isRunning { _ = kill(pid, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            usleep(10_000)
        }
        drain()
        return parse(String(decoding: data, as: UTF8.self))
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
