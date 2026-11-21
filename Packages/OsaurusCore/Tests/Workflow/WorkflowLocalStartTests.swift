//
//  WorkflowLocalStartTests.swift
//  osaurusTests
//
//  Shortcuts' Run Workflow: text goes where an automation's {{text}}
//  would, an object is taken as given over the defaults, setup that is not
//  done refuses, and the run is a background user run. The route answers
//  only the app's own token.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct WorkflowLocalStartTests {
    private let schema = WF.object(
        [
            "topic": WF.string,
            "count": .object(["type": .string("integer"), "default": .number(3)]),
        ],
        required: ["topic"]
    )

    @Test func textFillsTheMainFieldOverTheDefaults() throws {
        let input = try WorkflowLocalStart.input(schema: schema, text: "  Swift  ", values: nil).get()
        #expect(input == .object(["topic": .string("Swift"), "count": .number(3)]))
    }

    @Test func anObjectIsTakenAsGiven() throws {
        let input = try WorkflowLocalStart.input(
            schema: schema,
            text: "ignored",
            values: .object(["topic": .string("Rust"), "count": .number(5)])
        ).get()
        #expect(input == .object(["topic": .string("Rust"), "count": .number(5)]))
    }

    @Test func missingOrMisshapenInputFails() {
        guard case .failure(.invalidInput) = WorkflowLocalStart.input(schema: schema, text: nil, values: nil) else {
            Issue.record("a required field left empty must fail")
            return
        }
        guard case .failure(.invalidInput) = WorkflowLocalStart.input(schema: schema, text: nil, values: .string("x"))
        else {
            Issue.record("input that is not an object must fail")
            return
        }
        #expect(WorkflowLocalStart.Failure.invalidInput("x").status == 400)
    }

    @Test func noRequiredFieldsRunWithNothing() throws {
        let input = try WorkflowLocalStart.input(schema: WF.object([:]), text: nil, values: nil).get()
        #expect(input == .object([:]))
    }

    @Test func startRefusesUnknownAndUnsetUpWorkflowsAndRunsInTheBackground() throws {
        guard case .failure(.notFound) = WorkflowLocalStart.start(workflowID: UUID(), text: nil, values: nil) else {
            Issue.record("an unknown id must be not found")
            return
        }

        let store = InstalledWorkflowStore.shared
        let installed = try store.install(
            WF.template(WF.intake(), name: "Local start \(UUID().uuidString.prefix(6))"),
            bindings: InstallBindings()
        )
        defer { store.delete(id: installed.id) }

        let blocked = SetupReport(
            subjectId: installed.id,
            items: [SetupItem(kind: .app, severity: .blocking, title: "Xcode", detail: "Not installed", value: "x.y")]
        )
        var launched: [(JSONValue, WorkflowCaller)] = []
        let refused = WorkflowLocalStart.start(
            workflowID: installed.id,
            text: "Acme",
            values: nil,
            report: { _ in blocked },
            launch: { _, input, caller in
                launched.append((input, caller))
                return UUID()
            }
        )
        guard case .failure(let failure) = refused, case .needsSetup = failure else {
            Issue.record("setup that is not done must refuse")
            return
        }
        #expect(failure.status == 409)
        #expect(failure.code == "needs_setup")
        #expect(launched.isEmpty)

        let runID = UUID()
        let started = WorkflowLocalStart.start(
            workflowID: installed.id,
            text: "Acme",
            values: nil,
            report: { SetupReport(subjectId: $0.id, items: []) },
            launch: { _, input, caller in
                launched.append((input, caller))
                return runID
            }
        )
        #expect(try started.get() == runID)
        let (input, caller) = try #require(launched.first)
        #expect(input.value(atPath: "client")?.stringValue == "Acme")
        #expect(caller.kind == .user)
        #expect(caller.background)
    }

    @Test func routeMatchesOnlyTheRunPath() {
        let id = UUID()
        #expect(HTTPHandler.localWorkflowRunID("/workflows/\(id.uuidString)/run") == id)
        #expect(HTTPHandler.localWorkflowRunID("/workflows/runs/\(id.uuidString)") == nil)
        #expect(HTTPHandler.localWorkflowRunID("/workflows/nope/run") == nil)
        #expect(HTTPHandler.localWorkflowRunID("/agents/a/workflows/\(id.uuidString)/run") == nil)
    }
}
