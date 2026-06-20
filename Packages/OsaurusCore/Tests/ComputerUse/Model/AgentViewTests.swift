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
}
