//
//  AgentActionAuditLabelTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The feed's record of an action: the resolved element by role and label,
//  the app, and typed text only as a length.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class AgentActionAuditLabelTests: XCTestCase {

    private let send = CUElement(id: "send", role: "button", label: "Send")
    private let to = CUElement(id: "to", role: "textfield", label: "To")

    func testClickNamesTheElementAndApp() {
        let click = AgentAction(verb: .click, target: AgentTarget(mark: 136))
        XCTAssertEqual(click.auditLabel(element: send, app: "Mail"), #"Click button "Send" in Mail"#)
    }

    func testUnresolvedTargetKeepsTheModelsAddress() {
        let click = AgentAction(verb: .click, target: AgentTarget(mark: 136))
        XCTAssertEqual(click.auditLabel(element: nil, app: "Mail"), "Click mark 136 in Mail")
        XCTAssertEqual(click.auditLabel(element: nil, app: nil), "Click mark 136")
    }

    func testTypedTextIsRecordedAsALengthOnly() {
        let type = AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "hunter2")
        let label = type.auditLabel(element: to, app: "Mail")
        XCTAssertEqual(label, #"Type 7 characters into textfield "To" in Mail"#)
        XCTAssertFalse(label.contains("hunter2"))

        let set = AgentAction(verb: .setValue, target: AgentTarget(mark: 1), text: "a")
        XCTAssertEqual(set.auditLabel(element: to, app: nil), #"Set textfield "To" to 1 character"#)

        let focused = AgentAction(verb: .type, text: "hello")
        XCTAssertEqual(focused.auditLabel(element: nil, app: "Notes"), "Type 5 characters in Notes")
    }

    func testBatchStepsKeepTypedTextOut() {
        let batch = AgentAction(
            verb: .batch,
            actions: [
                AgentAction(verb: .type, target: AgentTarget(mark: 1), text: "secret plan"),
                AgentAction(verb: .click, target: AgentTarget(mark: 2)),
            ]
        )
        let label = batch.auditLabel(element: nil, app: "Mail")
        XCTAssertEqual(label, "Run 2 steps in Mail: Type 11 characters into mark 1, Click mark 2")
        XCTAssertFalse(label.contains("secret"))
    }

    func testUnlabeledElementFallsBackToItsRole() {
        let icon = CUElement(id: "x", role: "button", label: "  ")
        let click = AgentAction(verb: .click, target: AgentTarget(mark: 4))
        XCTAssertEqual(click.auditLabel(element: icon, app: "Finder"), "Click button in Finder")
    }

    func testVerbsWithoutATargetAreUnchanged() {
        XCTAssertEqual(AgentAction(verb: .open, app: "Mail").auditLabel(element: nil, app: "Finder"), "Open Mail")
        XCTAssertEqual(AgentAction(verb: .done, reason: "ok").auditLabel(element: nil, app: "Mail"), "Done")
    }
}
