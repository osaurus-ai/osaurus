//
//  WorkflowFlowStoryTests.swift
//  OsaurusCoreTests
//
//  The full view in plain words: what you give and get, the one-line peek
//  at what a step made, where the run stands at the end, whether anything
//  leaves this Mac, and a map step's item states, live or from its output.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowFlowStoryTests {

    private static func run(_ ids: [String], input: JSONValue = .object([:])) -> WorkflowRun {
        WorkflowRun(
            workflowID: UUID(), workflowName: "Flow", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: input, nodeIDs: ids)
    }

    private static func badge(_ kind: WorkflowStepBadge.Kind, _ tone: WorkflowStepBadge.Tone = .caution)
        -> WorkflowStepBadge
    {
        WorkflowStepBadge(kind: kind, label: kind.rawValue, detail: nil, tone: tone)
    }

    private static func schema(_ properties: [String: String], required: [String] = []) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(
                properties.mapValues { .object(["type": .string("string"), "title": .string($0)]) }),
            "required": .array(required.map { .string($0) }),
        ])
    }

    // MARK: - Peek

    @Test func peek_countsListsAndTheItemsOfAMapStep() {
        #expect(WorkflowFlowStory.peek(.array([.number(1), .number(2), .number(3)])) == "3 items")
        #expect(WorkflowFlowStory.peek(.array([.string("a")])) == "1 item")
        let mapped = JSONValue.object(["items": .array([.null, .null]), "failed": .array([])])
        #expect(WorkflowFlowStory.peek(mapped) == "2 items")
    }

    @Test func peek_takesTheFirstLineOfTextAndClipsIt() {
        #expect(WorkflowFlowStory.peek(.string("\n  Sunny, 72°\nWind 5 mph")) == "Sunny, 72°")
        let long = String(repeating: "a", count: 100)
        let clipped = WorkflowFlowStory.peek(.string(long), limit: 10)
        #expect(clipped == String(repeating: "a", count: 9) + "…")
    }

    @Test func peek_opensAOneFieldObjectAndSaysNothingForEmptyValues() {
        #expect(WorkflowFlowStory.peek(.object(["summary": .string("All good")])) == "All good")
        #expect(WorkflowFlowStory.peek(.object(["ok": .bool(true)])) == "Yes")
        #expect(WorkflowFlowStory.peek(nil) == nil)
        #expect(WorkflowFlowStory.peek(.null) == nil)
        #expect(WorkflowFlowStory.peek(.string("  \n ")) == nil)
        #expect(WorkflowFlowStory.peek(.object([:])) == nil)
    }

    // MARK: - You give, you get

    @Test func given_namesTheFieldsBeforeARunAndShowsTheAnswersAfter() {
        let def = WorkflowDefinition(inputSchema: Self.schema(["topic": "Topic", "tone": "Tone"], required: ["topic"]))
        #expect(WorkflowFlowStory.given(def, run: nil).map(\.label) == ["Topic", "Tone"])
        #expect(WorkflowFlowStory.given(def, run: nil).allSatisfy { $0.text.isEmpty })

        let run = Self.run([], input: .object(["topic": .string("Solar panels")]))
        let given = WorkflowFlowStory.given(def, run: run)
        #expect(given.map(\.text) == ["Solar panels", "—"])
    }

    @Test func gotten_showsTheResultByFieldOnceThereIsOne() {
        let def = WorkflowDefinition(outputSchema: Self.schema(["post": "Post", "words": "Word count"]))
        #expect(WorkflowFlowStory.gotten(def, run: nil).map(\.label) == ["Post", "Word count"])

        var run = Self.run([])
        run.output = .object(["post": .string("Hello\nworld"), "words": .number(2)])
        let gotten = WorkflowFlowStory.gotten(def, run: run)
        #expect(gotten.map(\.label) == ["Post", "Word count"])
        #expect(gotten.first?.text == "Hello")
    }

    @Test func gotten_withoutASchemaPeeksAtTheWholeResult() {
        var run = Self.run([])
        run.output = .string("Done and dusted")
        #expect(WorkflowFlowStory.gotten(WorkflowDefinition(), run: run) == [.init(label: "", text: "Done and dusted")])
    }

    @Test func entries_keepDistinctIdsWhenTitlesRepeat() {
        let def = WorkflowDefinition(
            inputSchema: Self.schema(["a": "Name", "b": "Name"]),
            outputSchema: Self.schema(["x": "Result", "y": "Result"], required: ["x", "x"]))
        let given = WorkflowFlowStory.given(def, run: nil)
        #expect(given.map(\.label) == ["Name", "Name"])
        #expect(Set(given.map(\.id)).count == 2)
        #expect(Set(WorkflowFlowStory.gotten(def, run: nil).map(\.id)).count == 2)

        var run = Self.run([])
        run.output = .object(["x": .string("one"), "y": .string("two")])
        let gotten = WorkflowFlowStory.gotten(def, run: run)
        #expect(gotten.map(\.text) == ["one", "two"])
        #expect(Set(gotten.map(\.id)).count == 2)
    }

    @Test func endNote_saysWhereTheRunStands() {
        let def = WorkflowDefinition(nodes: [WorkflowNode(id: "write", name: "Write", kind: .wait(WaitSpec(seconds: "1")))])
        #expect(WorkflowFlowStory.endNote(def, run: nil) == nil)

        var run = Self.run(["write"])
        run.status = .running
        #expect(WorkflowFlowStory.endNote(def, run: run) == "On its way…")

        run.status = .failed
        run.error = WorkflowRunError(nodeID: "write", reason: "boom")
        #expect(WorkflowFlowStory.endNote(def, run: run) == "It stopped at “Write”.")

        run.status = .completed
        run.error = nil
        run.output = .string("ok")
        #expect(WorkflowFlowStory.endNote(def, run: run) == nil)

        run.output = .object([:])
        #expect(WorkflowFlowStory.endNote(def, run: run) == "It finished.", "an empty result still says the run ended")
    }

    // MARK: - Where the data goes

    @Test func reach_staysOnThisMacWhenNoStepGoesOnline() {
        let badges: [String: [WorkflowStepBadge]] = [
            "a": [Self.badge(.localModel, .neutral)],
            "b": [Self.badge(.files), Self.badge(.shell, .risky)],
        ]
        let reach = WorkflowFlowStory.reach(["a", "b"], badges: badges)
        #expect(reach.steps.isEmpty)
        #expect(reach.title == "Stays on this Mac")
    }

    @Test func reach_sortsStepsByHowTheirDataLeaves() {
        let unchosen = WorkflowStepBadge(kind: .localModel, label: "Model not chosen", detail: nil, tone: .neutral)
        let fallback = WorkflowStepBadge(
            kind: .localModel, label: "Local model, else provider", detail: nil, tone: .neutral)
        let badges: [String: [WorkflowStepBadge]] = [
            "a": [Self.badge(.cloudModel)],
            "b": [unchosen, Self.badge(.network)],
            "c": [fallback],
            "d": [Self.badge(.localModel, .neutral)],
        ]
        let reach = WorkflowFlowStory.reach(["a", "b", "c", "d"], badges: badges)
        #expect(reach.cloud == ["a"])
        #expect(reach.online == ["b"])
        #expect(reach.unsure == ["b", "c"])
        #expect(reach.steps == ["a", "b", "c"])
        #expect(reach.title == "Goes online · uses a cloud model")
    }

    @Test func reach_titleNamesWhatLeaves() {
        #expect(WorkflowFlowStory.Reach(cloud: ["a"]).title == "Uses a cloud model")
        #expect(WorkflowFlowStory.Reach(online: ["a"]).title == "Goes online")
        #expect(WorkflowFlowStory.Reach(unsure: ["a"]).title == "May leave this Mac")
    }

    @Test @MainActor func reach_onRealBadgesForAStepThatReachesTheWeb() {
        let node = WorkflowNode(
            id: "fetch", name: "Fetch", kind: .http(HTTPSpec(url: "https://api.example.com/items")))
        let badges = ["fetch": WorkflowStepRisk.badges(for: node, in: WorkflowDefinition(), locality: { _ in .local })]
        let reach = WorkflowFlowStory.reach(["fetch"], badges: badges)
        #expect(reach.online == ["fetch"])
        #expect(reach.cloud.isEmpty)
    }

    @Test @MainActor func reach_countsWebToolsAndBrowsersAsGoingOnline() {
        let def = WorkflowDefinition()
        func tool(_ name: String) -> WorkflowNode {
            WorkflowNode(id: name, name: name, kind: .tool(ToolNodeSpec(tool: ToolRef(name: name))))
        }
        let search = tool("search_and_extract")
        let browse = tool("browser_use")
        let read = tool("file_read")
        let badges = Dictionary(
            uniqueKeysWithValues: [search, browse, read].map {
                ($0.id, WorkflowStepRisk.badges(for: $0, in: def, locality: { _ in .local }))
            })
        let reach = WorkflowFlowStory.reach([search.id, browse.id, read.id], badges: badges)
        #expect(reach.online == [search.id, browse.id])
        #expect(reach.title == "Goes online")
    }

    // MARK: - Map items

    @Test func mapItems_comeFromTheOutputWithFailedItemsByIndex() {
        var record = NodeRun(nodeID: "each", status: .done)
        record.output = WorkflowRunner.mapOutput(
            results: [.string("a"), .null, .string("c")], failed: [(index: 1, error: "boom")])
        let items = WorkflowFlowStory.mapItems(record)
        #expect(items?.states == [.done, .failed, .done])
        #expect(items?.errors == [1: "boom"])
        #expect(items?.results.count == 3)
        #expect(items?.done == 2)
        #expect(items?.failed == 1)
    }

    @Test func mapItems_withoutFailuresAreAllDone() {
        var record = NodeRun(nodeID: "each", status: .done)
        record.output = WorkflowRunner.mapOutput(results: [.number(1), .number(2)], failed: [])
        #expect(WorkflowFlowStory.mapItems(record)?.states == [.done, .done])
    }

    @Test func mapItems_preferTheLiveStatesWhileTheStepRuns() {
        var record = NodeRun(nodeID: "each", status: .running)
        record.mapItems = [.done, .running, .pending, .failed]
        record.output = WorkflowRunner.mapOutput(results: [.null], failed: [])
        let items = WorkflowFlowStory.mapItems(record)
        #expect(items?.states == [.done, .running, .pending, .failed])
        #expect(items?.running == 1)
        #expect(items?.results.isEmpty == true)
    }

    @Test func mapItems_areNilBeforeTheStepHasAny() {
        #expect(WorkflowFlowStory.mapItems(nil) == nil)
        #expect(WorkflowFlowStory.mapItems(NodeRun(nodeID: "each")) == nil)
        var other = NodeRun(nodeID: "each", status: .done)
        other.output = .object(["text": .string("not a map")])
        #expect(WorkflowFlowStory.mapItems(other) == nil)
    }
}
