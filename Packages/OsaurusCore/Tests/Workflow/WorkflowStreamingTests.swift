//
//  WorkflowStreamingTests.swift
//  osaurusTests
//
//  An inference step's tokens reach whoever watches the run while the
//  step runs, in order, and never reach history.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workflow streaming")
struct WorkflowStreamingTests {
    private actor Seen {
        var runs: [WorkflowRun] = []
        func add(_ run: WorkflowRun) { runs.append(run) }
    }

    private static func definition() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object([:]),
            outputSchema: WF.object(["text": WF.string]),
            nodes: [
                WorkflowNode(
                    id: "write",
                    name: "Write",
                    kind: .inference(InferenceSpec(modelSlot: "writer", instructions: "Write a line.")),
                    outputSchema: WF.object(["text": WF.string])
                ),
                WorkflowNode(
                    id: "shout",
                    name: "Shout",
                    kind: .code(CodeSpec(source: "async function run(input) { return input }")),
                    input: .object(["text": "{{nodes.write.output.text}}"]),
                    outputSchema: WF.object(["text": WF.string])
                ),
            ],
            edges: [WorkflowEdge(from: "write", to: "shout")],
            output: .object(["text": "{{nodes.shout.output.text}}"])
        )
    }

    @Test
    func inferenceStep_streamsInOrderAndClearsOnCompletion() async throws {
        let seen = Seen()
        let executor = ClosureExecutor { ctx, _ in
            if case .inference = ctx.node.kind {
                let sink = try #require(ctx.onDelta, "an inference step gets a delta sink")
                sink("Hel")
                try await Task.sleep(nanoseconds: 200_000_000)
                sink("lo")
                try await Task.sleep(nanoseconds: 200_000_000)
                sink(" world")
                return WorkflowNodeOutcome(output: .object(["text": .string("Hello world")]))
            }
            #expect(ctx.onDelta == nil, "only inference steps stream")
            return WorkflowNodeOutcome(output: ctx.input)
        }
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(Self.definition(), input: .object([:])),
            executor: executor,
            observer: { await seen.add($0) }
        ).execute()
        #expect(run.status == .completed, "\(String(describing: run.error))")
        #expect(run.output?.value(atPath: "text") == .string("Hello world"))
        #expect(run.node("write")?.streamed == nil, "cleared when the step ends")

        let partials = await seen.runs.compactMap { $0.node("write")?.streamed }
        #expect(!partials.isEmpty, "watchers saw the text form")
        #expect(partials.first == "Hel")
        #expect(partials.contains("Hello"), "\(partials)")
        for (a, b) in zip(partials, partials.dropFirst()) {
            #expect(b.hasPrefix(a), "text only grows: \(a) → \(b)")
        }
        let last = try #require(await seen.runs.last)
        #expect(last.node("write")?.streamed == nil)

        // History never carries partial text.
        let encoded = try JSONEncoder().encode(run)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\"streamed\""))
    }

    /// An agent's tool call that runs a workflow gets the same stream on
    /// its tool card: a row per step, the model step's text as it forms,
    /// and the outcome; partial text never enters the feed after the step.
    @Test
    @MainActor
    func toolCallFeed_mirrorsStepsAndStreamedText_thenFinishes() async throws {
        let installed = InstalledWorkflow(template: WF.template(Self.definition(), name: "Liner"), bindings: InstallBindings())
        let registry = SubagentFeedRegistry.makeForTesting()
        // A private store: a running row in the shared database shows up as
        // abandoned to relaunch tests that share the in-memory process database.
        let database = WorkflowRunDatabase()
        try database.openInMemory()
        let store = WorkflowRunStore(database: database)
        let caller = WorkflowCaller(kind: .agent, agentName: "Helper", sessionID: "s1", toolCallID: "call-7")
        var run = WorkflowRun(
            workflowID: installed.id, workflowName: "Liner", templateID: installed.template.id, templateVersion: 1,
            caller: caller, input: .object([:]), nodeIDs: ["write", "shout"])
        store.record(run)
        let live = WorkflowCallFeed.attach(
            runID: run.id, toolCallID: "call-7", workflow: installed, caller: caller, store: store, registry: registry)
        #expect(registry.feed(for: "call-7") === live.feed)
        #expect(live.feed.kindId == WorkflowCallFeed.kindId && live.feed.title == "Liner")

        run.update("write") { $0.status = .running; $0.attempts = 1; $0.streamed = "Hel" }
        live.apply(run)
        run.update("write") { $0.streamed = "Hello wor" }
        live.apply(run)
        run.update("write") { $0.status = .done; $0.streamed = nil; $0.model = "foundation"
            $0.startedAt = Date(timeIntervalSince1970: 100); $0.finishedAt = Date(timeIntervalSince1970: 100.5)
        }
        run.update("shout") { $0.status = .running; $0.attempts = 1 }
        live.apply(run)
        var events = live.feed.currentEvents()
        #expect(events.map(\.kind) == [.phase, .phase, .response, .outcome, .phase], "\(events.map(\.kind))")
        #expect(events[1].title == "Write")
        #expect(events[2].detail == "Hello wor", "deltas coalesce into one growing row")
        #expect(events[3].detail == "foundation · 500 ms")
        #expect(events[4].title == "Shout")

        // Streamed text after a step ended is never shown again.
        run.update("shout") { $0.status = .failed; $0.error = "boom" }
        run.status = .failed
        run.error = WorkflowRunError(nodeID: "shout", reason: "boom")
        live.apply(run)
        events = live.feed.currentEvents()
        #expect(events.last?.kind == .error && events.last?.detail == "boom")
        guard case .finished(let success, let summary) = live.feed.currentStatus() else {
            Issue.record("the feed ends with the run")
            return
        }
        #expect(!success && summary == "Shout: boom")
        // A second finish (the tool call returning) changes nothing.
        live.finish(nil)
        #expect(live.feed.currentStatus() == .finished(success: false, summary: "Shout: boom"))
    }

    @Test
    func mapItems_doNotStream() async throws {
        let def = WorkflowDefinition(
            inputSchema: WF.object(["words": .object(["type": .string("array")])]),
            outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "each",
                    name: "Each",
                    kind: .map(
                        MapSpec(
                            items: "{{input.words}}",
                            step: .object([
                                "kind": .string("inference"),
                                "inference": .object([
                                    "model_slot": .string("writer"), "instructions": .string("Say {{item}}"),
                                ]),
                                "output_schema": WF.object(["text": WF.string]),
                            ])
                        )
                    )
                )
            ],
            output: .object([:])
        )
        let run = await WorkflowRunner(
            request: WorkflowRunnerTests.request(def, input: .object(["words": .array([.string("a"), .string("b")])])),
            executor: ClosureExecutor { ctx, _ in
                #expect(ctx.onDelta == nil, "a map item shares the map node's record; its tokens would interleave")
                return WorkflowNodeOutcome(output: .object(["text": .string("x")]))
            }
        ).execute()
        #expect(run.status == .completed, "\(String(describing: run.error))")
    }

    @Test
    func collect_forwardsVisibleDeltasAndDropsSentinels() async throws {
        let stream = AsyncThrowingStream<String, Error> { c in
            c.yield("{\"a\":")
            c.yield("\u{FFFE}billing:{}")
            c.yield("")
            c.yield(" 1}")
            c.finish()
        }
        let deltas = Seen()
        actor Deltas { var list: [String] = []; func add(_ s: String) { list.append(s) } }
        let got = Deltas()
        let text = try await CoreModelService.collect(stream) { delta in
            Task { await got.add(delta) }
        }
        #expect(text == "{\"a\": 1}")
        try await Task.sleep(nanoseconds: 50_000_000)
        let list = await got.list
        #expect(Set(list) == ["{\"a\":", " 1}"], "\(list)")
        _ = deltas
    }

    @Test
    func backends_declareWhetherStreamingAppliesTheSchema() {
        struct Plain: ModelService {
            var id: String { "plain" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { true }
            func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?)
                async throws -> String
            { "" }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        #expect(Plain().streamsResponseSchema, "the default: a backend that honors the schema on both paths")
        #expect(
            !FoundationModelService().streamsResponseSchema,
            "Foundation applies its GenerationSchema one-shot only"
        )
    }

    @Test
    func nodeRun_streamedRoundTripsOnlyWhilePresent() throws {
        var node = NodeRun(nodeID: "n", status: .running)
        node.streamed = "part"
        let data = try JSONEncoder().encode(node)
        #expect(String(decoding: data, as: UTF8.self).contains("\"streamed\":\"part\""))
        #expect(try JSONDecoder().decode(NodeRun.self, from: data).streamed == "part")
        node.streamed = nil
        #expect(!String(decoding: try JSONEncoder().encode(node), as: UTF8.self).contains("streamed"))
    }
}
