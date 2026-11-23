//
//  WorkflowLiveRunsTests.swift
//  osaurusTests
//
//  The live-run facts pages show, where a run page lands, and what its
//  status line says.
//

import Foundation
import Testing

@testable import OsaurusCore

private let started = Date(timeIntervalSince1970: 1_800_000_000)

private func liveRun(
    _ status: WorkflowRunStatus, nodes: [NodeRunStatus] = [.done, .running, .pending],
    workflowID: UUID = UUID(), started at: Date = started, finished: Date? = nil, test: Bool = false
) -> WorkflowRun {
    var run = WorkflowRun(
        workflowID: workflowID, workflowName: "Brief", templateID: UUID(), templateVersion: 1,
        caller: WorkflowCaller(kind: test ? .test : .user), input: .object([:]),
        nodeIDs: nodes.indices.map { "n\($0)" }, startedAt: at)
    for (index, status) in nodes.enumerated() { run.nodes[index].status = status }
    run.status = status
    run.finishedAt = finished
    return run
}

struct WorkflowLiveRunSummaryTests {
    @Test func stepCountsFinishedStepsPlusOne() {
        let summary = WorkflowLiveRuns.Summary(liveRun(.running))
        #expect(summary.step == 2)
        #expect(summary.stepCount == 3)
        #expect(summary.stepNodeID == "n1")
        #expect(summary.isGoing)
    }

    @Test func shortLine() {
        #expect(WorkflowLiveRuns.Summary(liveRun(.running)).shortLine == "Step 2 of 3")
        let waiting = liveRun(.awaitingUser, nodes: [.done, .awaitingUser])
        #expect(WorkflowLiveRuns.Summary(waiting).shortLine == "Waiting for your answer")
        #expect(WorkflowLiveRuns.Summary(liveRun(.running, nodes: [])).shortLine == "Starting…")
    }

    @Test func stopwatchTicksInSeconds() {
        #expect(WorkflowRunWords.stopwatch(0) == "0:00")
        #expect(WorkflowRunWords.stopwatch(42.7) == "0:42")
        #expect(WorkflowRunWords.stopwatch(725) == "12:05")
        #expect(WorkflowRunWords.stopwatch(3725) == "1:02:05")
    }

    @Test func progressNamesTheStep() {
        let summary = WorkflowLiveRuns.Summary(liveRun(.running))
        #expect(summary.progress(stepName: "Read mail") == "Step 2 of 3: Read mail")
        let waiting = WorkflowLiveRuns.Summary(liveRun(.awaitingUser, nodes: [.awaitingUser]))
        #expect(waiting.progress(stepName: "Pick one") == "Waiting for your answer at Pick one")
    }

    @Test func streamedWordsDontChangeTheSummaries() {
        var run = liveRun(.running)
        let before = WorkflowLiveRuns.summaries([run.id: run])
        run.nodes[1].streamed = "Some words so far"
        run.nodes[1].logs.append("a log line")
        #expect(WorkflowLiveRuns.summaries([run.id: run]) == before)
        run.nodes[1].status = .done
        #expect(WorkflowLiveRuns.summaries([run.id: run]) != before)
    }

    @Test func testRunsAreLeftOut() {
        let run = liveRun(.running, test: true)
        #expect(WorkflowLiveRuns.summaries([run.id: run]).isEmpty)
    }
}

@MainActor
struct WorkflowsRunningNowTests {
    @Test func waitingFirstThenRunningThenJustEnded() {
        let now = started.addingTimeInterval(100)
        let running = WorkflowLiveRuns.Summary(liveRun(.running, started: started.addingTimeInterval(50)))
        let waiting = WorkflowLiveRuns.Summary(liveRun(.awaitingUser, nodes: [.awaitingUser]))
        let ended = WorkflowLiveRuns.Summary(liveRun(.completed, nodes: [.done], finished: now.addingTimeInterval(-2)))
        let gone = WorkflowLiveRuns.Summary(
            liveRun(.completed, nodes: [.done], finished: now.addingTimeInterval(-WorkflowRunPresentation.lingerInterval - 1)))
        let shown = WorkflowsRunningNow.shown([ended, running, gone, waiting], now: now)
        #expect(shown.map(\.id) == [waiting.id, running.id, ended.id])
    }
}

@MainActor
struct WorkflowRunPathTests {
    let workflow: UUID
    let other = UUID()
    let page: ChatWindowState.WorkflowsPage

    init() {
        workflow = UUID()
        page = .run(workflowID: workflow, runID: UUID(), agentId: Agent.defaultId)
    }

    @Test func outsideTheLibraryStartsOverUnderTheWorkflow() {
        let path = ChatWindowState.path(showing: page, of: workflow, from: [.activity], inLibrary: false)
        #expect(path == [.workflow(workflow), page])
    }

    @Test func onTheWorkflowPagePushesTheRun() {
        let path = ChatWindowState.path(showing: page, of: workflow, from: [.workflow(workflow)], inLibrary: true)
        #expect(path == [.workflow(workflow), page])
    }

    @Test func anotherRunOfTheSameWorkflowIsReplaced() {
        let earlier = ChatWindowState.WorkflowsPage.run(workflowID: workflow, runID: UUID(), agentId: Agent.defaultId)
        let path = ChatWindowState.path(showing: page, of: workflow, from: [.workflow(workflow), earlier], inLibrary: true)
        #expect(path == [.workflow(workflow), page])
    }

    @Test func activityKeepsTheRunOnTop() {
        let path = ChatWindowState.path(showing: page, of: workflow, from: [.activity], inLibrary: true)
        #expect(path == [.activity, page])
    }

    @Test func elsewhereAddsTheWorkflowPageUnderIt() {
        let path = ChatWindowState.path(showing: page, of: workflow, from: [.workflow(other)], inLibrary: true)
        #expect(path == [.workflow(other), .workflow(workflow), page])
        #expect(ChatWindowState.path(showing: page, of: workflow, from: [], inLibrary: true) == [.workflow(workflow), page])
    }
}

@MainActor
struct WorkflowRunResultTests {
    @Test func emptyOutputsShowNoResult() {
        #expect(!WorkflowRunPage.hasResult(.null))
        #expect(!WorkflowRunPage.hasResult(.object([:])))
        #expect(!WorkflowRunPage.hasResult(.object(["text": .string("  "), "items": .array([])])))
        #expect(WorkflowRunPage.hasResult(.object(["done": .bool(true)])))
        #expect(WorkflowRunPage.hasResult(.string("A short report")))
    }
}

@MainActor
struct WorkflowRunStatusWordsTests {
    @Test func eachStatusSaysOneSentence() {
        #expect(WorkflowRunWords.status(liveRun(.running), definition: nil).text == "Running now · Step 2 of 3")
        #expect(WorkflowRunWords.status(liveRun(.running), definition: nil).tone == .info)
        #expect(WorkflowRunWords.status(liveRun(.awaitingUser, nodes: [.awaitingUser]), definition: nil).text == "Waiting for your answer")
        #expect(WorkflowRunWords.status(liveRun(.completed, nodes: [.done]), definition: nil).text == "It worked.")
        #expect(WorkflowRunWords.status(liveRun(.failed, nodes: [.failed]), definition: nil).text == "It didn't finish.")
        #expect(WorkflowRunWords.status(liveRun(.failed, nodes: [.failed]), definition: nil).tone == .error)
        #expect(
            WorkflowRunWords.status(liveRun(.needsSetup, nodes: []), definition: nil).text
                == "It couldn't start: setup isn't finished.")
        #expect(WorkflowRunWords.status(liveRun(.cancelled), definition: nil).tone == nil)
    }
}
