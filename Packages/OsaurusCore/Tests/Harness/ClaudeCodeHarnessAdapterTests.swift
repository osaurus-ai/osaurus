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
        #expect(value(after: "--tools", in: args) == "Read,Grep,Glob,TodoWrite")
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

    /// A tool `dontAsk` would refuse is hidden so the model never calls it,
    /// and a granted tool is never hidden — a deny beats the allow.
    @Test(arguments: [false, true], [false, true])
    func ungrantedBuiltinsAreHiddenFromTheModel(allowWrites: Bool, allowShell: Bool) throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-hidden")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, _) = try plan(
            ClaudeCodeAgentConfig(allowWrites: allowWrites, allowShell: allowShell),
            in: directory
        )
        defer { cleanup(plan) }
        let args = plan.spec.arguments
        let hidden = try #require(value(after: "--disallowedTools", in: args)).split(separator: ",").map(String.init)
        let allowed = try #require(value(after: "--allowedTools", in: args)).split(separator: ",").map(String.init)

        for tool in ["Bash", "Monitor", "CronCreate", "LSP", "RemoteTrigger", "Workflow"] {
            #expect(hidden.contains(tool) == !allowShell)
        }
        #expect(allowed.contains("Monitor") == allowShell)
        #expect(!allowed.contains("CronCreate"), "shell access never auto-approves scheduling")
        for tool in ["Edit", "Write", "NotebookEdit"] {
            #expect(hidden.contains(tool) == !allowWrites)
        }
        #expect(hidden.contains("WebFetch"))
        #expect(hidden.contains("WebSearch"))
        for tool in ClaudeCodeConfiguration.defaultAllowedTools {
            #expect(!hidden.contains(tool))
        }
        #expect(Set(hidden).isDisjoint(with: allowed))

        // `--disallowedTools` alone leaves newer built-ins (ListAgents,
        // SendMessage, Cron*) visible, so the visible set is an allow list.
        let visible = Set(try #require(value(after: "--tools", in: args)).split(separator: ",").map(String.init))
        #expect(visible.contains("TodoWrite"), "permission-free built-ins stay available")
        #expect(visible.isDisjoint(with: hidden))
        for tool in ["Task", "ListAgents", "SendMessage", "WebFetch"] {
            #expect(!visible.contains(tool))
        }
        #expect(visible.contains("Bash") == allowShell)
        #expect(visible.contains("Write") == allowWrites)
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
        #expect(!args.contains("--disallowedTools"))
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

    /// `--print` runs ignore the `showThinkingSummaries` setting and stream
    /// empty thinking; only the explicit flag returns summaries.
    @Test func everyLaunchRequestsThinkingSummaries() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-thinking")
        defer { try? FileManager.default.removeItem(at: directory) }
        for config in [ClaudeCodeAgentConfig.default, ClaudeCodeAgentConfig(mode: .textOnly)] {
            let (plan, _) = try plan(config, in: directory)
            defer { cleanup(plan) }
            #expect(value(after: "--thinking-display", in: plan.spec.arguments) == "summarized")
            #expect(!plan.spec.arguments.contains("--settings"), "the user's own settings stay untouched")
        }
    }

    @Test func effortIsPassedOnlyWhenSet() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-effort")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaultPlan, _) = try plan(in: directory)
        let (xhighPlan, _) = try plan(ClaudeCodeAgentConfig(model: "fable", effort: " XHigh "), in: directory)
        let (bogusPlan, _) = try plan(ClaudeCodeAgentConfig(effort: "turbo"), in: directory)
        defer { [defaultPlan, xhighPlan, bogusPlan].forEach(cleanup) }

        #expect(!defaultPlan.spec.arguments.contains("--effort"))
        #expect(value(after: "--effort", in: xhighPlan.spec.arguments) == "xhigh")
        #expect(value(after: "--model", in: xhighPlan.spec.arguments) == "fable")
        #expect(!bogusPlan.spec.arguments.contains("--effort"))
    }

    @Test func effortSurvivesAgentRoundTripAndOldAgentsDecode() throws {
        let config = ClaudeCodeAgentConfig(model: "opus", effort: "max")
        let decoded = try JSONDecoder().decode(ClaudeCodeAgentConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.resolvedEffort == .max)

        let legacy = try JSONDecoder().decode(ClaudeCodeAgentConfig.self, from: Data(#"{"model":"opus"}"#.utf8))
        #expect(legacy.effort == nil)
        #expect(legacy.resolvedEffort == nil)
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

    // MARK: - Architect

    /// The Architect's job is the draft, so its run sees exactly its Osaurus
    /// tools and no built-ins, whatever its Claude Code options say.
    @Test(arguments: [ClaudeCodeAgentConfig.default, ClaudeCodeAgentConfig(
        mode: .textOnly, allowWrites: true, allowShell: true, allowOsaurusTools: false)])
    func architectSeesOnlyItsDraftTools(config: ClaudeCodeAgentConfig) throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-architect")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, context) = try plan(
            config,
            systemPrompt: "You are the Architect.",
            cliPath: "/Apps/osaurus",
            serverReachable: true,
            agentId: Agent.architectId,
            in: directory
        )
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        #expect(value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(value(after: "--tools", in: args) == "")
        #expect(!args.contains("--disallowedTools"))
        let allowed = Set(try #require(value(after: "--allowedTools", in: args)).split(separator: ",").map(String.init))
        #expect(allowed == Set(HarnessGrantStore.architectToolNames.map { "mcp__osaurus__\($0)" }))
        #expect(allowed.contains("mcp__osaurus__workflow_draft"))
        #expect(allowed.contains("mcp__osaurus__workflow_propose_save"))
        #expect(!allowed.contains("mcp__osaurus__clarify"), "clarify needs the native chat UI")

        let mcpPath = try #require(value(after: "--mcp-config", in: args))
        let root = HarnessFixtures.json(try Data(contentsOf: URL(fileURLWithPath: mcpPath)))
        let server = try #require((root["mcpServers"] as? [String: Any])?["osaurus"] as? [String: Any])
        #expect((server["env"] as? [String: String])?[HarnessGrantStore.environmentKey] == "osh_token")

        let adapter = ClaudeCodeHarnessAdapter(runtime: runtime)
        #expect(adapter.tokenToolScope(context: context) == HarnessGrantStore.architectToolNames)
        #expect(!adapter.tokenAllowsConfigWrites(context: context))
    }

    @Test func architectWithoutTheServerSaysItCannotBuild() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-architect-down")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (plan, _) = try plan(
            cliPath: "/Apps/osaurus",
            serverReachable: false,
            agentId: Agent.architectId,
            in: directory
        )
        defer { cleanup(plan) }
        let args = plan.spec.arguments

        #expect(value(after: "--tools", in: args) == "")
        #expect(!args.contains("--mcp-config"))
        #expect(!args.contains("--allowedTools"))
        let promptPath = try #require(value(after: "--append-system-prompt-file", in: args))
        let note = try String(contentsOfFile: promptPath, encoding: .utf8)
        #expect(note.contains("workflow tools are NOT connected"))
        #expect(note.lowercased().contains("server"))
    }

    /// Long `workflow_test` runs go through MCP; the CLI's default tool
    /// timeout would cut them off.
    @Test func mcpToolTimeoutIsRaisedUnlessTheRuntimeSetsIt() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-mcp-timeout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaultPlan, _) = try plan(in: directory)
        let custom = HarnessRuntime(name: "Claude", kind: .claudeCode, environment: ["MCP_TOOL_TIMEOUT": "1000"])
        let (customPlan, _) = try plan(runtime: custom, in: directory)
        defer { [defaultPlan, customPlan].forEach(cleanup) }

        #expect(defaultPlan.spec.environment["MCP_TOOL_TIMEOUT"] == "900000")
        #expect(customPlan.spec.environment["MCP_TOOL_TIMEOUT"] == "1000")
    }

    @Test func promptSnapshotIsTurnedOffOnlyWhenTheCLIHasTheFlag() throws {
        let directory = try HarnessFixtures.temporaryDirectory("claude-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = ClaudeCodeHarnessAdapter(runtime: runtime)
        let old = HarnessFixtures.context(runtime: runtime, workingDirectory: directory, sessionMode: .forceNew)
        let new = HarnessFixtures.context(
            runtime: runtime,
            workingDirectory: directory,
            sessionMode: .forceNew,
            claudeCodeFeatures: ClaudeCodeCLIFeatures(systemPromptSnapshot: true)
        )

        #expect(!(try adapter.launchPlan(context: old, token: nil)).spec.arguments.contains("--system-prompt-snapshot"))
        #expect(value(after: "--system-prompt-snapshot", in: try adapter.launchPlan(context: new, token: nil).spec.arguments) == "off")
        #expect(ClaudeCodeCLIFeatures.parse(help: "  --system-prompt-snapshot <mode>  ...").systemPromptSnapshot)
        #expect(!ClaudeCodeCLIFeatures.parse(help: "  --system-prompt <prompt>  ...").systemPromptSnapshot)
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

    @Test func aDeniedToolNamesTheToggleWithoutTheCLIText() {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"Bash","input":{}}}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_01","content":"Permission to use Bash has been denied because Claude Code is running in don't ask mode."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_02","content":"exit code 1"}]}}"#,
        ])
        #expect(
            events.contains(
                .toolFinished(
                    callId: "toolu_01",
                    name: "Bash",
                    isError: true,
                    message: ClaudeCodeConfiguration.permissionDeniedMessage(tool: "Bash")
                )
            )
        )
        #expect(events.contains(.toolFinished(callId: "toolu_02", name: "", isError: true)))
        #expect(ClaudeCodeConfiguration.permissionDeniedMessage(tool: "Bash").contains("Allow shell commands"))
        #expect(ClaudeCodeConfiguration.permissionDeniedMessage(tool: "Write").contains("Allow file changes"))
        #expect(!ClaudeCodeConfiguration.permissionDeniedMessage(tool: "WebFetch").contains("Allow"))
    }

    /// Text from CLI 2.1.308 for a tool `dontAsk` refuses.
    @Test func the2_1_308DenialTextIsRecognized() {
        #expect(
            ClaudeCodeStreamDecoder.isPermissionDenial(
                "Permission to use Bash has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work around this denial in malicious ways."
            )
        )
    }

    /// A call to a hidden or nonexistent tool says so instead of the generic
    /// "the remote agent reported this tool call failed".
    @Test func aCallToAMissingToolSaysItDoesNotExist() {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_09","name":"WebFetch","input":{}}}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_09","content":"<tool_use_error>Error: No such tool available: WebFetch</tool_use_error>"}]}}"#,
        ])
        #expect(
            events.contains(
                .toolFinished(
                    callId: "toolu_09",
                    name: "WebFetch",
                    isError: true,
                    message: ClaudeCodeConfiguration.unavailableToolMessage(tool: "WebFetch")
                )
            )
        )
    }

    @Test func osaurusToolCardsShowTheBareName() {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_05","name":"mcp__osaurus__workflow_draft","input":{}}}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":false,"tool_use_id":"toolu_05","content":"ok"}]}}"#,
        ])
        #expect(events.contains(.toolStarted(callId: "toolu_05", name: "workflow_draft")))
        #expect(!events.contains { "\($0)".contains("mcp__osaurus__") })
    }

    /// A permission prompt nobody can answer would hang the turn; it is
    /// denied, and any other host question is refused.
    @Test func controlRequestsAreAnsweredSoTheTurnNeverHangs() throws {
        let codec = ClaudeCodeHarnessCodec(runtimeName: "Claude Code")
        let (events, replies) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"control_request","request_id":"req_1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#,
            #"{"type":"control_request","request_id":"req_2","request":{"subtype":"hook_callback"}}"#,
        ])
        #expect(events.isEmpty)
        #expect(replies.count == 2)

        let deny = HarnessFixtures.json(replies[0])
        #expect(deny["type"] as? String == "control_response")
        let denyResponse = try #require(deny["response"] as? [String: Any])
        #expect(denyResponse["subtype"] as? String == "success")
        #expect(denyResponse["request_id"] as? String == "req_1")
        #expect((denyResponse["response"] as? [String: Any])?["behavior"] as? String == "deny")

        let refuse = try #require(HarnessFixtures.json(replies[1])["response"] as? [String: Any])
        #expect(refuse["subtype"] as? String == "error")
        #expect(refuse["request_id"] as? String == "req_2")
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
