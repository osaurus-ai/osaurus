//
//  AgentActionSurfaceTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Decode coverage for the screenshot-addressed surface (`target.point`,
//  `zoom` regions, `hover`, `select`, `press_key` repeat, `batch`) and the
//  pixel → screen mapping in `ScreenshotPointing`.
//

import CoreGraphics
import Foundation
import XCTest

@testable import OsaurusCore

final class AgentActionSurfaceTests: XCTestCase {

    private func decoded(_ json: String) -> AgentAction? {
        if case .action(let action) = AgentAction.decode(argumentsJSON: json) { return action }
        return nil
    }

    private func invalidReason(_ json: String) -> String? {
        if case .invalid(let reason) = AgentAction.decode(argumentsJSON: json) { return reason }
        return nil
    }

    private func frame(width: Int = 400, height: Int = 300, region: CUScreenRegion?) -> CUImage {
        CUImage(base64: "", mimeType: "image/png", width: width, height: height, region: region)
    }

    // MARK: - Decode

    func testPointTargetDecodesAndRoundTrips() {
        let action = decoded(#"{"verb":"click","target":{"point":{"x":120.5,"y":"80"}}}"#)
        XCTAssertEqual(action?.target?.point, AgentPoint(x: 120.5, y: 80))
        XCTAssertNil(action?.target?.mark)
        let again = action.flatMap { decoded($0.argumentsJSON()) }
        XCTAssertEqual(again?.target?.point, AgentPoint(x: 120.5, y: 80))
    }

    func testPointWithBooleanCoordinateIsNotAPoint() {
        XCTAssertNotNil(invalidReason(#"{"verb":"click","target":{"point":{"x":true,"y":3}}}"#))
    }

    func testPointAsTwoNumberArrayDecodes() {
        let action = decoded(#"{"verb":"click","target":{"point":[170,328]}}"#)
        XCTAssertEqual(action?.target?.point, AgentPoint(x: 170, y: 328))
        let drag = decoded(#"{"verb":"drag","target":{"point":[1,2]},"to":{"point":[30.5,"40"]}}"#)
        XCTAssertEqual(drag?.to?.point, AgentPoint(x: 30.5, y: 40))
    }

    func testMalformedPointArraysAreRejectedWithAReason() {
        for json in [
            #"{"verb":"click","target":{"point":[1,2,3]}}"#,
            #"{"verb":"click","target":{"point":[1]}}"#,
            #"{"verb":"click","target":{"mark":2,"point":{"x":1}}}"#,
        ] {
            XCTAssertEqual(
                invalidReason(json),
                "`target.point` takes two numbers, as {\"x\": <x>, \"y\": <y>} or [<x>, <y>].", json
            )
        }
        XCTAssertNotNil(invalidReason(#"{"verb":"click","target":{"point":[true,2]}}"#))
    }

    func testSchemaDeclaresBothPointShapes() throws {
        let schema = try XCTUnwrap(String(data: JSONEncoder().encode(AgentAction.schema), encoding: .utf8))
        XCTAssertTrue(schema.contains(#""anyOf""#))
        XCTAssertTrue(schema.contains(#""maxItems":2"#) && schema.contains(#""minItems":2"#))
    }

    func testZoomNeedsAPositiveRegion() {
        XCTAssertNotNil(invalidReason(#"{"verb":"zoom"}"#))
        XCTAssertNotNil(invalidReason(#"{"verb":"zoom","region":{"x":0,"y":0,"width":0,"height":10}}"#))
        let action = decoded(#"{"verb":"zoom","region":{"x":10,"y":20,"width":100,"height":50}}"#)
        XCTAssertEqual(action?.region, AgentRegion(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(action?.verb.baselineEffect, .read)
    }

    func testHoverAndSelectNeedTheirFields() {
        XCTAssertNotNil(invalidReason(#"{"verb":"hover"}"#))
        XCTAssertNotNil(invalidReason(#"{"verb":"select","target":{"mark":2}}"#))
        let select = decoded(#"{"verb":"select","target":{"mark":2},"option":"Large"}"#)
        XCTAssertEqual(select?.option, "Large")
        XCTAssertEqual(select?.verb.baselineEffect, .navigate)
    }

    func testPressKeyRepeatRoundTripsAndIsBounded() {
        let action = decoded(#"{"verb":"press_key","key":"down","repeat":"4"}"#)
        XCTAssertEqual(action?.repeatCount, 4)
        XCTAssertEqual(action.flatMap { decoded($0.argumentsJSON()) }?.repeatCount, 4)
        XCTAssertNotNil(invalidReason(#"{"verb":"press_key","key":"down","repeat":0}"#))
        XCTAssertNotNil(
            invalidReason(#"{"verb":"press_key","key":"down","repeat":\#(AgentAction.maxKeyRepeat + 1)}"#)
        )
    }

    func testBatchDecodesStepsInOrder() {
        let action = decoded(
            #"{"verb":"batch","actions":[{"verb":"click","target":{"mark":1}},"#
                + #"{"verb":"type","text":"hi"},{"verb":"press_key","key":"return"}]}"#
        )
        XCTAssertEqual(action?.verb, .batch)
        XCTAssertEqual(action?.actions.map(\.verb), [.click, .type, .pressKey])
        XCTAssertEqual(action.flatMap { decoded($0.argumentsJSON()) }?.actions.count, 3)
    }

    func testBatchRejectsEmptyOversizedAndNonBatchableSteps() {
        XCTAssertNotNil(invalidReason(#"{"verb":"batch","actions":[]}"#))
        let step = #"{"verb":"press_key","key":"tab"}"#
        let tooMany = Array(repeating: step, count: AgentAction.maxBatchActions + 1).joined(separator: ",")
        XCTAssertTrue(
            invalidReason(#"{"verb":"batch","actions":[\#(tooMany)]}"#)?.contains("at most") ?? false
        )
        for verb in ["done", "open", "observe", "zoom", "batch"] {
            let reason = invalidReason(
                #"{"verb":"batch","actions":[{"verb":"click","target":{"mark":1}},{"verb":"\#(verb)"}]}"#
            )
            XCTAssertNotNil(reason, "\(verb) must not run inside a batch")
            XCTAssertTrue(reason?.hasPrefix("actions[1]") ?? false, "got: \(reason ?? "nil")")
        }
    }

    func testBatchStepErrorsNameTheStep() {
        let reason = invalidReason(#"{"verb":"batch","actions":[{"verb":"press_key","key":"a"},{"verb":"click"}]}"#)
        XCTAssertTrue(reason?.hasPrefix("actions[1]: click needs a `target`") ?? false, "got: \(reason ?? "nil")")
    }

    // MARK: - ScreenshotPointing

    func testPointMapsFromScreenshotPixelsToScreenPoints() {
        // A 400×300 screenshot of an 800×600 window at (100, 50).
        let shown = frame(region: CUScreenRegion(x: 100, y: 50, w: 800, h: 600))
        XCTAssertEqual(
            ScreenshotPointing.screenPoint(AgentPoint(x: 200, y: 150), in: shown),
            .screen(CGPoint(x: 500, y: 350))
        )
    }

    func testPointNeedsAScreenshotWithAKnownPosition() {
        guard case .invalid(let none) = ScreenshotPointing.screenPoint(AgentPoint(x: 1, y: 1), in: nil) else {
            return XCTFail("No frame must not map")
        }
        XCTAssertTrue(none.contains("screenshot"))
        guard case .invalid = ScreenshotPointing.screenPoint(AgentPoint(x: 1, y: 1), in: frame(region: nil)) else {
            return XCTFail("A frame without a region must not map")
        }
    }

    func testPointOutsideTheScreenshotIsInvalid() {
        let shown = frame(region: CUScreenRegion(x: 0, y: 0, w: 800, h: 600))
        for point in [AgentPoint(x: 400, y: 10), AgentPoint(x: 10, y: 300), AgentPoint(x: -1, y: 10)] {
            guard case .invalid = ScreenshotPointing.screenPoint(point, in: shown) else {
                return XCTFail("\(point) is outside the 400×300 frame")
            }
        }
    }

    func testRegionClipsToTheScreenshotAndMaps() {
        let shown = frame(region: CUScreenRegion(x: 0, y: 0, w: 800, h: 600))
        XCTAssertEqual(
            ScreenshotPointing.screenRegion(AgentRegion(x: 300, y: 250, width: 200, height: 200), in: shown),
            .screen(CUScreenRegion(x: 600, y: 500, w: 200, h: 100))
        )
        guard
            case .invalid = ScreenshotPointing.screenRegion(
                AgentRegion(x: 398, y: 10, width: 50, height: 50),
                in: shown
            )
        else { return XCTFail("A 2-pixel-wide sliver is below the minimum zoom side") }
    }

    func testHitTestPicksTheSmallestContainingElement() {
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: 1,
            app: "Demo",
            focusedWindow: nil,
            tier: .som,
            truncated: false,
            windows: [],
            elements: [
                CUElement(id: "group", role: "group", label: "Toolbar", x: 0, y: 0, w: 400, h: 60),
                CUElement(id: "save", role: "button", label: "Save", x: 10, y: 10, w: 60, h: 30),
                CUElement(id: "zero", role: "button", label: "Hidden", x: 10, y: 10, w: 0, h: 0),
            ],
            image: nil
        )
        XCTAssertEqual(ScreenshotPointing.hitTest(CGPoint(x: 20, y: 20), in: snapshot)?.id, "save")
        XCTAssertEqual(ScreenshotPointing.hitTest(CGPoint(x: 200, y: 20), in: snapshot)?.id, "group")
        XCTAssertNil(ScreenshotPointing.hitTest(CGPoint(x: 500, y: 20), in: snapshot))
    }
}
