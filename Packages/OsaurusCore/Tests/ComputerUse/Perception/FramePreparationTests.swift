//
//  FramePreparationTests.swift
//  OsaurusCoreTests — Computer Use
//
//  `FrameBudget` sizing and bundle resolution, and `FramePreparer` fitting
//  and mark drawing on real encoded pixels.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import OsaurusCore

final class FramePreparationTests: XCTestCase {

    // MARK: - FrameBudget

    func testStandardBudgetShrinksRetinaWindowInsideBothCaps() {
        let size = FrameBudget.standard.fitted(width: 2880, height: 1800)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1568)
        XCTAssertLessThanOrEqual(size.width * size.height, 1_150_000)
        XCTAssertEqual(Double(size.width) / Double(size.height), 1.6, accuracy: 0.01)
    }

    func testFrameInsideBudgetKeepsItsSize() {
        let size = FrameBudget.standard.fitted(width: 800, height: 600)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testGridSnapsBothSidesDown() {
        let budget = FrameBudget(maxLongEdge: 1568, maxPixels: 1_150_000, multiple: 32)
        let size = budget.fitted(width: 1000, height: 700)
        XCTAssertEqual(size.width, 992)
        XCTAssertEqual(size.height, 672)
    }

    func testGridNeverRoundsASideToZero() {
        let budget = FrameBudget(maxLongEdge: 1568, maxPixels: 1_150_000, multiple: 28)
        let size = budget.fitted(width: 1500, height: 10)
        XCTAssertEqual(size.height, 28)
    }

    func testPixelBudgetResolvesFromNewerSizeLayout() throws {
        let json = #"{"size":{"longest_edge":16777216,"shortest_edge":65536},"patch_size":16,"merge_size":2}"#
        let budget = FrameBudget.resolve(preprocessorConfig: Data(json.utf8))
        XCTAssertEqual(budget, FrameBudget(maxLongEdge: 1568, maxPixels: 1_150_000, multiple: 32))
    }

    func testSmallerBundlePixelCapWins() {
        let json = #"{"max_pixels":1003520,"min_pixels":3136,"patch_size":14,"merge_size":2}"#
        let budget = FrameBudget.resolve(preprocessorConfig: Data(json.utf8))
        XCTAssertEqual(budget, FrameBudget(maxLongEdge: 1568, maxPixels: 1_003_520, multiple: 28))
    }

    func testLargerBundlePixelCapKeepsStandard() {
        let json = #"{"max_pixels":12845056,"patch_size":14,"merge_size":2}"#
        let budget = FrameBudget.resolve(preprocessorConfig: Data(json.utf8))
        XCTAssertEqual(budget.maxPixels, 1_150_000)
        XCTAssertEqual(budget.multiple, 28)
    }

    func testEdgeLengthProcessorCapsTheLongEdge() {
        let json = #"{"size":{"longest_edge":1536},"patch_size":16}"#
        let budget = FrameBudget.resolve(preprocessorConfig: Data(json.utf8))
        XCTAssertEqual(budget, FrameBudget(maxLongEdge: 1536, maxPixels: 1_150_000, multiple: 1))
    }

    func testUnreadableConfigKeepsStandard() {
        XCTAssertEqual(FrameBudget.resolve(preprocessorConfig: Data("not json".utf8)), .standard)
        let booleans = #"{"merge_size":true,"patch_size":14}"#
        XCTAssertEqual(FrameBudget.resolve(preprocessorConfig: Data(booleans.utf8)), .standard)
    }

    func testMissingBundleConfigKeepsStandard() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(FrameBudget.resolve(modelDirectory: dir), .standard)
    }

    // MARK: - FramePreparer

    func testFitShrinksPixelsAndKeepsRegion() throws {
        let region = CUScreenRegion(x: 100, y: 50, w: 2000, h: 1000)
        let image = try Self.solidImage(width: 1000, height: 500, region: region)
        let fitted = FramePreparer.fit(image, to: FrameBudget(maxLongEdge: 1568, maxPixels: 125_000))
        XCTAssertEqual(fitted.width, 500)
        XCTAssertEqual(fitted.height, 250)
        XCTAssertEqual(fitted.region, region)
        let decoded = try XCTUnwrap(Self.decode(fitted))
        XCTAssertEqual(decoded.width, 500)
        XCTAssertEqual(decoded.height, 250)
    }

    func testFitLeavesAFittingFrameUntouched() throws {
        let image = try Self.solidImage(width: 400, height: 300, region: nil)
        XCTAssertEqual(FramePreparer.fit(image, to: .standard), image)
    }

    func testUndecodableFrameIsReturnedAsIs() {
        let image = CUImage(base64: "", mimeType: "image/png", width: 4000, height: 3000)
        XCTAssertEqual(FramePreparer.fit(image, to: .standard), image)
        let marks = [FrameMark(number: 1, rect: CGRect(x: 0, y: 0, width: 50, height: 50))]
        XCTAssertEqual(FramePreparer.drawMarks(marks, on: image), image)
    }

    func testMarksMapScreenFramesIntoFramePixelsKeepingListNumbers() throws {
        let region = CUScreenRegion(x: 100, y: 50, w: 2000, h: 1000)
        let image = try Self.solidImage(width: 1000, height: 500, region: region)
        let snapshot = Self.snapshot(elements: [
            CUElement(id: "off", role: "button", x: 5000, y: 5000, w: 80, h: 30),
            CUElement(id: "go", role: "button", x: 300, y: 250, w: 200, h: 60),
            CUElement(id: "tiny", role: "button", x: 600, y: 600, w: 4, h: 4),
            CUElement(id: "edge", role: "button", x: 2000, y: 900, w: 400, h: 400),
        ])
        let view = AgentView.build(from: snapshot, previous: nil)
        let marks = FramePreparer.marks(for: snapshot, view: view, in: image)
        XCTAssertEqual(
            marks,
            [
                FrameMark(number: 2, rect: CGRect(x: 100, y: 100, width: 100, height: 30)),
                FrameMark(number: 4, rect: CGRect(x: 950, y: 425, width: 50, height: 75)),
            ]
        )
    }

    func testMarksCarryTheViewNumbersAfterAnElementAboveDisappears() throws {
        let region = CUScreenRegion(x: 0, y: 0, w: 1000, h: 500)
        let image = try Self.solidImage(width: 1000, height: 500, region: region)
        let before = Self.snapshot(elements: [
            CUElement(id: "s1-1", role: "statictext", label: "Last Expression", x: 10, y: 10, w: 200, h: 30),
            CUElement(id: "s1-2", role: "button", label: "1", x: 10, y: 100, w: 60, h: 60),
            CUElement(id: "s1-3", role: "button", label: "2", x: 100, y: 100, w: 60, h: 60),
        ])
        let after = Self.snapshot(elements: [
            CUElement(id: "s2-1", role: "button", label: "1", x: 10, y: 100, w: 60, h: 60),
            CUElement(id: "s2-2", role: "button", label: "2", x: 100, y: 100, w: 60, h: 60),
        ])
        let view = AgentView.build(from: after, previous: AgentView.build(from: before, previous: nil))
        XCTAssertEqual(
            FramePreparer.marks(for: after, view: view, in: image).map(\.number),
            [2, 3]
        )
    }

    func testNoMarksWithoutARegionOrSnapshot() throws {
        let image = try Self.solidImage(width: 200, height: 100, region: nil)
        let snapshot = Self.snapshot(elements: [CUElement(id: "go", role: "button", x: 10, y: 10, w: 50, h: 20)])
        let view = AgentView.build(from: snapshot, previous: nil)
        XCTAssertTrue(FramePreparer.marks(for: snapshot, view: view, in: image).isEmpty)
        let placed = try Self.solidImage(width: 200, height: 100, region: CUScreenRegion(x: 0, y: 0, w: 200, h: 100))
        XCTAssertTrue(FramePreparer.marks(for: nil, view: view, in: placed).isEmpty)
        XCTAssertTrue(FramePreparer.marks(for: snapshot, view: nil, in: placed).isEmpty)
    }

    func testDrawnMarkTagsTheBoxCorner() throws {
        let region = CUScreenRegion(x: 0, y: 0, w: 400, h: 300)
        let image = try Self.solidImage(width: 400, height: 300, region: region)
        let mark = FrameMark(number: 7, rect: CGRect(x: 100, y: 100, width: 120, height: 60))
        let drawn = FramePreparer.drawMarks([mark], on: image)
        XCTAssertEqual(drawn.width, 400)
        XCTAssertEqual(drawn.height, 300)
        XCTAssertEqual(drawn.region, region)
        let pixels = try XCTUnwrap(Self.rgba(drawn))
        // Inside the tag at the box's top-left: red fill (or white digit).
        let tag = pixels(103, 103)
        XCTAssertTrue(tag.r > 150 && (tag.g < 90 || tag.g > 200), "tag pixel \(tag)")
        // Well outside the box: untouched white.
        let outside = pixels(20, 20)
        XCTAssertTrue(outside.r > 240 && outside.g > 240 && outside.b > 240, "outside pixel \(outside)")
        // Centre of the box stays clear so the control is still visible.
        let centre = pixels(190, 150)
        XCTAssertTrue(centre.r > 240 && centre.g > 240, "centre pixel \(centre)")
    }

    // MARK: - Fixtures

    private static func snapshot(elements: [CUElement]) -> CUSnapshot {
        CUSnapshot(
            snapshotId: 1, pid: 1, app: "Test", focusedWindow: nil, tier: .som,
            truncated: false, windows: [], elements: elements, image: nil
        )
    }

    /// An encoded all-white PNG frame.
    static func solidImage(width: Int, height: Int, region: CUScreenRegion?) throws -> CUImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return CUImage(
            base64: (data as Data).base64EncodedString(), mimeType: "image/png",
            width: width, height: height, region: region
        )
    }

    static func decode(_ image: CUImage) -> CGImage? {
        guard let data = Data(base64Encoded: image.base64),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A top-left-origin pixel reader for `image`.
    private static func rgba(_ image: CUImage) -> ((Int, Int) -> (r: Int, g: Int, b: Int))? {
        guard let cg = decode(image) else { return nil }
        let width = cg.width
        let height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return { x, y in
            let i = (y * width + x) * 4
            return (Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2]))
        }
    }
}
