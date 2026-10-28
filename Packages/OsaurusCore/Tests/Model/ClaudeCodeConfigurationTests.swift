//
//  ClaudeCodeConfigurationTests.swift
//  osaurusTests
//
//  Model-id, PATH-resolution, setup-state, and Osaurus-tool coverage for the
//  Claude Code runtime. Token-free — only fake `claude` scripts are spawned.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code configuration")
struct ClaudeCodeConfigurationTests {

    // MARK: - Model ids

    @Test func legacyPickerIdsMapToModels() {
        #expect(ClaudeCodeModel.fromPickerId("claude-code/sonnet") == .sonnet)
        #expect(ClaudeCodeModel.fromPickerId("claude-code/opus") == .opus)
        #expect(ClaudeCodeModel.fromPickerId("claude-code/haiku") == .haiku)
    }

    @Test func foreignModelIdsAreRejected() {
        #expect(ClaudeCodeModel.fromPickerId("sonnet") == nil)
        #expect(ClaudeCodeModel.fromPickerId("claude-code/") == nil)
        #expect(ClaudeCodeModel.fromPickerId("claude-code/gpt-5") == nil)
        #expect(ClaudeCodeModel.fromPickerId("anthropic/claude-sonnet-4") == nil)
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

    @Test func processRegistryTerminatesChildrenForAppShutdown() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5"]
        try process.run()

        let registry = HarnessProcessRegistry()
        registry.register(UUID(), terminator: ProcessTerminator(process: process))
        #expect(registry.liveCount() == 1)

        await registry.terminateAll()
        #expect(!process.isRunning)
        #expect(registry.liveCount() == 0)
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
            command: directory.appendingPathComponent("claude").path
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
            command: directory.appendingPathComponent("claude").path
        )
        #expect(state == .signedOut)
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

    @Test func configWritesAreOptIn() {
        let readOnly = ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: false)
        let full = ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: true)

        #expect(readOnly == ["osaurus_inspect", "osaurus_help"])
        #expect(full == ["osaurus_inspect", "osaurus_help", "osaurus_config"])
    }

    /// Every name handed to the CLI must be a tool the Osaurus registry
    /// actually serves; a stale name is silently never callable.
    @MainActor
    @Test func exposedNamesAreRealRegistryTools() {
        let registered = Set(ToolRegistry.shared.listTools().map(\.name))
            .union(ConfigDeclarativeDomain.domain.tools.map(\.name))
        for name in ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: true) {
            #expect(registered.contains(name), "\(name) is not a registered tool")
        }
    }

    /// Claude Code addresses MCP tools as `mcp__<server>__<tool>`; the bare
    /// name would silently never match the allow-list.
    @Test func allowedNamesUseClaudeCodeMCPNamespace() {
        let names = ClaudeCodeConfiguration.osaurusAllowedToolNames(allowConfigWrites: false)

        #expect(names == ["mcp__osaurus__osaurus_inspect", "mcp__osaurus__osaurus_help"])
        #expect(names.allSatisfy { $0.hasPrefix("mcp__osaurus__") })
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
        #expect(patterns.contains("osaurus_inspect"))
        #expect(!patterns.contains("osaurus_config"))
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
        #expect(note.contains("osaurus_inspect"))
        #expect(note.contains("Allow Osaurus read tools"))
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

        #expect(note.contains("osaurus_inspect"))
        #expect(note.contains("osaurus_help"))
        // Un-granted tools must not be advertised.
        #expect(!note.contains("osaurus_config"))
        #expect(note.lowercased().contains("read-only"))
    }

    @Test func availableNoteDropsReadOnlyClaimWhenWritesGranted() {
        let note = ClaudeCodeConfiguration.osaurusToolsSystemNote(
            available: true,
            allowConfigWrites: true
        )

        #expect(note.contains("osaurus_config"))
        #expect(!note.lowercased().contains("read-only"))
    }

    @Test func displayPlanNormalizesWhitespaceAndEmpty() {
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: "  ").displayPlan == nil)
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: "").displayPlan == nil)
        #expect(ClaudeCodeAuthStatus(loggedIn: true, subscriptionType: " pro ").displayPlan == "Pro")
    }
}
