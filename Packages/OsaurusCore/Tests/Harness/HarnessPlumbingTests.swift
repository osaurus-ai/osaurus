//
//  HarnessPlumbingTests.swift
//  osaurusTests
//
//  JSONL framing, the child environment and PATH, agent tokens, and the
//  runtime probe.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Harness line framing")
struct HarnessLineFramerTests {

    @Test func splitsOnLFAndBuffersPartialRecords() {
        var framer = HarnessLineFramer()
        #expect(framer.append(Data(#"{"a":1}"#.utf8)).isEmpty)
        let lines = framer.append(Data("\n{\"b\":2}\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(framer.flush().map { String(decoding: $0, as: UTF8.self) } == #"{"c""#)
        #expect(framer.flush() == nil)
    }

    /// U+2028 / U+2029 are legal unescaped inside JSON strings. A
    /// Unicode-aware splitter (`String.components(separatedBy: .newlines)`,
    /// Node's `readline`) breaks the record there.
    @Test func lineSeparatorInsideARecordDoesNotSplitIt() throws {
        var framer = HarnessLineFramer()
        let record = "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"a\u{2028}b\u{2029}c\"}}"
        let lines = framer.append(Data((record + "\n").utf8))
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let root = try #require(HarnessJSON.object(line))
        let delta = (root["assistantMessageEvent"] as? [String: Any])?["delta"] as? String
        #expect(delta == "a\u{2028}b\u{2029}c")
    }

    @Test func trimsCRAndSkipsBlankLines() {
        var framer = HarnessLineFramer()
        let lines = framer.append(Data("one\r\n\n\r\ntwo\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
    }

    @Test func multibyteCharactersSplitAcrossChunksSurvive() {
        var framer = HarnessLineFramer()
        let bytes = Array("\"🦖\"\n".utf8)
        #expect(framer.append(Data(bytes[0 ..< 3])).isEmpty)
        let lines = framer.append(Data(bytes[3...]))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["\"🦖\""])
    }
}

@Suite("Harness environment")
struct HarnessEnvironmentTests {

    @Test func contractNamesAreStable() {
        // Documented in docs/HARNESS_RUNTIMES.md; harness authors key off these.
        #expect(HarnessEnvironment.chatId == "OSAURUS_CHAT_ID")
        #expect(HarnessEnvironment.agentId == "OSAURUS_AGENT_ID")
        #expect(HarnessEnvironment.agentToken == "OSAURUS_AGENT_TOKEN")
        #expect(HarnessEnvironment.apiBase == "OSAURUS_API_BASE")
        #expect(HarnessEnvironment.workingDirectory == "OSAURUS_WORKING_DIRECTORY")
        #expect(HarnessEnvironment.bridgeGrant == "OSAURUS_MCP_BRIDGE_GRANT")
        // `MCPCommand` in the CLI duplicates this literal; `MCPBridgeGrantTests` pins its side.
        #expect(HarnessGrantStore.headerName == "X-Osaurus-Bridge-Grant")
    }

    @Test func contractWithoutTokenOrServerOmitsThoseKeys() throws {
        let directory = try HarnessFixtures.temporaryDirectory("env-contract")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = HarnessFixtures.context(
            runtime: HarnessRuntime(name: "Pi", kind: .piRPC),
            workingDirectory: directory
        )
        let env = HarnessEnvironment.contract(context: context, token: nil)
        #expect(env.keys.sorted() == ["OSAURUS_AGENT_ID", "OSAURUS_CHAT_ID", "OSAURUS_WORKING_DIRECTORY"])
    }

    @Test func childEnvironmentStripsThenOverlays() {
        let env = HarnessProcess.childEnvironment(
            inherited: [
                "PATH": "/inherited/bin",
                "HOME": "/Users/me",
                "CLAUDECODE": "1",
                "OSAURUS_MCP_BRIDGE_GRANT": "stale-from-parent",
                "ANTHROPIC_API_KEY": "sk-should-go",
            ],
            loginShellEntries: ["/login/first", "/inherited/bin"],
            overlay: ["OSAURUS_MCP_BRIDGE_GRANT": "osh_fresh", "EXTRA": "1"],
            removing: HarnessEnvironment.alwaysRemoved.union(["ANTHROPIC_API_KEY"])
        )
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["OSAURUS_MCP_BRIDGE_GRANT"] == "osh_fresh")
        #expect(env["EXTRA"] == "1")
        #expect(env["HOME"] == "/Users/me")
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(path.first == "/login/first", "the login shell's order wins over the GUI's sparse PATH")
        #expect(path.filter { $0 == "/inherited/bin" }.count == 1)
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test func anExplicitPATHOverlayIsRespected() {
        let env = HarnessProcess.childEnvironment(
            inherited: ["PATH": "/usr/bin"],
            loginShellEntries: ["/login"],
            overlay: ["PATH": "/only/this"],
            removing: []
        )
        #expect(env["PATH"] == "/only/this")
    }

    /// npm-installed `claude` / `pi` are `#!/usr/bin/env node` scripts; the
    /// `node` the user's version manager placed beside them must win.
    @Test func envShebangSiblingIsPutFirst() throws {
        let directory = try HarnessFixtures.temporaryDirectory("shebang")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try HarnessFixtures.writeExecutable("#!/usr/bin/env node\n", named: "pi", in: directory)
        try HarnessFixtures.writeExecutable("#!/bin/sh\n", named: "node", in: directory)

        let path = HarnessProcess.prependingShebangSibling(of: script.path, to: "/usr/bin:\(directory.path):/bin")
        #expect(path == "\(directory.path):/usr/bin:/bin")

        let binary = try HarnessFixtures.writeExecutable("#!/bin/sh\n", named: "plain", in: directory)
        #expect(HarnessProcess.prependingShebangSibling(of: binary.path, to: "/usr/bin") == "/usr/bin")
    }

    @Test func aGUISparsePathStillFindsALoginShellInstall() async throws {
        let directory = try HarnessFixtures.temporaryDirectory("login-path")
        defer { try? FileManager.default.removeItem(at: directory) }
        try HarnessFixtures.writeExecutable("#!/bin/sh\n", named: "osaurus-fake-harness", in: directory)

        let process = try? HarnessProcess(
            spec: HarnessProcess.LaunchSpec(
                executable: "osaurus-fake-harness",
                arguments: [],
                environment: [:],
                removingEnvironment: [],
                workingDirectory: directory,
                runtimeName: "Fake"
            ),
            loginShellEntries: [directory.path],
            inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(process?.resolvedExecutable == directory.appendingPathComponent("osaurus-fake-harness").path)
        await process?.shutdown(grace: 1)

        #expect(throws: HarnessError.self) {
            _ = try HarnessProcess(
                spec: HarnessProcess.LaunchSpec(
                    executable: "osaurus-fake-harness",
                    arguments: [],
                    environment: [:],
                    removingEnvironment: [],
                    workingDirectory: directory,
                    runtimeName: "Fake"
                ),
                loginShellEntries: [],
                inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        }
    }

    @Test func processRegistryKillsLiveHarnessesOnQuit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        let registry = HarnessProcessRegistry()
        registry.register(UUID(), terminator: ProcessTerminator(process: process))
        await registry.terminateAll()
        #expect(!process.isRunning)
        #expect(registry.liveCount() == 0)
    }
}

@Suite("Harness agent tokens")
struct HarnessGrantStoreTests {

    @Test func mintResolveRevoke() {
        let store = HarnessGrantStore()
        let agentId = UUID()
        let token = store.mint(agentId: agentId, allowsConfigWrites: false)

        #expect(token.hasPrefix("osh_"))
        #expect(store.resolve(token)?.agentId == agentId)
        #expect(store.resolve(token)?.expiresAt == nil, "process tokens live until revoked")
        #expect(store.resolve("osh_not-a-token") == nil)

        store.revoke(token)
        #expect(store.resolve(token) == nil)
    }

    @Test func tokensAreDistinctAndURLSafe() {
        let store = HarnessGrantStore()
        var seen = Set<String>()
        for _ in 0 ..< 50 {
            let token = store.mint(agentId: UUID(), allowsConfigWrites: false)
            #expect(seen.insert(token).inserted)
            #expect(token.count >= 47)
            #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
        }
        store.revokeAll()
        #expect(store.liveGrantCount() == 0)
    }

    @Test func anExplicitLifetimeExpires() {
        let store = HarnessGrantStore()
        let now = Date()
        let token = store.mint(agentId: UUID(), allowsConfigWrites: false, lifetime: 60, now: now)
        #expect(store.resolve(token, now: now.addingTimeInterval(30)) != nil)
        #expect(store.resolve(token, now: now.addingTimeInterval(61)) == nil)
        #expect(store.liveGrantCount(now: now.addingTimeInterval(61)) == 0)
    }

    @Test func scopeNeverReachesSpawningLoopOrBuiltInLoopTools() {
        let wide = HarnessGrant(agentId: UUID(), allowsConfigWrites: true, allowedToolNames: nil, expiresAt: nil)
        for name in HarnessGrantStore.deniedToolNames.union(HarnessGrantStore.builtInLoopToolNames) {
            #expect(!wide.permitsTool(name), "\(name) must never be reachable with a harness token")
        }
        #expect(HarnessGrantStore.deniedToolNames.contains(SubagentCapabilityRegistry.spawnAgentToolName))
        #expect(wide.permitsTool("osaurus_config"))
        #expect(wide.permitsTool("search_web"))
    }

    @Test func configWritesAndAllowListsAreFixedAtMint() {
        let readOnly = HarnessGrant(
            agentId: UUID(),
            allowsConfigWrites: false,
            allowedToolNames: ["osaurus_inspect", "osaurus_config"],
            expiresAt: nil
        )
        #expect(readOnly.permitsTool("osaurus_inspect"))
        #expect(!readOnly.permitsTool("osaurus_config"), "the write opt-in beats the allow-list")
        #expect(!readOnly.permitsTool("osaurus_help"))

        let none = HarnessGrant(agentId: UUID(), allowsConfigWrites: false, allowedToolNames: [], expiresAt: nil)
        #expect(!none.permitsTool("osaurus_inspect"))
    }

    @Test func bearerOnlyCountsWhenItIsALiveToken() {
        let store = HarnessGrantStore()
        let token = store.mint(agentId: UUID(), allowsConfigWrites: false)

        #expect(store.presentedToken(bridgeHeader: nil, authorization: "Bearer \(token)") == token)
        #expect(store.presentedToken(bridgeHeader: nil, authorization: "Bearer osk-v1.some-api-key") == nil)
        #expect(store.presentedToken(bridgeHeader: nil, authorization: token) == nil)
        // The header is an explicit claim: a bad one is reported, not ignored.
        #expect(store.presentedToken(bridgeHeader: "osh_bad", authorization: "Bearer \(token)") == "osh_bad")
        #expect(store.presentedToken(bridgeHeader: "", authorization: nil) == nil)
    }

    @Test func routesAreConfinedToInferenceAndMCP() {
        let routes = HarnessGrantStore.allowedRoutes
        for allowed in ["/mcp/call", "/mcp/tools", "/chat/completions", "/messages", "/responses", "/models"] {
            #expect(routes.contains(allowed))
        }
        for denied in ["/admin/cache-stats", "/agents", "/pair", "/memory/ingest", "/mcp/oauth"] {
            #expect(!routes.contains(denied))
        }
    }

    @Test func mcpConfigCarriesTheTokenInEnvNeverArgv() throws {
        let json = try #require(
            ClaudeCodeConfiguration.mcpConfigJSON(
                cliPath: "/usr/local/bin/osaurus",
                allowConfigWrites: false,
                bridgeGrant: "osh_abc123"
            )
        )
        let root = HarnessFixtures.json(Data(json.utf8))
        let server = try #require((root["mcpServers"] as? [String: Any])?["osaurus"] as? [String: Any])
        #expect((server["env"] as? [String: String])?[HarnessGrantStore.environmentKey] == "osh_abc123")
        let args = try #require(server["args"] as? [String])
        #expect(!args.contains { $0.contains("osh_abc123") })

        let withoutToken = try #require(
            ClaudeCodeConfiguration.mcpConfigJSON(cliPath: "/usr/local/bin/osaurus", allowConfigWrites: false, bridgeGrant: nil)
        )
        let bare = HarnessFixtures.json(Data(withoutToken.utf8))
        #expect(((bare["mcpServers"] as? [String: Any])?["osaurus"] as? [String: Any])?["env"] == nil)
    }
}

@Suite("Harness runtime probe", .serialized)
struct HarnessRuntimeProbeTests {

    private func fakePi(model: String? = nil) throws -> (URL, HarnessRuntime) {
        let directory = try HarnessFixtures.temporaryDirectory("probe")
        let script = try HarnessFixtures.writeExecutable(HarnessFixtures.fakePiScript, named: "fake-pi", in: directory)
        var env: [String: String] = [:]
        if let model { env["FAKE_MODEL"] = model }
        return (directory, HarnessRuntime(name: "Fake Pi", kind: .piRPC, executable: script.path, environment: env))
    }

    @Test func aConfiguredModelIsReady() async throws {
        let (directory, runtime) = try fakePi(model: #"{"id":"qwen3","provider":"osaurus"}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await HarnessRuntimeProbe.run(runtime, timeout: 10)
        #expect(result.status == .ready)
        #expect(result.message.contains("osaurus/qwen3"))
        #expect(result.resolvedExecutable == runtime.executable)
    }

    @Test func piWithoutAModelNeedsSetup() async throws {
        let (directory, runtime) = try fakePi()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await HarnessRuntimeProbe.run(runtime, timeout: 10)
        #expect(result.status == .needsSetup)
    }

    @Test func aCommandThatIsNotRPCTimesOut() async throws {
        let directory = try HarnessFixtures.temporaryDirectory("probe-silent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try HarnessFixtures.writeExecutable("#!/bin/sh\ncat > /dev/null\n", named: "silent", in: directory)
        let result = await HarnessRuntimeProbe.run(
            HarnessRuntime(name: "Silent", kind: .piRPC, executable: script.path, arguments: []),
            timeout: 1
        )
        #expect(result.status == .failed)
        #expect(result.message.contains("--mode rpc"))
    }

    @Test func aMissingCommandFails() async {
        let result = await HarnessRuntimeProbe.run(
            HarnessRuntime(name: "Ghost", kind: .piRPC, executable: "osaurus-no-such-harness"),
            timeout: 1
        )
        #expect(result.status == .failed)
        #expect(result.resolvedExecutable == nil)
    }

    @Test func aSignedOutClaudeNeedsSetup() async throws {
        let directory = try HarnessFixtures.temporaryDirectory("probe-claude")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try HarnessFixtures.writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then printf '2.1.308 (Claude Code)\\n'; else printf '{"loggedIn":false}\\n'; fi
            """,
            named: "claude",
            in: directory
        )
        let result = await HarnessRuntimeProbe.run(
            HarnessRuntime(name: "Claude Code", kind: .claudeCode, executable: script.path)
        )
        #expect(result.status == .needsSetup)
        #expect(result.resolvedExecutable == script.path)
    }
}
