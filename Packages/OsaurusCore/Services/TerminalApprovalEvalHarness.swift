//
//  TerminalApprovalEvalHarness.swift
//  OsaurusCore
//
//  Deterministic, model-free driver for the `terminal_approval` eval domain.
//  Runs a probe `.ask` tool through the REAL ToolRegistry gate on an external
//  surface (the context `/agents/{id}/run` binds) and answers its card the
//  way `osaurus agent run` does, through `ToolPermissionPromptService`'s
//  terminal session API. No model, no network, no AppKit panel.
//

import Foundation

public struct TerminalApprovalScenarioOutcome: Sendable, Codable {
    public let passed: Bool
    public let checks: [String]
    public let failures: [String]
}

@MainActor
public enum TerminalApprovalEvalHarness {

    private final class ProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
        let name: String
        let description = "Eval-only terminal approval probe."
        let parameters: JSONValue? = nil
        let requirements: [String] = []
        let defaultPermissionPolicy: ToolPermissionPolicy = .ask
        private let lock = NSLock()
        private var _executions = 0

        var executions: Int {
            lock.lock()
            defer { lock.unlock() }
            return _executions
        }

        init(name: String) { self.name = name }

        func execute(argumentsJSON: String) async throws -> String {
            lock.withLock { _executions += 1 }
            return ToolEnvelope.success(tool: name, text: "ran")
        }
    }

    private final class Recorder {
        var checks: [String] = []
        var failures: [String] = []

        func check(_ condition: Bool, _ line: String) {
            checks.append((condition ? "ok: " : "FAIL: ") + line)
            if !condition { failures.append(line) }
        }

        var outcome: TerminalApprovalScenarioOutcome {
            TerminalApprovalScenarioOutcome(passed: failures.isEmpty, checks: checks, failures: failures)
        }
    }

    /// Scenarios:
    ///   - `terminal_approve`: the run's card reaches only its own terminal
    ///     session (not the phone, not another session); `allow_once` runs
    ///     the tool exactly once.
    ///   - `terminal_deny`: `deny` from the terminal refuses the call and
    ///     the tool never runs.
    ///   - `headless_refusal`: an external run with no terminal session is
    ///     refused with "requires interactive approval" and raises no card.
    ///   - `narrowed_answers`: on a per-call card, `always_allow` and
    ///     `allow_for_run` from the terminal become `allow_once`.
    public static func run(scenario: String) async -> TerminalApprovalScenarioOutcome {
        let recorder = Recorder()
        let defaults = UserDefaults.standard
        let autoAllowKey = ToolApprovalSettings.autoAllowAllDefaultsKey
        let previousAutoAllow = defaults.object(forKey: autoAllowKey)
        defaults.set(false, forKey: autoAllowKey)
        ToolPermissionPromptService.resetForTesting()
        defer {
            ToolPermissionPromptService.resetForTesting()
            if let previousAutoAllow {
                defaults.set(previousAutoAllow, forKey: autoAllowKey)
            } else {
                defaults.removeObject(forKey: autoAllowKey)
            }
        }

        switch scenario {
        case "terminal_approve", "terminal_deny", "headless_refusal":
            await runToolScenario(scenario, recorder)
        case "narrowed_answers":
            await narrowedAnswers(recorder)
        default:
            recorder.check(false, "unknown scenario '\(scenario)'")
        }
        return recorder.outcome
    }

    private static func runToolScenario(_ scenario: String, _ recorder: Recorder) async {
        let registry = ToolRegistry.shared
        let tool = ProbeTool(name: "eval_terminal_probe_" + UUID().uuidString.prefix(8).lowercased())
        registry.register(tool)
        registry.setEnabled(true, for: tool.name)
        defer {
            registry.clearPolicy(for: tool.name)
            registry.unregister(names: [tool.name])
        }

        let session: String? = scenario == "headless_refusal" ? nil : "cli-" + UUID().uuidString
        let run = externalRun(tool.name, session: session)

        guard let session else {
            let result = await run.result
            let message = (try? result.get()).map { _ in "" } ?? errorText(result)
            recorder.check(message.contains("requires interactive approval"), "headless call refused: \(message)")
            recorder.check(ToolPermissionPromptService.openPromptCount == 0, "no card raised for a headless run")
            recorder.check(tool.executions == 0, "tool did not run")
            return
        }

        let card = await waitForCard(session: session)
        recorder.check(card != nil, "card reached the terminal session")
        guard let card else {
            run.cancel()
            return
        }
        recorder.check(card.toolName == tool.name, "card names the tool")
        recorder.check(
            ToolPermissionPromptService.terminalPrompts(session: "cli-another-session").isEmpty,
            "another terminal session sees no card")
        recorder.check(ToolPermissionPromptService.remotePrompts.isEmpty, "your iPhone sees no card")
        recorder.check(
            !ToolPermissionPromptService.resolveFromTerminal(
                id: card.id, session: "cli-another-session", outcome: .allowOnce),
            "another terminal session cannot answer")
        recorder.check(
            !ToolPermissionPromptService.resolveRemotely(id: card.id, outcome: .allowOnce),
            "the phone route cannot answer")

        if scenario == "terminal_approve" {
            recorder.check(
                ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .allowOnce),
                "own session answers allow_once")
            let result = await run.result
            let output = (try? result.get()) ?? ""
            recorder.check(output.contains("ran"), "tool result came back")
            recorder.check(tool.executions == 1, "tool ran exactly once (ran \(tool.executions))")
        } else {
            recorder.check(
                ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .denied),
                "own session answers deny")
            let result = await run.result
            let refused: Bool
            if case .success(let output) = result {
                refused = output.contains("\"ok\":false") || output.contains("\"ok\" : false")
            } else {
                refused = true
            }
            recorder.check(refused, "denied call is refused")
            recorder.check(tool.executions == 0, "tool did not run")
        }
        recorder.check(
            !ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .allowOnce),
            "an answered card cannot be answered again")
    }

    private static func narrowedAnswers(_ recorder: Recorder) async {
        for (answer, label) in [
            (ToolPermissionPromptService.PromptResolution.alwaysAllow, "always_allow"),
            (.allowForRun, "allow_for_run"),
        ] {
            let session = "cli-" + UUID().uuidString
            let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
            let task = ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
                ChatExecutionContext.$terminalReviewerSession.withValue(session) {
                    Task { @MainActor in
                        await ToolPermissionPromptService.requestApprovalOutcome(
                            toolName: "web_fetch", description: "Fetch", argumentsJSON: "{}",
                            perCallApprovalOnly: true)
                    }
                }
            }
            guard let card = await waitForCard(session: session) else {
                recorder.check(false, "per-call card reached the terminal (\(label))")
                task.cancel()
                continue
            }
            recorder.check(!card.offersRunLease, "per-call card offers no run lease (\(label))")
            recorder.check(
                ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: answer),
                "terminal answers \(label)")
            let outcome = await task.value
            recorder.check(outcome == .allowOnce, "\(label) from the terminal became allow_once (got \(outcome))")
        }
    }

    private static func externalRun(_ toolName: String, session: String?) -> Task<String, Error> {
        let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
        return ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
            ChatExecutionContext.$isExternalSurface.withValue(true) {
                ChatExecutionContext.$terminalReviewerSession.withValue(session) {
                    Task { @MainActor in
                        try await ToolRegistry.shared.execute(name: toolName, argumentsJSON: "{}")
                    }
                }
            }
        }
    }

    private static func waitForCard(session: String) async -> ToolPermissionPromptService.RemotePrompt? {
        for _ in 0 ..< 400 {
            if let card = ToolPermissionPromptService.terminalPrompts(session: session).first { return card }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private static func errorText(_ result: Result<String, Error>) -> String {
        if case .failure(let error) = result { return error.localizedDescription }
        return ""
    }
}
