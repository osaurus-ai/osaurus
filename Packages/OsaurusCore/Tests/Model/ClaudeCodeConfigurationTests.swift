//
//  ClaudeCodeConfigurationTests.swift
//  osaurusTests
//
//  Argument-vector, model-id, and PATH-resolution coverage for the Claude
//  Code backend. Token-free — no subprocess, no network.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code configuration")
struct ClaudeCodeConfigurationTests {

    // MARK: - Model ids

    @Test func pickerIdsRoundTrip() {
        for model in ClaudeCodeModel.allCases {
            #expect(ClaudeCodeModel.fromPickerId(model.pickerId) == model)
        }
    }

    @Test func foreignModelIdsAreRejected() {
        #expect(ClaudeCodeModel.fromPickerId("mlx-community/Qwen3-8B") == nil)
        #expect(ClaudeCodeModel.fromPickerId("openai/gpt-5") == nil)
        #expect(ClaudeCodeModel.fromPickerId("") == nil)
        // Right prefix, unknown alias.
        #expect(ClaudeCodeModel.fromPickerId("claude-code/nonexistent") == nil)
    }

    /// The service must not claim the empty / "default" model the way
    /// `FoundationModelService` does — installing Claude Code should never
    /// silently take over the system default.
    @Test func serviceOnlyClaimsItsOwnIds() {
        let service = ClaudeCodeService()
        #expect(service.handles(requestedModel: "claude-code/sonnet"))
        #expect(!service.handles(requestedModel: nil))
        #expect(!service.handles(requestedModel: ""))
        #expect(!service.handles(requestedModel: "default"))
        #expect(!service.handles(requestedModel: "foundation"))
    }

    // MARK: - Argument vector

