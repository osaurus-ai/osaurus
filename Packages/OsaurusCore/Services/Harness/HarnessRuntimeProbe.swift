//
//  HarnessRuntimeProbe.swift
//  osaurus
//
//  The Agent Runtimes "Test" button: start the runtime the way a chat would
//  and ask it something harmless. Pi answers `get_state`; Claude Code reports
//  its sign-in with `auth status`.
//

import Foundation

public struct HarnessProbeResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Started and ready to chat.
        case ready
        /// Started, but chats will fail until the user fixes something
        /// (no model configured, signed out).
        case needsSetup
        /// Couldn't start or didn't answer.
        case failed
    }

    public var status: Status
    public var message: String
    /// The executable that was actually run.
    public var resolvedExecutable: String?
}

/// Resolution for one-shot control commands, using the same PATH a harness
/// chat process gets, so a Test that passes means a chat can launch.
enum HarnessControlCommand {
    struct Resolved: Sendable {
        var executable: String
        var environment: [String: String]
    }

    static func resolve(
        _ command: String,
        overlay: [String: String] = [:],
        removing: Set<String> = HarnessEnvironment.alwaysRemoved,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Resolved? {
        let entries = await LoginShellPath.shared.entries()
        var environment = HarnessProcess.childEnvironment(
            inherited: inherited,
            loginShellEntries: entries,
            overlay: overlay,
            removing: removing
        )
        guard let executable = ExecutableLocator.resolve(command: command, env: environment),
            FileManager.default.isExecutableFile(atPath: executable)
        else { return nil }
        if overlay["PATH"] == nil {
            environment["PATH"] = HarnessProcess.prependingShebangSibling(
                of: executable,
                to: environment["PATH"] ?? ""
            )
        }
        return Resolved(executable: executable, environment: environment)
    }

    /// The PATH searched for `command`, for "not found" messages.
    static func searchedPath(inherited: [String: String] = ProcessInfo.processInfo.environment) async -> String {
        let entries = await LoginShellPath.shared.entries()
        return ExecutableLocator.childPath(inherited: inherited, loginShellEntries: entries)
    }
}

enum HarnessRuntimeProbe {
    static func run(_ runtime: HarnessRuntime, timeout: TimeInterval = 20) async -> HarnessProbeResult {
        switch runtime.kind {
        case .claudeCode: return await probeClaudeCode(runtime)
        case .piRPC: return await probePi(runtime, timeout: timeout)
        }
    }

    // MARK: - Claude Code

    private static func probeClaudeCode(_ runtime: HarnessRuntime) async -> HarnessProbeResult {
        let state = await ClaudeCodeConfiguration.setupState(
            command: runtime.executable,
            overlay: runtime.environment
        )
        let resolved = await HarnessControlCommand.resolve(runtime.executable, overlay: runtime.environment)
        switch state {
        case .notInstalled:
            return HarnessProbeResult(
                status: .failed,
                message: String(format: L("Couldn't find \"%@\"."), runtime.executable),
                resolvedExecutable: nil
            )
        case .statusUnavailable(let version):
            return HarnessProbeResult(
                status: .needsSetup,
                message: String(
                    format: L("Claude Code %@ doesn't report its sign-in status. Run claude in Terminal to check it."),
                    version ?? ""
                ),
                resolvedExecutable: resolved?.executable
            )
        case .signedOut:
            return HarnessProbeResult(
                status: .needsSetup,
                message: L("Claude Code isn't signed in."),
                resolvedExecutable: resolved?.executable
            )
        case .signedIn(let status):
            let account = status.email ?? status.orgName
            return HarnessProbeResult(
                status: .ready,
                message: account.map { String(format: L("Signed in as %@."), $0) } ?? L("Signed in."),
                resolvedExecutable: resolved?.executable
            )
        }
    }

    // MARK: - Pi

    private static func probePi(_ runtime: HarnessRuntime, timeout: TimeInterval) async -> HarnessProbeResult {
        let probeChatId = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-harness-probe-\(probeChatId.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let promptFile = directory.appendingPathComponent("system-prompt.md")
        try? Data().write(to: promptFile)

        var environment = runtime.environment
        environment[HarnessEnvironment.chatId] = probeChatId.uuidString.lowercased()
        environment[HarnessEnvironment.workingDirectory] = directory.path

        let spec = HarnessProcess.LaunchSpec(
            executable: runtime.executable,
            arguments: runtime.resolvedArguments(
                chatId: probeChatId,
                agentId: Agent.defaultId,
                workingDirectory: directory,
                systemPromptFile: promptFile
            ),
            environment: environment,
            removingEnvironment: HarnessEnvironment.alwaysRemoved,
            workingDirectory: directory,
            runtimeName: runtime.displayName
        )

        let process: HarnessProcess
        do {
            process = try await HarnessProcess.launch(spec)
        } catch {
            return HarnessProbeResult(
                status: .failed,
                message: error.localizedDescription,
                resolvedExecutable: nil
            )
        }

        let requestId = "osaurus-probe-\(UUID().uuidString)"
        let outcome: PiProbeOutcome
        do {
            try await process.send(try HarnessJSON.encode(["id": requestId, "type": "get_state"]))
            outcome = await awaitStateResponse(process: process, requestId: requestId, timeout: timeout)
        } catch {
            outcome = .exited
        }
        await process.shutdown(grace: 2)

        let executable = process.resolvedExecutable
        switch outcome {
        case .state(let data):
            let model = data["model"] as? [String: Any]
            let provider = (model?["provider"] as? String) ?? ""
            let modelId = (model?["id"] as? String) ?? ""
            if modelId.isEmpty || modelId == "unknown" {
                return HarnessProbeResult(
                    status: .needsSetup,
                    message: L(
                        "Connected, but no model is configured. Run it in Terminal and use /login, or pass --provider and --model in the arguments."
                    ),
                    resolvedExecutable: executable
                )
            }
            let label = provider.isEmpty || provider == "unknown" ? modelId : "\(provider)/\(modelId)"
            return HarnessProbeResult(
                status: .ready,
                message: String(format: L("Connected. Model: %@."), label),
                resolvedExecutable: executable
            )
        case .rejected(let detail):
            return HarnessProbeResult(status: .failed, message: detail, resolvedExecutable: executable)
        case .timedOut:
            return HarnessProbeResult(
                status: .failed,
                message: L("It started but didn't answer an RPC get_state request. Check that the arguments include --mode rpc."),
                resolvedExecutable: executable
            )
        case .exited:
            let stderr = process.stderrText()
            let code = process.exitCode ?? -1
            return HarnessProbeResult(
                status: .failed,
                message: HarnessError.exited(runtime: runtime.displayName, code: code, stderrTail: stderr)
                    .localizedDescription,
                resolvedExecutable: executable
            )
        }
    }

    private enum PiProbeOutcome: @unchecked Sendable {
        case state([String: Any])
        case rejected(String)
        case timedOut
        case exited
    }

    private static func awaitStateResponse(
        process: HarnessProcess,
        requestId: String,
        timeout: TimeInterval
    ) async -> PiProbeOutcome {
        await withTaskGroup(of: PiProbeOutcome.self) { group in
            group.addTask {
                for await line in process.lines {
                    guard let root = HarnessJSON.object(line),
                        (root["type"] as? String) == "response",
                        (root["id"] as? String) == requestId
                    else { continue }
                    if (root["success"] as? Bool) == true {
                        return .state((root["data"] as? [String: Any]) ?? [:])
                    }
                    return .rejected((root["error"] as? String) ?? L("The get_state request was rejected."))
                }
                return .exited
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}
