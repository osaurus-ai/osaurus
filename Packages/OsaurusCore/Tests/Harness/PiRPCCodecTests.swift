//
//  PiRPCCodecTests.swift
//  osaurusTests
//
//  Pi `--mode rpc` codec against wire shapes captured from Pi 0.83.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Pi RPC codec")
struct PiRPCCodecTests {

    private func startedCodec(_ text: String = "hi", images: [HarnessImage] = []) throws -> (PiRPCCodec, String) {
        let codec = PiRPCCodec(runtimeName: "Pi")
        let records = try codec.beginTurn(HarnessUserMessage(text: text, images: images))
        let first = try #require(records.first)
        let id = try #require(HarnessFixtures.json(first)["id"] as? String)
        return (codec, id)
    }

    @Test func promptCommandCarriesTextAndImages() throws {
        let codec = PiRPCCodec(runtimeName: "Pi")
        let image = HarnessImage(data: Data([0x89, 0x50]), mimeType: "image/png")
        let records = try codec.beginTurn(HarnessUserMessage(text: "look", images: [image]))

        #expect(records.count == 1)
        let command = HarnessFixtures.json(try #require(records.first))
        #expect(command["type"] as? String == "prompt")
        #expect(command["message"] as? String == "look")
        #expect((command["id"] as? String)?.hasPrefix("osaurus-") == true)
        let images = try #require(command["images"] as? [[String: Any]])
        #expect(images.first?["type"] as? String == "image")
        #expect(images.first?["mimeType"] as? String == "image/png")
        #expect(images.first?["data"] as? String == Data([0x89, 0x50]).base64EncodedString())
    }

    @Test func aFullTurnDecodesInOrder() throws {
        let (codec, id) = try startedCodec()
        let (events, replies) = HarnessFixtures.decodeAll(codec, [
            #"{"id":"\#(id)","type":"response","command":"prompt","success":true}"#,
            #"{"type":"agent_start"}"#,
            #"{"type":"turn_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"hmm"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hel"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"lo\u2028there"}}"#,
            #"{"type":"tool_execution_start","toolCallId":"c1","toolName":"bash","args":{"command":"ls"}}"#,
            #"{"type":"tool_execution_update","toolCallId":"c1","toolName":"bash","partialResult":{}}"#,
            #"{"type":"tool_execution_end","toolCallId":"c1","toolName":"bash","result":{},"isError":true}"#,
            #"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"input":10,"output":42}}}"#,
            #"{"type":"turn_end"}"#,
            #"{"type":"agent_end","messages":[]}"#,
            #"{"type":"agent_settled"}"#,
        ])

        // The acknowledgement arrived before `agent_start`, so the codec
        // asks once whether a run actually started.
        #expect(replies.count == 1)
        #expect(HarnessFixtures.json(replies[0])["type"] as? String == "get_state")
        #expect(events.count == 7)
        #expect(events[0] == .reasoning("hmm"))
        #expect(events.visibleText == "Hello\u{2028}there")
        #expect(events[3] == .toolStarted(callId: "c1", name: "bash"))
        #expect(events[4] == .toolFinished(callId: "c1", name: "bash", isError: true))
        if case .stats(let tokens, _, let stopReason) = events[5] {
            #expect(tokens == 42)
            #expect(stopReason == "stop")
        } else {
            Issue.record("expected stats, got \(events[5])")
        }
        #expect(events[6] == .turnCompleted)
    }

    /// `agent_end` is not the end of a turn: Pi may still retry or compact.
    @Test func onlyAgentSettledEndsTheTurn() throws {
        let (codec, _) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"agent_start"}"#,
            #"{"type":"agent_end","messages":[]}"#,
            #"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":1000,"errorMessage":"overloaded"}"#,
        ])
        #expect(!events.contains(.turnCompleted))
        #expect(events.contains { if case .notice = $0 { return true } else { return false } })
    }

    @Test func aRejectedPromptIsTypedAsSignIn() throws {
        let (codec, id) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"id":"\#(id)","type":"response","command":"prompt","success":false,"error":"No API key found for anthropic. Use /login."}"#
        ])
        guard case .turnFailed(.notAuthenticated(let runtime, _)) = events.first else {
            Issue.record("expected notAuthenticated, got \(events)")
            return
        }
        #expect(runtime == "Pi")
    }

    @Test func otherRejectionsStayRejections() throws {
        let (codec, id) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"id":"\#(id)","type":"response","command":"prompt","success":false,"error":"Agent is busy"}"#
        ])
        #expect(events == [.turnFailed(.rejected(runtime: "Pi", detail: "Agent is busy"))])
    }

    /// A slash command an extension handles never starts a run, so no
    /// `agent_settled` follows; one `get_state` tells the two cases apart.
    @Test func aHandledCommandEndsAfterOneStateProbe() throws {
        let (codec, id) = try startedCodec("/hello")
        let ack = codec.decode(line: Data(#"{"id":"\#(id)","type":"response","command":"prompt","success":true}"#.utf8))
        #expect(ack.events.isEmpty)
        let probe = HarnessFixtures.json(try #require(ack.replies.first))
        #expect(probe["type"] as? String == "get_state")
        let probeId = try #require(probe["id"] as? String)

        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"id":"\#(probeId)","type":"response","command":"get_state","success":true,"data":{"model":{"id":"unknown","provider":"unknown"},"isStreaming":false,"sessionId":"s"}}"#
        ])
        #expect(events == [.turnCompleted])
    }

    @Test func aStreamingStateProbeWaitsForSettle() throws {
        let (codec, id) = try startedCodec()
        let ack = codec.decode(line: Data(#"{"id":"\#(id)","type":"response","command":"prompt","success":true}"#.utf8))
        let probe = try #require(ack.replies.first)
        let probeId = try #require(HarnessFixtures.json(probe)["id"] as? String)

        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"id":"\#(probeId)","type":"response","command":"get_state","success":true,"data":{"isStreaming":true}}"#,
            #"{"type":"agent_start"}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"ok"}}"#,
            #"{"type":"agent_settled"}"#,
        ])
        #expect(events.visibleText == "ok")
        #expect(events.last == .turnCompleted)
    }

    @Test func aModelErrorFailsTheTurn() throws {
        let (codec, _) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"agent_start"}"#,
            #"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"429 rate limit exceeded"}}"#,
            #"{"type":"agent_settled"}"#,
        ])
        #expect(events == [.turnFailed(.rateLimited(runtime: "Pi", detail: "429 rate limit exceeded"))])
    }

    @Test func anAbortedTurnCompletesQuietly() throws {
        let (codec, _) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"agent_start"}"#,
            #"{"type":"message_end","message":{"role":"assistant","stopReason":"aborted","errorMessage":"Request was aborted"}}"#,
            #"{"type":"agent_settled"}"#,
        ])
        #expect(events.last == .turnCompleted)
        #expect(!events.contains { if case .turnFailed = $0 { return true } else { return false } })
    }

    @Test func deltasOutsideATurnAreIgnored() {
        let codec = PiRPCCodec(runtimeName: "Pi")
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"stray"}}"#,
            #"{"type":"agent_settled"}"#,
            "not json",
            "",
        ])
        #expect(events.isEmpty)
    }

    @Test func abortIsTheInterruptRecord() throws {
        let codec = PiRPCCodec(runtimeName: "Pi")
        let records = codec.interruptRecords()
        #expect(records.count == 1)
        #expect(HarnessFixtures.json(try #require(records.first))["type"] as? String == "abort")
    }

    @Test func dialogRequestsAndResponses() throws {
        let (codec, _) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"extension_ui_request","id":"s1","method":"select","title":"Pick","options":["a","b"]}"#,
            #"{"type":"extension_ui_request","id":"c1","method":"confirm","title":"Sure?","message":"Delete it"}"#,
            #"{"type":"extension_ui_request","id":"i1","method":"input","title":"Name","placeholder":"type"}"#,
            #"{"type":"extension_ui_request","id":"e1","method":"editor","title":"Edit","prefill":"draft"}"#,
            #"{"type":"extension_ui_request","id":"n1","method":"notify","message":"Saved","notifyType":"info"}"#,
            #"{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"k"}"#,
        ])

        #expect(events == [
            .dialog(HarnessDialogRequest(id: "s1", title: "Pick", kind: .select(options: ["a", "b"]))),
            .dialog(HarnessDialogRequest(id: "c1", title: "Sure?", kind: .confirm(message: "Delete it"))),
            .dialog(HarnessDialogRequest(id: "i1", title: "Name", kind: .input(placeholder: "type"))),
            .dialog(HarnessDialogRequest(id: "e1", title: "Edit", kind: .editor(prefill: "draft"))),
            .notice("Saved", isError: false),
        ])
        #expect(codec.pendingDialogIds == ["s1", "c1", "i1", "e1"])

        let select = HarnessFixtures.json(try #require(codec.dialogResponse(id: "s1", response: .value("b"))))
        #expect(select["type"] as? String == "extension_ui_response")
        #expect(select["id"] as? String == "s1")
        #expect(select["value"] as? String == "b")

        let confirm = HarnessFixtures.json(try #require(codec.dialogResponse(id: "c1", response: .confirmed(false))))
        #expect(confirm["confirmed"] as? Bool == false)

        let cancel = HarnessFixtures.json(try #require(codec.dialogResponse(id: "i1", response: .cancelled)))
        #expect(cancel["cancelled"] as? Bool == true)

        #expect(codec.pendingDialogIds == ["e1"])
        // Answering twice (or an unknown id) writes nothing.
        #expect(codec.dialogResponse(id: "s1", response: .value("a")) == nil)
        #expect(codec.dialogResponse(id: "zzz", response: .cancelled) == nil)
    }

    @Test func compactionAndExtensionErrorsBecomeNotices() throws {
        let (codec, _) = try startedCodec()
        let (events, _) = HarnessFixtures.decodeAll(codec, [
            #"{"type":"compaction_start","reason":"threshold"}"#,
            #"{"type":"compaction_end","reason":"threshold","aborted":false,"errorMessage":"too small"}"#,
            #"{"type":"extension_error","extensionPath":"/x.ts","event":"tool_call","error":"boom"}"#,
        ])
        #expect(events.count == 3)
        #expect(events[2] == .notice("boom", isError: true))
        if case .notice(_, let isError) = events[1] { #expect(isError) }
    }

    @Test func launchPlanUsesTheRuntimeArgumentsAndContract() throws {
        let directory = try HarnessFixtures.temporaryDirectory("pi-plan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = HarnessRuntime(
            name: "Spotlight",
            kind: .piRPC,
            executable: "~/.local/bin/spotlight",
            arguments: ["--mode", "rpc", "--session-dir", "/tmp/s/{chat_id}", "--append-system-prompt", "{system_prompt_file}"],
            environment: ["SPOTLIGHT_MODE": "case", "OSAURUS_CHAT_ID": "spoofed"]
        )
        let chatId = UUID()
        let context = HarnessFixtures.context(
            runtime: runtime,
            chatId: chatId,
            workingDirectory: directory,
            systemPrompt: "Be terse.",
            apiBase: "http://127.0.0.1:1337/v1"
        )

        let plan = try PiRPCAdapter(runtime: runtime).launchPlan(context: context, token: "osh_test")
        defer { plan.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        let spec = plan.spec

        #expect(spec.executable == "~/.local/bin/spotlight")
        #expect(Array(spec.arguments.prefix(2)) == ["--mode", "rpc"])
        #expect(spec.arguments[3] == "/tmp/s/\(chatId.uuidString.lowercased())")
        let promptFile = try #require(plan.temporaryFiles.first)
        #expect(spec.arguments[5] == promptFile.path)
        #expect(try String(contentsOf: promptFile, encoding: .utf8) == "Be terse.")
        let attributes = try FileManager.default.attributesOfItem(atPath: promptFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!spec.arguments.contains("Be terse."))

        #expect(spec.environment["SPOTLIGHT_MODE"] == "case")
        #expect(spec.environment["OSAURUS_CHAT_ID"] == chatId.uuidString.lowercased(), "the contract must win")
        #expect(spec.environment["OSAURUS_AGENT_TOKEN"] == "osh_test")
        #expect(spec.environment["OSAURUS_MCP_BRIDGE_GRANT"] == "osh_test")
        #expect(spec.environment["OSAURUS_API_BASE"] == "http://127.0.0.1:1337/v1")
        #expect(spec.environment["OSAURUS_WORKING_DIRECTORY"] == directory.path)
        #expect(spec.workingDirectory == directory)
        #expect(spec.removingEnvironment.contains("CLAUDECODE"))
        #expect(spec.removingEnvironment.contains("OSAURUS_MCP_BRIDGE_GRANT"))
        #expect(!spec.removingEnvironment.contains("ANTHROPIC_API_KEY"), "Pi may legitimately use API keys")
    }

    @Test func piTokensDeferToTheAgentToolPolicyAndCannotWriteConfig() throws {
        let directory = try HarnessFixtures.temporaryDirectory("pi-scope")
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = PiRPCAdapter(runtime: HarnessRuntime(name: "Pi", kind: .piRPC))
        let context = HarnessFixtures.context(runtime: adapter.runtime, workingDirectory: directory)
        #expect(adapter.tokenToolScope(context: context) == nil)
        #expect(!adapter.tokenAllowsConfigWrites(context: context))
        #expect(adapter.retryMode(after: .turnFailed(runtime: "Pi", detail: "already in use"), context: context) == nil)
    }
}