    @Test func agentModeIsFailClosedByDefault() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: ClaudeCodeConfiguration.allowedTools(allowWrites: false, allowShell: false),
            systemPrompt: nil
        )
        // `dontAsk` is what makes an un-allowlisted tool a denial rather than a
        // silent approval in a non-interactive run.
        #expect(args.contains("--permission-mode"))
        #expect(args.contains("dontAsk"))

        guard let allowedIndex = args.firstIndex(of: "--allowedTools") else {
            Issue.record("expected an --allowedTools flag in \(args)")
            return
        }
        let allowed = args[allowedIndex + 1]
        #expect(allowed.contains("Read"))
        #expect(!allowed.contains("Bash"))
        #expect(!allowed.contains("Write"))
    }

    @Test func optingIntoWritesAndShellWidensTheAllowlist() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .opus,
            mode: .agent,
            allowedTools: ClaudeCodeConfiguration.allowedTools(allowWrites: true, allowShell: true),
            systemPrompt: nil
        )
        guard let allowedIndex = args.firstIndex(of: "--allowedTools") else {
            Issue.record("expected an --allowedTools flag in \(args)")
            return
        }
        let allowed = args[allowedIndex + 1]
        #expect(allowed.contains("Read"))
        #expect(allowed.contains("Write"))
        #expect(allowed.contains("Bash"))
    }

    /// `--tools ""` is the CLI's documented "disable every built-in" form.
    @Test func textOnlyModeDisablesEveryBuiltinTool() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .haiku,
            mode: .textOnly,
            allowedTools: ["Read", "Bash"],
            systemPrompt: nil
        )
        guard let toolsIndex = args.firstIndex(of: "--tools") else {
            Issue.record("expected a --tools flag in \(args)")
            return
        }
        #expect(args[toolsIndex + 1].isEmpty)
        // Permission mode is meaningless with no tools, and an allowlist would
        // contradict the disable.
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--permission-mode"))
    }

    @Test func everyRunIsStatelessAndIgnoresUserMCPServers() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: [],
            systemPrompt: nil
        )
        // Without this the CLI writes into the user's ~/.claude history.
        #expect(args.contains("--no-session-persistence"))
        // Without this the CLI silently inherits whatever MCP servers the user
        // configured for their own terminal sessions.
        #expect(args.contains("--strict-mcp-config"))
        // Without this the chat sits blank and paints the whole answer at once.
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--print"))

        guard let formatIndex = args.firstIndex(of: "--output-format") else {
            Issue.record("expected an --output-format flag in \(args)")
            return
        }
        #expect(args[formatIndex + 1] == "stream-json")
    }

    @Test func modelAliasIsPassedThrough() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .opus,
            mode: .agent,
            allowedTools: [],
            systemPrompt: nil
        )
        guard let modelIndex = args.firstIndex(of: "--model") else {
            Issue.record("expected a --model flag in \(args)")
            return
        }
        #expect(args[modelIndex + 1] == "opus")
    }

    /// Appending rather than replacing keeps Claude Code's own tool contract
    /// intact.
    @Test func systemPromptIsAppendedNotReplaced() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: [],
            systemPrompt: "You are terse."
        )
        #expect(args.contains("--append-system-prompt"))
        #expect(args.contains("You are terse."))
        #expect(!args.contains("--system-prompt"))
    }

    @Test func blankSystemPromptIsOmitted() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: [],
            systemPrompt: "   \n "
        )
        #expect(!args.contains("--append-system-prompt"))
    }

    // MARK: - Prompt rendering

    private func message(_ role: String, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content)
    }

    @Test func singleUserTurnIsSentBare() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [message("user", "hi there")])
        #expect(rendered.prompt == "hi there")
        #expect(rendered.systemPrompt == nil)
    }

    @Test func systemMessagesAreHoistedOutOfTheTranscript() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [
            message("system", "Be brief."),
            message("user", "hi"),
        ])
        #expect(rendered.systemPrompt == "Be brief.")
        #expect(rendered.prompt == "hi")
    }

    @Test func priorTurnsAreRenderedAsALabeledTranscript() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [
            message("user", "one"),
            message("assistant", "two"),
            message("user", "three"),
        ])
        #expect(rendered.prompt == "User: one\n\nAssistant: two\n\nUser: three")
    }

    @Test func emptyMessagesAreSkipped() {
        let rendered = ClaudeCodeService.renderPrompt(messages: [
            message("system", "   "),
            message("user", "only this"),
        ])
        #expect(rendered.systemPrompt == nil)
        #expect(rendered.prompt == "only this")
    }

    // MARK: - Executable resolution

    @Test func absoluteAndTildePathsBypassThePathWalk() {
        #expect(ExecutableLocator.resolve(command: "/bin/sh", env: [:]) == "/bin/sh")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ExecutableLocator.expandUserPath("~/bin/claude") == "\(home)/bin/claude")
        #expect(ExecutableLocator.expandUserPath("~") == home)
        #expect(ExecutableLocator.expandUserPath("/opt/claude") == "/opt/claude")
    }

    /// GUI-launched apps inherit a sparse PATH; the fallbacks are what make
    /// a Homebrew or `~/.local/bin` install discoverable at all.
    @Test func searchPathAppendsCommonInstallLocations() {
        let path = ExecutableLocator.searchPath(env: ["PATH": "/custom/first"])
        let entries = path.split(separator: ":").map(String.init)

        #expect(entries.first == "/custom/first")
        #expect(entries.contains("/opt/homebrew/bin"))
        // Where the official Claude Code installer puts the binary.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(entries.contains("\(home)/.local/bin"))
    }

    @Test func searchPathStillWorksWithNoInheritedPath() {
        let entries = ExecutableLocator.searchPath(env: [:]).split(separator: ":").map(String.init)
        #expect(entries.contains("/usr/bin"))
        #expect(entries.contains("/opt/homebrew/bin"))
    }

    @Test func missingBareCommandResolvesToNil() {
        let resolved = ExecutableLocator.resolve(
            command: "osaurus-definitely-not-a-real-binary",
            env: ["PATH": "/usr/bin:/bin"]
        )
        #expect(resolved == nil)
    }

    @Test func bareCommandIsFoundOnPath() {
        // `sh` exists on every macOS install.
        #expect(ExecutableLocator.resolve(command: "sh", env: ["PATH": "/bin"]) == "/bin/sh")
    }

    // MARK: - Agent config

    /// Older agent JSON has no `claudeCode` key at all, and a future build
    /// could write a `mode` this build doesn't know. Neither may lose the
    /// user's agent.
    @Test func agentConfigDecodeFallsBackToSafeDefaults() throws {
        let decoder = JSONDecoder()

        let empty = try decoder.decode(ClaudeCodeAgentConfig.self, from: Data("{}".utf8))
        #expect(empty == .default)
        #expect(empty.mode == .agent)
        #expect(!empty.allowWrites)
        #expect(!empty.allowShell)

        let futureMode = try decoder.decode(
            ClaudeCodeAgentConfig.self,
            from: Data(#"{"mode":"someFutureMode","allowWrites":true}"#.utf8)
        )
        #expect(futureMode.mode == .agent)
        #expect(futureMode.allowWrites)
    }

    @Test func agentConfigRoundTrips() throws {
        let original = ClaudeCodeAgentConfig(mode: .textOnly, allowWrites: true, allowShell: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClaudeCodeAgentConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test func defaultAgentPersistsClaudePermissionPrecedence() throws {
        let claude = ClaudeCodeAgentConfig(
            mode: .agent,
            allowWrites: true,
            allowShell: false,
            allowOsaurusTools: true,
            allowOsaurusConfigWrites: false
        )
        let original = DefaultAgentConfiguration(claudeCode: claude)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DefaultAgentConfiguration.self, from: data)

        #expect(decoded.claudeCode == claude)
        #expect(decoded.claudeCode?.allowOsaurusTools == true)
        #expect(decoded.claudeCode?.allowOsaurusConfigWrites == false)
    }

    // MARK: - Auth status

    /// The exact shape `claude auth status --json` emits for a personal
    /// subscription login, captured from the CLI.
    @Test func decodesSubscriptionLogin() throws {
        let json = """
            {
              "loggedIn": true,
              "authMethod": "claude.ai",
              "apiProvider": "firstParty",
              "email": "someone@example.com",
              "orgId": "4366ad70-efb4-4d0c-8ee3-475e0e512f77",
              "orgName": "Someone",
              "subscriptionType": "pro"
            }
            """
        let status = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(json.utf8)))

        #expect(status.loggedIn)
        #expect(status.email == "someone@example.com")
        #expect(status.subscriptionType == "pro")
        #expect(status.displayPlan == "Pro")
        #expect(status.usesSubscription)
    }

    /// `apiProvider` and `orgId` are deliberately not modeled; an unknown key
    /// must not fail the decode, or a CLI update would break sign-in detection.
    @Test func ignoresUnmodeledKeys() throws {
        let json = #"{"loggedIn":true,"subscriptionType":"max","brandNewField":123}"#
        let status = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(json.utf8)))

        #expect(status.loggedIn)
        #expect(status.displayPlan == "Max")
    }

    @Test func decodesSignedOut() throws {
        let status = try #require(
            ClaudeCodeConfiguration.decodeAuthStatus(Data(#"{"loggedIn":false}"#.utf8))
        )

        #expect(!status.loggedIn)
        #expect(status.displayPlan == nil)
        #expect(!status.usesSubscription)
    }

    /// An API-key or gateway login reports no `subscriptionType`. The UI keys
    /// off `usesSubscription` to avoid claiming a subscription that isn't there.
    @Test func loggedInWithoutSubscriptionIsNotSubscriptionBacked() throws {
        let json = #"{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}"#
        let status = try #require(ClaudeCodeConfiguration.decodeAuthStatus(Data(json.utf8)))

        #expect(status.loggedIn)
        #expect(status.displayPlan == nil)
        #expect(!status.usesSubscription)
    }

    @Test func malformedPayloadDecodesToNil() {
        #expect(ClaudeCodeConfiguration.decodeAuthStatus(Data("not json".utf8)) == nil)
        #expect(ClaudeCodeConfiguration.decodeAuthStatus(Data()) == nil)
        // `loggedIn` is required — a payload without it is not a status.
        #expect(ClaudeCodeConfiguration.decodeAuthStatus(Data(#"{"email":"a@b.c"}"#.utf8)) == nil)
    }

    @Test func cliVersionUsesFirstNonemptyLine() {
        let data = Data("\n2.1.37 (Claude Code)\nextra\n".utf8)
        #expect(ClaudeCodeConfiguration.decodeVersion(data) == "2.1.37 (Claude Code)")
        #expect(ClaudeCodeConfiguration.decodeVersion(Data()) == nil)
    }

    @Test func controlCommandCaptureCollectsBothPipes() async throws {
        let result = try #require(
            await ClaudeCodeProcessRunner.capture(
                executable: "/bin/sh",
                arguments: ["-c", "printf stdout-value; printf stderr-value >&2"],
                timeout: 2
            )
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "stdout-value")
        #expect(result.stderr == "stderr-value")
        #expect(!result.timedOut)
    }

    @Test func controlCommandCaptureTimesOutAndTerminates() async throws {
        let result = try #require(
            await ClaudeCodeProcessRunner.capture(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                timeout: 0.05
            )
        )
        #expect(result.timedOut)
        #expect(result.exitCode != 0)
    }

    @Test func oldCLIWithoutAuthJSONUsesManualStatusPath() async throws {
        let directory = try makeFakeClaude(
            """
            if [ "$1" = "--version" ]; then
              printf '2.1.37 (Claude Code)\\n'
            else
              printf 'Usage: claude [options] [command]\\n'
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = await ClaudeCodeConfiguration.setupState(
            env: ["PATH": directory.path]
        )
        #expect(state == .statusUnavailable(cliVersion: "2.1.37 (Claude Code)"))
    }

    @Test func modernCLISignedOutJSONIsRecognized() async throws {
        let directory = try makeFakeClaude(
            """
            if [ "$1" = "--version" ]; then
              printf '2.1.212 (Claude Code)\\n'
            else
              printf '{"loggedIn":false}\\n'
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = await ClaudeCodeConfiguration.setupState(
            env: ["PATH": directory.path]
        )
        #expect(state == .signedOut)
    }

    @Test func resultFailuresMapToTypedErrors() {
        #expect(
            ClaudeCodeProcessRunner.error(forFailureDetail: "authentication required")
                == .notAuthenticated(detail: "authentication required")
        )
        #expect(
            ClaudeCodeProcessRunner.error(forFailureDetail: "usage limit reached")
                == .rateLimited(detail: "usage limit reached")
        )
        #expect(
            ClaudeCodeProcessRunner.error(forFailureDetail: "upstream exploded")
                == .turnFailed("upstream exploded")
        )
    }

    @Test func coreModelNeverRetriesClaudeCodeFailures() {
        #expect(!CoreModelService.isRetryable(ClaudeCodeError.rateLimited(detail: "limit")))
        #expect(!CoreModelService.isRetryable(ClaudeCodeError.notAuthenticated(detail: "login")))
        #expect(!CoreModelService.isRetryable(ClaudeCodeError.turnFailed("failed")))
    }

    private func makeFakeClaude(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("claude", isDirectory: false)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return directory
    }

    // MARK: - Osaurus MCP bridge

    /// The dispatch tool must never be reachable: it can queue agent runs, and
    /// a queued run can start another Claude Code subprocess.
    @Test func scheduleToolIsNeverExposed() {
        let readOnly = ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: false)
        let full = ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: true)

        #expect(!readOnly.contains("osaurus_schedule"))
        #expect(!full.contains("osaurus_schedule"))
        #expect(ClaudeCodeConfiguration.osaurusExcludedTools.contains("osaurus_schedule"))
    }

    @Test func configWritesAreOptIn() {
        let readOnly = ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: false)
        let full = ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: true)

        #expect(readOnly.contains("osaurus_status"))
        #expect(!readOnly.contains("osaurus_agent"))
        #expect(full.contains("osaurus_agent"))
        #expect(full.count > readOnly.count)
    }

    /// Claude Code addresses MCP tools as `mcp__<server>__<tool>`; the bare
    /// name would silently never match the allow-list.
    @Test func allowedNamesUseClaudeCodeMCPNamespace() {
        let names = ClaudeCodeConfiguration.osaurusAllowedToolNames(allowConfigWrites: false)

        #expect(names.contains("mcp__osaurus__osaurus_status"))
        #expect(names.allSatisfy { $0.hasPrefix("mcp__osaurus__") })
    }

    @Test func osaurusToolsJoinTheAllowlistOnlyWhenGranted() {
        let without = ClaudeCodeConfiguration.allowedTools(allowWrites: false, allowShell: false)
        let with = ClaudeCodeConfiguration.allowedTools(
            allowWrites: false,
            allowShell: false,
            allowOsaurusTools: true
        )

        #expect(!without.contains { $0.hasPrefix("mcp__") })
        #expect(with.contains("mcp__osaurus__osaurus_status"))
        // The read-only built-ins survive either way.
        #expect(with.contains("Read"))
    }

    @Test func mcpConfigPointsAtTheGivenCLIWithAFilter() throws {
        let json = try #require(
            ClaudeCodeConfiguration.mcpConfigJSON(
                cliPath: "/Apps/Osaurus.app/Contents/Helpers/osaurus",
                allowConfigWrites: false
            )
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let osaurus = try #require(servers["osaurus"] as? [String: Any])

        #expect(osaurus["command"] as? String == "/Apps/Osaurus.app/Contents/Helpers/osaurus")
        let args = try #require(osaurus["args"] as? [String])
        #expect(args.first == "mcp")
        #expect(args.contains("--tools"))
        // The filter must be applied at the proxy, not left to the client.
        let patterns = try #require(args.last)
        #expect(patterns.contains("osaurus_status"))
        #expect(!patterns.contains("osaurus_schedule"))
        #expect(!patterns.contains("osaurus_agent"))
    }

    @Test func mcpConfigIsOnlyAttachedInAgentModeWithACLI() {
        let base = ClaudeCodeRunOptions(
            mode: .agent,
            allowOsaurusTools: true,
            osaurusCLIPath: "/tmp/osaurus"
        )
        #expect(base.attachesOsaurusMCP)

        var textOnly = base
        textOnly.mode = .textOnly
        #expect(!textOnly.attachesOsaurusMCP)

        var noGrant = base
        noGrant.allowOsaurusTools = false
        #expect(!noGrant.attachesOsaurusMCP)

        var noCLI = base
        noCLI.osaurusCLIPath = nil
        #expect(!noCLI.attachesOsaurusMCP)
    }

    @Test func mcpConfigFlagOnlyAppearsWhenPathGiven() {
        let without = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: ["Read"],
            systemPrompt: nil
        )
        #expect(!without.contains("--mcp-config"))

        let with = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .agent,
            allowedTools: ["Read"],
            systemPrompt: nil,
            mcpConfigPath: "/tmp/mcp.json"
        )
        #expect(with.contains("--mcp-config"))
        #expect(with.contains("/tmp/mcp.json"))
        // `--strict-mcp-config` must still be present, or the CLI would also
        // load whatever the user configured for their terminal sessions.
        #expect(with.contains("--strict-mcp-config"))
    }

    /// Text-only mode disables every tool, so an MCP config there would be
    /// dead weight at best and misleading at worst.
    @Test func textOnlyModeNeverAttachesMCP() {
        let args = ClaudeCodeConfiguration.arguments(
            model: .sonnet,
            mode: .textOnly,
            allowedTools: ["Read"],
            systemPrompt: nil,
            mcpConfigPath: "/tmp/mcp.json"
        )
        #expect(!args.contains("--mcp-config"))
    }

    // MARK: - Capability note

    /// The whole point: an un-bridged run must be told the tools are absent,
    /// or it spends the turn guessing at permission errors.
    @Test func unavailableNoteSaysToolsAreAbsentAndWhy() {
        let note = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: false,
            reason: .notEnabled
        )

        #expect(note.contains("NOT"))
        #expect(note.contains("osaurus_status"))
        // Must steer away from the exact failure mode observed in the wild.
        #expect(note.lowercased().contains("permission"))
    }

    /// "Switch it on" and "start the server" are different fixes; naming the
    /// right one saves the user a round trip.
    @Test func unavailableNoteDistinguishesTheCause() {
        let disabled = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: false,
            reason: .notEnabled
        )
        let serverDown = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: false,
            reason: .serverNotRunning
        )
        let textOnly = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: false,
            reason: .textOnlyMode
        )

        #expect(disabled != serverDown)
        #expect(serverDown != textOnly)
        #expect(serverDown.lowercased().contains("server"))
        #expect(textOnly.lowercased().contains("text-only"))
    }

    @Test func availableNoteListsExactlyTheGrantedTools() {
        let note = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: true,
            allowConfigWrites: false
        )

        #expect(note.contains("osaurus_status"))
        // Un-granted and excluded tools must not be advertised.
        #expect(!note.contains("osaurus_agent"))
        #expect(!note.contains("osaurus_schedule"))
        #expect(note.lowercased().contains("read-only"))
    }

    @Test func availableNoteDropsReadOnlyClaimWhenWritesGranted() {
        let note = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: true,
            allowConfigWrites: true
        )

        #expect(note.contains("osaurus_agent"))
        #expect(!note.lowercased().contains("read-only"))
        // Still never the dispatch tool.
        #expect(!note.contains("osaurus_schedule"))
    }

    @Test func displayPlanNormalizesWhitespaceAndEmpty() {
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: "  ").displayPlan == nil)
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: "").displayPlan == nil)
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: " pro ").displayPlan == "Pro")
    }
}
