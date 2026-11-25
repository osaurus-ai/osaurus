//
//  AgentViewTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The model's compact, id-free picture of an app + the verify-delta builder.
//  These pin the behaviour the loop and the model both depend on:
//   • 1-based marks in stable element order (the model's only handle),
//   • the changed/removed delta that is the verify signal,
//   • duplicate (role|label) matching across captures, and
//   • the 120-item truncation hint + empty-view rendering.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class AgentViewTests: XCTestCase {

    private func el(_ id: String, _ role: String, _ label: String?, value: String? = nil) -> CUElement {
        CUElement(id: id, role: role, label: label, value: value)
    }

    private func snapshot(_ elements: [CUElement], id: Int = 1) -> CUSnapshot {
        CUSnapshot(
            snapshotId: id,
            pid: 1,
            app: "App",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [],
            elements: elements,
            image: nil
        )
    }

    // MARK: - Marks

    func testMarksAreOneBasedInOrder() {
        let view = AgentView.build(
            from: snapshot([el("a", "button", "A"), el("b", "button", "B"), el("c", "button", "C")]),
            previous: nil
        )
        XCTAssertEqual(view.items.map { $0.mark }, [1, 2, 3])
        XCTAssertEqual(view.items.map { $0.elementId }, ["a", "b", "c"])
    }

    func testItemLookupByMark() {
        let view = AgentView.build(
            from: snapshot([el("a", "button", "A"), el("b", "button", "B")]),
            previous: nil
        )
        XCTAssertEqual(view.item(mark: 2)?.elementId, "b")
        XCTAssertNil(view.item(mark: 5))
    }

    // MARK: - Change delta

    func testFirstCaptureHasNoChanges() {
        let view = AgentView.build(from: snapshot([el("a", "textfield", "F", value: "x")]), previous: nil)
        XCTAssertFalse(view.hasChanges)
        XCTAssertFalse(view.items.contains { $0.changed })
    }

    func testChangedValueIsFlagged() {
        let prev = AgentView.build(from: snapshot([el("a", "textfield", "F", value: "old")]), previous: nil)
        let next = AgentView.build(
            from: snapshot([el("a", "textfield", "F", value: "new")], id: 2),
            previous: prev
        )
        XCTAssertTrue(next.items.first?.changed ?? false)
        XCTAssertTrue(next.hasChanges)
    }

    func testUnchangedValueIsNotFlagged() {
        let prev = AgentView.build(from: snapshot([el("a", "textfield", "F", value: "same")]), previous: nil)
        let next = AgentView.build(
            from: snapshot([el("a", "textfield", "F", value: "same")], id: 2),
            previous: prev
        )
        XCTAssertFalse(next.items.first?.changed ?? true)
        XCTAssertFalse(next.hasChanges)
    }

    func testNewElementIsFlaggedChanged() {
        let prev = AgentView.build(from: snapshot([el("a", "textfield", "F")]), previous: nil)
        let next = AgentView.build(
            from: snapshot([el("a", "textfield", "F"), el("b", "button", "New")], id: 2),
            previous: prev
        )
        XCTAssertEqual(next.item(mark: 2)?.changed, true)
    }

    func testRemovedElementCounted() {
        let prev = AgentView.build(
            from: snapshot([el("a", "textfield", "F"), el("b", "button", "Gone")]),
            previous: nil
        )
        let next = AgentView.build(from: snapshot([el("a", "textfield", "F")], id: 2), previous: prev)
        XCTAssertEqual(next.removedCount, 1)
        XCTAssertTrue(next.hasChanges)
        XCTAssertTrue(next.renderForModel().localizedCaseInsensitiveContains("disappeared"))
    }

    /// Live finding (Qwen3-VL-8B): after a click that archived the email, the result said only "The view changed."
    /// and the model clicked Archive three more times. The verify result now names what changed.
    func testChangesNameTheValueAppearedAndDisappearedElements() {
        let prev = AgentView.build(
            from: snapshot([
                el("a", "button", "Archive"), el("s", "statictext", "State", value: "inbox"),
                el("g", "button", "Gone"),
            ]),
            previous: nil
        )
        let next = AgentView.build(
            from: snapshot(
                [
                    el("a", "button", "Archive"), el("s", "statictext", "State", value: "archived"),
                    el("u", "button", "Undo"),
                ], id: 2),
            previous: prev
        )
        XCTAssertEqual(
            next.changes,
            [
                AgentViewChange(mark: 2, role: "statictext", label: "State", value: "archived", kind: .valueChanged(from: "inbox")),
                AgentViewChange(mark: 3, role: "button", label: "Undo", value: nil, kind: .appeared),
                AgentViewChange(mark: nil, role: "button", label: "Gone", value: nil, kind: .disappeared),
            ])
        XCTAssertEqual(
            next.renderChanges(),
            "[2] statictext \"State\": \"inbox\" → \"archived\"\n[3] button \"Undo\" appeared\nbutton \"Gone\" disappeared")
    }

    func testChangesAreCappedAndSecureValuesStayOut() {
        let prev = AgentView.build(from: snapshot([el("p", "securetextfield", "Password", value: "a")]), previous: nil)
        let next = AgentView.build(
            from: snapshot(
                [el("p", "securetextfield", "Password", value: "ab")] + (1...8).map { el("n\($0)", "button", "N\($0)") },
                id: 2),
            previous: prev
        )
        XCTAssertFalse(next.changes.contains { $0.label == "Password" }, "a secure value is never diffed")
        let lines = next.renderChanges(limit: 3).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.last, "… and 5 more")
    }

    func testFirstCaptureListsNoChanges() {
        let view = AgentView.build(from: snapshot([el("a", "textfield", "F", value: "x")]), previous: nil)
        XCTAssertTrue(view.changes.isEmpty)
        XCTAssertEqual(view.renderChanges(), "")
    }

    func testDuplicateLabelChangeDetection() {
        // Two same-keyed rows; only the second value changes. The build's
        // per-key "consumed" counter must attribute the change to the right one.
        let prev = AgentView.build(
            from: snapshot([
                el("r1", "textfield", "Row", value: "a"),
                el("r2", "textfield", "Row", value: "b"),
            ]),
            previous: nil
        )
        let next = AgentView.build(
            from: snapshot(
                [
                    el("r1", "textfield", "Row", value: "a"),
                    el("r2", "textfield", "Row", value: "c"),
                ],
                id: 2
            ),
            previous: prev
        )
        XCTAssertEqual(next.item(mark: 1)?.changed, false)
        XCTAssertEqual(next.item(mark: 2)?.changed, true)
    }

    func testDuplicateTextareasStayBoundToTheirWindowsAndRenderWindowContext() {
        let windows = [
            CUWindowSummary(id: 10, title: "Target", focused: true, x: 0, y: 0, w: 400, h: 300),
            CUWindowSummary(id: 20, title: "Other", focused: false, x: 10, y: 10, w: 400, h: 300),
        ]
        func multiSnapshot(_ first: String, _ second: String, id: Int) -> CUSnapshot {
            CUSnapshot(
                snapshotId: id,
                pid: 1,
                app: "TextEdit",
                focusedWindow: "Target",
                tier: .ax,
                truncated: false,
                windows: windows,
                elements: [
                    CUElement(id: "target", role: "textarea", value: first, windowId: 10),
                    CUElement(id: "other", role: "textarea", value: second, windowId: 20),
                ],
                image: nil
            )
        }

        let previous = AgentView.build(
            from: multiSnapshot("Hello from OracHQ", "Hello again", id: 1),
            previous: nil
        )
        let next = AgentView.build(
            from: multiSnapshot("Hello again", "Hello again", id: 2),
            previous: previous
        )

        XCTAssertEqual(next.item(mark: 1)?.windowTitle, "Target")
        XCTAssertEqual(next.item(mark: 1)?.changed, true)
        XCTAssertEqual(next.item(mark: 2)?.changed, false)
        XCTAssertTrue(next.renderForModel().contains("[window \"Target\", focused]"))
        XCTAssertTrue(next.renderForModel().contains("[window \"Other\"]"))
    }

    // MARK: - Rendering

    func testTruncationHintBeyond120() {
        let many = (0 ..< 130).map { el("e\($0)", "button", "B\($0)") }
        let view = AgentView.build(from: snapshot(many), previous: nil)
        let render = view.renderForModel()
        XCTAssertTrue(
            render.contains("10 more elements"),
            "Expected a truncation hint; got tail: \(render.suffix(120))"
        )
    }

    func testEmptyViewRendersNoElements() {
        let view = AgentView.build(from: snapshot([]), previous: nil)
        XCTAssertTrue(view.renderForModel().contains("(no actionable elements found)"))
    }

    func testChangedItemRendersMarker() {
        let prev = AgentView.build(from: snapshot([el("a", "textfield", "F", value: "old")]), previous: nil)
        let next = AgentView.build(
            from: snapshot([el("a", "textfield", "F", value: "new")], id: 2),
            previous: prev
        )
        XCTAssertTrue(next.renderForModel().contains("* ["), "Changed elements should render a `*` marker")
    }

    func testSecureFieldValueDoesNotRenderForModel() {
        let view = AgentView.build(
            from: snapshot([
                el("email", "textfield", "Email", value: "ops@example.com"),
                el("password", "securetextfield", "Password", value: "p@ssw0rd-do-not-leak"),
            ]),
            previous: nil
        )
        let render = view.renderForModel()

        XCTAssertTrue(render.contains("Email"))
        XCTAssertTrue(render.contains("ops@example.com"))
        XCTAssertTrue(render.contains("Password"))
        XCTAssertFalse(render.contains("p@ssw0rd-do-not-leak"))
        XCTAssertNil(view.items.first(where: { $0.elementId == "password" })?.value)
    }

    func testSecureFieldValueChangeDoesNotRenderMarker() {
        let prev = AgentView.build(
            from: snapshot([el("password", "securetextfield", "Password", value: "old-secret")]),
            previous: nil
        )
        let next = AgentView.build(
            from: snapshot([el("password", "securetextfield", "Password", value: "new-secret")], id: 2),
            previous: prev
        )

        XCTAssertFalse(next.hasChanges)
        XCTAssertFalse(next.items.first?.changed ?? true)
        XCTAssertFalse(next.renderForModel().contains("* ["))
        XCTAssertFalse(next.renderForModel().contains("new-secret"))
    }

    // MARK: - Value clipping

    /// A terminal is one textarea whose value is the whole scrollback. The
    /// model must see the latest output (the tail), not the login banner.
    func testLongTextareaRendersTailSoCommandOutputIsVisible() {
        let banner = "Last login: Thu Sep 17 12:07:13 on ttys003\nrcn@Mac ~ % "
        let filler = String(repeating: "older output line\n", count: 200)
        let output = "ls -la ~/Desktop/PII-Test\nbudget.xlsx\nsetup.dmg\nrcn@Mac ~ % "
        let view = AgentView.build(
            from: snapshot([el("t", "textarea", "shell", value: banner + filler + output)]),
            previous: nil
        )
        let render = view.renderForModel()
        XCTAssertTrue(render.contains("budget.xlsx"), "latest command output must reach the model")
        XCTAssertTrue(render.contains("earlier characters not shown"))
        XCTAssertFalse(render.contains("Last login"), "the head is the part that gets dropped")
    }

    func testShortTextareaRendersWholeValue() {
        let value = String(repeating: "a", count: AgentView.contentValueChars)
        XCTAssertEqual(AgentView.renderedValue(value, role: "textarea"), value)
    }

    func testOtherRolesKeepShortHeadClip() {
        let value = String(repeating: "b", count: 100)
        XCTAssertEqual(
            AgentView.renderedValue(value, role: "textfield"),
            String(repeating: "b", count: AgentView.fieldValueChars) + "…"
        )
    }
}
