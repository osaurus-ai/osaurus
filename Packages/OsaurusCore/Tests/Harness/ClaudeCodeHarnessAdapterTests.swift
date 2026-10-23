//
//  ClaudeCodeHarnessAdapterTests.swift
//  osaurusTests
//
//  The argv, files, and environment a Claude Code chat process starts with,
//  and the stream-json codec. No subprocess.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code harness adapter")
struct ClaudeCodeHarnessAdapterTests {

    private let runtime = HarnessRuntime.builtInClaudeCode

    private func plan(
        _ config: ClaudeCodeAgentConfig = .default,
        systemPrompt: String? = nil,
        cliPath: String? = nil,
        serverReachable: Bool = false,
        sessionMode: HarnessLaunchContext.SessionMode = .forceNew,
        runtime: HarnessRuntime? = nil,
        token: String? = "osh_token",
        agentId: UUID = UUID(),
        in directory: URL
    ) throws -> (HarnessLaunchPlan, HarnessLaunchContext) {
        let runtime = runtime ?? self.runtime
        let context = HarnessFixtures.context(
            runtime: runtime,
            agentId: agentId,
            workingDirectory: directory,
            systemPrompt: systemPrompt,
            claudeCode: config,
            osaurusCLIPath: cliPath,
            apiBase: "http://127.0.0.1:1337/v1",
            serverReachable: serverReachable,
            sessionMode: sessionMode
        )
        return (try ClaudeCodeHarnessAdapter(runtime: runtime).launchPlan(context: context, token: token), context)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func cleanup(_ plan: HarnessLaunchPlan) {
        for url in plan.temporaryFiles { try? FileManager.default.removeItem(at: url) }
    }

    @Test func persistentStreamJSONSessionKeyedByChat() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-plan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, context) = try plan(in: directory)
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        #expect(plan.spec.executable == "claude")
        #expect(args.contains("--print"))
        #expect(value(after: "--input-format", in: args) == "stream-json")
        #expect(value(after: "--output-format", in: args) == "stream-json")
        #expect(args.contains("--verbose"))
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(value(after: "--session-id", in: args) == context.chatId.uuidString.lowercased())
        #expect(!args.contains("--resume"))
        #expect(!args.contains("--no-session-persistence"))
        #expect(plan.spec.workingDirectory == directory)
    }

    @Test func resumeUsesTheSameChatKey() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-resume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, context) = try plan(sessionMode: .forceResume, in: directory)
        defer { cleanup(plan) }
        #expect(value(after: "--resume", in: plan.spec.arguments) == context.chatId.uuidString.lowercased())
        #expect(!plan.spec.arguments.contains("--session-id"))
    }

    @Test func automaticModeFindsAnExistingSessionFile() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-auto")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configDir = directory.appendingPathComponent("claude-config", isDirectory: true)
        let chatId = UUID()
        let project = configDir.appendingPathComponent("projects/-some-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let custom = HarnessRuntime(
            name: "Claude Code",
            kind: .claudeCode,
            environment: ["CLAUDE_CONFIG_DIR": configDir.path]
        )
        let adapter = ClaudeCodeHarnessAdapter(runtime: custom)
        let context = HarnessFixtures.context(runtime: custom, chatId: chatId, workingDirectory: directory)

        let fresh = try adapter.launchPlan(context: context, token: nil)
        #expect(fresh.spec.arguments.contains("--session-id"))

        try Data().write(to: project.appendingPathComponent("\(chatId.uuidString.lowercased()).jsonl"))
        let resumed = try adapter.launchPlan(context: context, token: nil)
        #expect(value(after: "--resume", in: resumed.spec.arguments) == chatId.uuidString.lowercased())
    }

    @Test func agentModeIsFailClosedByDefault() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-closed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, _) = try plan(in: directory)
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        #expect(value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(value(after: "--allowedTools", in: args) == "Read,Grep,Glob")
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("--tools"))
    }

    @Test func writesAreScopedToTheWorkingFolderAndShellIsOptIn() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-writes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, _) = try plan(ClaudeCodeAgentConfig(allowWrites: true, allowShell: true), in: directory)
        defer { cleanup(plan) }
        let allowed = try #require(value(after: "--allowedTools", in: plan.spec.arguments)).split(separator: ",")

        #expect(allowed.contains("Edit(/\(directory.path)/**)"))
        #expect(allowed.contains("Bash"))
        #expect(!allowed.contains("Edit"), "an unscoped Edit would reach the whole disk")
    }

    /// Claude matches `Edit(...)` against real paths. Foundation's
    /// `resolvingSymlinksInPath` maps `/private/tmp` back to `/tmp`, which
    /// would make every write under a temp folder silently denied.
    @Test func writeRuleUsesTheRealPath() {
        #expect(ClaudeCodeConfiguration.scopedWriteRule(root: URL(fileURLWithPath: "/tmp")) == "Edit(//private/tmp/**)")
        #expect(
            ClaudeCodeConfiguration.scopedWriteRule(root: URL(fileURLWithPath: "/private/tmp/"))
                == "Edit(//private/tmp/**)"
        )
        #expect(
            ClaudeCodeConfiguration.scopedWriteRule(root: URL(fileURLWithPath: "/no/such/dir"))
                == "Edit(//no/such/dir/**)"
        )
    }

    @Test func textOnlyModeDisablesEveryTool() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-text")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ClaudeCodeAgentConfig(mode: .textOnly, allowWrites: true, allowShell: true, allowOsaurusTools: true)
        let (plan, context) = try plan(config, cliPath: "/tmp/osaurus", serverReachable: true, in: directory)
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        #expect(value(after: "--tools", in: args) == "")
        #expect(!args.contains("--allowedTools"))
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("--permission-mode"))
        #expect(ClaudeCodeHarnessAdapter(runtime: runtime).tokenToolScope(context: context) == [])
    }

    @Test func modelComesFromTheAgent() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-model")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaultPlan, _) = try plan(in: directory)
        let (opusPlan, _) = try plan(ClaudeCodeAgentConfig(model: "opus"), in: directory)
        let (customPlan, _) = try plan(ClaudeCodeAgentConfig(model: " claude-sonnet-4-5 "), in: directory)

        #expect(value(after: "--model", in: defaultPlan.spec.arguments) == "sonnet")
        #expect(value(after: "--model", in: opusPlan.spec.arguments) == "opus")
        #expect(value(after: "--model", in: customPlan.spec.arguments) == "claude-sonnet-4-5")
    }

    @Test func instructionsTravelInAPrivateFileNeverArgv() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-prompt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "You are the case agent. Internal codename: BLUEBIRD."
        let (plan, _) = try plan(systemPrompt: "  \(secret)\n", in: directory)
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        #expect(!args.contains { $0.contains("BLUEBIRD") })
        #expect(!args.contains("--append-system-prompt"))
        #expect(!args.contains("--system-prompt"))
        let path = try #require(value(after: "--append-system-prompt-file", in: args))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == secret)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(plan.temporaryFiles.map(\.path).contains(path))
        #expect(!path.hasPrefix(directory.path), "private files never sit inside the harness's cwd")
    }

    @Test func blankInstructionsWriteNoFile() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-blank")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, _) = try plan(systemPrompt: "   \n", in: directory)
        #expect(!plan.spec.arguments.contains("--append-system-prompt-file"))
        #expect(plan.temporaryFiles.isEmpty)
    }

    @Test func osaurusToolsAttachThroughATokenInAPrivateMCPConfig() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-mcp")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ClaudeCodeAgentConfig(allowOsaurusTools: true)
        let (plan, context) = try plan(config, cliPath: "/Apps/osaurus", serverReachable: true, in: directory)
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        let mcpPath = try #require(value(after: "--mcp-config", in: args))
        let root = HarnessFixtures.json(try Data(contentsOf: URL(fileURLWithPath: mcpPath)))
        let server = try #require((root["mcpServers"] as? [String: Any])?["osaurus"] as? [String: Any])
        #expect(server["command"] as? String == "/Apps/osaurus")
        #expect((server["env"] as? [String: String])?[HarnessGrantStore.environmentKey] == "osh_token")
        #expect(!args.contains { $0.contains("osh_token") })

        let allowed = try #require(value(after: "--allowedTools", in: args)).split(separator: ",").map(String.init)
        #expect(allowed.contains("mcp__osaurus__osaurus_inspect"))
        #expect(allowed.contains("mcp__osaurus__osaurus_help"))
        #expect(!allowed.contains("mcp__osaurus__osaurus_config"))

        let adapter = ClaudeCodeHarnessAdapter(runtime: runtime)
        #expect(adapter.tokenToolScope(context: context) == ["osaurus_inspect", "osaurus_help"])
        #expect(!adapter.tokenAllowsConfigWrites(context: context))

        let promptPath = try #require(value(after: "--append-system-prompt-file", in: args))
        let note = try String(contentsOfFile: promptPath, encoding: .utf8)
        #expect(note.contains("osaurus_inspect"))
        #expect(!note.contains("do NOT"))
    }

    @Test func configWritesNeedTheirOwnOptIn() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-config-writes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ClaudeCodeAgentConfig(allowOsaurusTools: true, allowOsaurusConfigWrites: true)
        let (plan, context) = try plan(
            config,
            cliPath: "/Apps/osaurus",
            serverReachable: true,
            agentId: Agent.defaultId,
            in: directory
        )
        defer { cleanup(plan) }

        let allowed = try #require(value(after: "--allowedTools", in: plan.spec.arguments))
        #expect(allowed.contains("mcp__osaurus__osaurus_config"))
        let adapter = ClaudeCodeHarnessAdapter(runtime: runtime)
        #expect(adapter.tokenAllowsConfigWrites(context: context))
        #expect(adapter.tokenToolScope(context: context)?.contains("osaurus_config") == true)
    }

    /// `osaurus_config` only runs for the Default agent, so a custom agent's
    /// opt-in must not attach a tool that would always refuse.
    @Test func configWritesAreIgnoredForCustomAgents() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-config-writes-custom")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ClaudeCodeAgentConfig(allowOsaurusTools: true, allowOsaurusConfigWrites: true)
        let (plan, context) = try plan(config, cliPath: "/Apps/osaurus", serverReachable: true, in: directory)
        defer { cleanup(plan) }

        let allowed = try #require(value(after: "--allowedTools", in: plan.spec.arguments))
        #expect(allowed.contains("mcp__osaurus__osaurus_help"))
        #expect(!allowed.contains("mcp__osaurus__osaurus_config"))
        let mcpPath = try #require(value(after: "--mcp-config", in: plan.spec.arguments))
        #expect(!(try String(contentsOfFile: mcpPath, encoding: .utf8)).contains("osaurus_config"))
        let adapter = ClaudeCodeHarnessAdapter(runtime: runtime)
        #expect(!adapter.tokenAllowsConfigWrites(context: context))
        #expect(adapter.tokenToolScope(context: context) == ["osaurus_inspect", "osaurus_help"])
    }

    @Test func aStoppedServerSaysSoInsteadOfAttaching() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-server-down")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ClaudeCodeAgentConfig(allowOsaurusTools: true)
        let (plan, _) = try plan(config, cliPath: "/Apps/osaurus", serverReachable: false, in: directory)
        defer { cleanup(plan) }

        #expect(!plan.spec.arguments.contains("--mcp-config"))
        let promptPath = try #require(value(after: "--append-system-prompt-file", in: plan.spec.arguments))
        let note = try String(contentsOfFile: promptPath, encoding: .utf8)
        #expect(note.contains("NOT"))
        #expect(note.lowercased().contains("server"))
    }

    @Test func environmentKeepsTheSubscriptionAndTheContract() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-env")
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = HarnessRuntime(
            name: "Work Claude",
            kind: .claudeCode,
            executable: "/opt/claude",
            arguments: ["--add-dir", "{cwd}/../shared"],
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/work-claude"]
        )
        let (plan, context) = try plan(runtime: custom, in: directory)
        defer { cleanup(plan) }
        let spec = plan.spec

        #expect(spec.removingEnvironment.contains("ANTHROPIC_API_KEY"))
        #expect(spec.removingEnvironment.contains("CLAUDECODE"))
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == "/tmp/work-claude")
        #expect(spec.environment["OSAURUS_CHAT_ID"] == context.chatId.uuidString.lowercased())
        #expect(spec.environment["OSAURUS_AGENT_TOKEN"] == "osh_token")
        #expect(spec.executable == "/opt/claude")
        #expect(Array(spec.arguments.suffix(2)) == ["--add-dir", "\(directory.path)/../shared"])
        #expect(spec.runtimeName == "Work Claude")
    }

    @Test func retryFlipsTheSessionModeOnlyForKnownFailures() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = ClaudeCodeHarnessAdapter(runtime: runtime)
        let context = HarnessFixtures.context(runtime: runtime, workingDirectory: directory)

        #expect(
            adapter.retryMode(
                after: .turnFailed(runtime: "Claude Code", detail: "Session ID abc is already in use."),
                context: context
            ) == .forceResume
        )
        #expect(
            adapter.retryMode(
                after: .exited(runtime: "Claude Code", code: 1, stderrTail: "No conversation found with session ID: abc"),
                context: context
            ) == .forceNew
        )
        #expect(adapter.retryMode(after: .turnFailed(runtime: "Claude Code", detail: "overloaded"), context: context) == nil)
    }

    // MARK: - Codec

    @Test func userMessageIsOneStreamJSONLine() throws {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let image = HarnessImage(data: Data([1, 2, 3]), mimeType: "image/jpeg")
        let records = try codec.beginTurn(HarnessUserMessage(text: "what is this?", images: [image]))

        #expect(records.count == 1)
        let root = HarnessFixtures.json(try #require(records.first))
        #expect(root["type"] as? String == "user")
        let message = try #require(root["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2)
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == Data([1, 2, 3]).base64EncodedString())
        #expect(content[1]["text"] as? String == "what is this?")
    }

    @Test func aResultFrameEndsTheTurn() {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let (events, replies) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"system","subtype":"init","session_id":"s","tools":[]}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"done"}}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"result":"done","usage":{"output_tokens":20}}"#,
        ])
        #expect(replies.isEmpty)
        #expect(events.contains(.reasoning("plan")))
        #expect(events.visibleText == "done", "the assembled assistant frame must not double the text")
        #expect(events.last == .turnCompleted)
        #expect(events.contains { if case .stats = $0 { return true } else { return false } })
    }

    @Test func anErrorResultFailsTheTurnTyped() {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login","duration_ms":5}"#
        ])
        guard case .turnFailed(.notAuthenticated) = events.last else {
            Issue.record("expected notAuthenticated, got \(events)")
            return
        }
    }

    @Test func interruptIsAControlRequest() throws {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let root = HarnessFixtures.json(try #require(codec.interruptRecords().first))
        #expect(root["type"] as? String == "control_request")
        #expect((root["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
        #expect((root["request_id"] as? String)?.isEmpty == false)
        #expect(codec.pendingDialogIds.isEmpty)
        #expect(codec.dialogResponse(id: "x", response: .cancelled) == nil)
    }
}
