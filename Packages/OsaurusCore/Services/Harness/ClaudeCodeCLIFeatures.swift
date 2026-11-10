//
//  ClaudeCodeCLIFeatures.swift
//  osaurus
//
//  Launch flags the installed `claude` may or may not know. An unknown
//  option makes the CLI refuse to start, so optional flags are only passed
//  when its `--help` lists them. Read once per binary (path + modification
//  date), so an update is noticed on the next launch.
//

import Foundation

struct ClaudeCodeCLIFeatures: Sendable, Equatable {
    /// `--system-prompt-snapshot <on|off>`. On (the default) reuses the
    /// first turn's system prompt on every resume, so a relaunch with new
    /// instructions or a changed tool note would keep the old ones.
    var systemPromptSnapshot = false

    static let none = ClaudeCodeCLIFeatures()

    static func parse(help: String) -> ClaudeCodeCLIFeatures {
        ClaudeCodeCLIFeatures(systemPromptSnapshot: help.contains("--system-prompt-snapshot"))
    }

    static func detect(_ runtime: HarnessRuntime) async -> ClaudeCodeCLIFeatures {
        guard
            let resolved = await HarnessControlCommand.resolve(
                runtime.executable,
                overlay: runtime.environment,
                removing: HarnessEnvironment.alwaysRemoved.union(ClaudeCodeHarnessAdapter.removedEnvironment)
            )
        else { return .none }
        // The installer updates by repointing a symlink, so key on the target.
        let target = URL(fileURLWithPath: resolved.executable).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: target))?[.modificationDate] as? Date
        let key = "\(target)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = await Cache.shared.value(for: key) { return cached }
        guard
            let result = await ClaudeCodeProcessRunner.capture(
                executable: resolved.executable,
                arguments: ["--help"],
                environment: resolved.environment,
                timeout: 5
            ),
            !result.timedOut
        else { return .none }
        let features = parse(help: String(decoding: result.stdout, as: UTF8.self))
        await Cache.shared.store(features, for: key)
        return features
    }

    private actor Cache {
        static let shared = Cache()
        private var values: [String: ClaudeCodeCLIFeatures] = [:]

        func value(for key: String) -> ClaudeCodeCLIFeatures? { values[key] }
        func store(_ features: ClaudeCodeCLIFeatures, for key: String) { values[key] = features }
    }
}
