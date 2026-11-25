//
//  GroundingProfileTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Coordinate frames, per-bundle resolution order (declared → stated config →
//  cached calibration → needs calibration), the calibration cache, the
//  synthetic screens, and calibration scoring.
//

import CoreGraphics
import Foundation
import XCTest

@testable import OsaurusCore

final class GroundingProfileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func store() -> GroundingCalibrationStore {
        GroundingCalibrationStore(fileURL: directory.appendingPathComponent("cache/grounding.json"))
    }

    // MARK: Frames

    func testPixelPointPerFrame() throws {
        let pixels = GroundingProfile(frame: .pixels, source: .provider)
        let thousand = GroundingProfile(frame: .normalized1000, source: .calibrated)
        let unit = GroundingProfile(frame: .normalizedUnit, source: .declared)

        let p = try XCTUnwrap(pixels.pixelPoint(x: 100, y: 50, width: 800, height: 400))
        XCTAssertEqual(p.x, 100)
        XCTAssertEqual(p.y, 50)
        let t = try XCTUnwrap(thousand.pixelPoint(x: 500, y: 250, width: 800, height: 400))
        XCTAssertEqual(t.x, 400)
        XCTAssertEqual(t.y, 100)
        let u = try XCTUnwrap(unit.pixelPoint(x: 0.25, y: 0.5, width: 800, height: 400))
        XCTAssertEqual(u.x, 200)
        XCTAssertEqual(u.y, 200)

        // A normalized scale includes its upper bound and maps it inside the image.
        let edge = try XCTUnwrap(thousand.pixelPoint(x: 1000, y: 1000, width: 800, height: 400))
        XCTAssertLessThan(edge.x, 800)
        XCTAssertLessThan(edge.y, 400)

        XCTAssertNil(pixels.pixelPoint(x: 800, y: 10, width: 800, height: 400))
        XCTAssertNil(thousand.pixelPoint(x: 1001, y: 10, width: 800, height: 400))
        XCTAssertNil(unit.pixelPoint(x: 2, y: 0.5, width: 800, height: 400))
        XCTAssertNil(unit.pixelPoint(x: -0.1, y: 0.5, width: 800, height: 400))
    }

    func testDeclaredSpellings() {
        XCTAssertEqual(GroundingProfile.CoordinateFrame(declared: "normalized_1000"), .normalized1000)
        XCTAssertEqual(GroundingProfile.CoordinateFrame(declared: "relative-1000"), .normalized1000)
        XCTAssertEqual(GroundingProfile.CoordinateFrame(declared: "absolute"), .pixels)
        XCTAssertEqual(GroundingProfile.CoordinateFrame(declared: "normalized"), .normalizedUnit)
        XCTAssertNil(GroundingProfile.CoordinateFrame(declared: "xy"))
    }

    // MARK: Resolution order

    func testDeclaredMetadataWinsOverStatedConfig() throws {
        try write("jang_config.json", ["grounding": ["coordinate_frame": "normalized_1000"]])
        try write("preprocessor_config.json", ["grounding": ["coordinate_frame": "pixels"]])
        XCTAssertEqual(
            GroundingProfileResolver.resolve(modelId: "m", directory: directory, budget: .standard, store: store()),
            .resolved(GroundingProfile(frame: .normalized1000, source: .declared))
        )
    }

    func testStatedConfigResolvesWhenNothingIsDeclared() throws {
        try write("jang_config.json", ["quantization": ["bits": 4]])
        try write("config.json", ["capabilities": ["grounding": ["coordinate_frame": "pixels"]]])
        XCTAssertEqual(
            GroundingProfileResolver.resolve(modelId: "m", directory: directory, budget: .standard, store: store()),
            .resolved(GroundingProfile(frame: .pixels, source: .bundleConfig))
        )
    }

    func testUnstatedBundleNeedsCalibrationThenUsesTheCache() throws {
        try write("config.json", ["model_type": "qwen3_vl"])
        try write("preprocessor_config.json", ["patch_size": 16, "merge_size": 2])
        let cache = store()
        let budget = FrameBudget.resolve(modelDirectory: directory)

        guard
            case .needsCalibration(let key) = GroundingProfileResolver.resolve(
                modelId: "m", directory: directory, budget: budget, store: cache
            )
        else { return XCTFail("expected needsCalibration") }
        XCTAssertEqual(key.budget, budget)

        cache.record(
            GroundingCalibration.Result(outcome: .frame(.normalized1000), hits: [.normalized1000: 5], trials: 5),
            for: key
        )
        XCTAssertEqual(
            GroundingProfileResolver.resolve(modelId: "m", directory: directory, budget: budget, store: cache),
            .resolved(GroundingProfile(frame: .normalized1000, source: .calibrated))
        )

        // A fresh store reads the persisted entry.
        XCTAssertEqual(
            GroundingProfileResolver.resolve(modelId: "m", directory: directory, budget: budget, store: store()),
            .resolved(GroundingProfile(frame: .normalized1000, source: .calibrated))
        )

        // Changing the bundle's config invalidates the calibration.
        try write("config.json", ["model_type": "qwen3_vl", "revision": 2])
        guard
            case .needsCalibration = GroundingProfileResolver.resolve(
                modelId: "m", directory: directory, budget: budget, store: cache
            )
        else { return XCTFail("a changed bundle must calibrate again") }
    }

    func testFailedCalibrationResolvesToMarksOnly() throws {
        let cache = store()
        guard
            case .needsCalibration(let key) = GroundingProfileResolver.resolve(
                modelId: "m", directory: directory, budget: .standard, store: cache
            )
        else { return XCTFail("expected needsCalibration") }
        cache.record(GroundingCalibration.Result(outcome: .marksOnly, hits: [:], trials: 5), for: key)
        XCTAssertEqual(
            GroundingProfileResolver.resolve(modelId: "m", directory: directory, budget: .standard, store: cache),
            .marksOnly
        )
    }

    // MARK: Synthetic screens

    func testScreensFitEachBudgetAndDiscriminateEveryFrame() throws {
        let budgets: [FrameBudget] = [
            .standard,
            // Qwen3-VL: pixel-count cap 16_777_216, 32 px multiple.
            FrameBudget(maxLongEdge: 4096, maxPixels: 16_777_216, multiple: 32),
            // Holo1: max_pixels 1_003_520, 28 px multiple.
            FrameBudget(maxLongEdge: 4096, maxPixels: 1_003_520, multiple: 28),
        ]
        for budget in budgets {
            let trials = GroundingCalibration.trials(budget: budget)
            XCTAssertEqual(trials.count, GroundingCalibration.screenSizes.count, "\(budget)")
            for trial in trials {
                XCTAssertLessThanOrEqual(trial.image.width * trial.image.height, budget.maxPixels)
                XCTAssertEqual(trial.image.width % budget.multiple, 0)
                XCTAssertEqual(trial.image.height % budget.multiple, 0)
                XCTAssertTrue(
                    GroundingCalibration.isDiscriminating(
                        trial.box, width: Double(trial.image.width), height: Double(trial.image.height)
                    )
                )
                let decoded = try XCTUnwrap(FramePreparationTests.decode(trial.image))
                XCTAssertEqual(decoded.width, trial.image.width)
                XCTAssertEqual(decoded.height, trial.image.height)
            }
            XCTAssertEqual(Set(trials.map(\.label)).count, trials.count, "each screen asks for a different button")
        }
    }

    // MARK: Scoring

    private func answers(
        _ frame: GroundingProfile.CoordinateFrame, for trials: [GroundingCalibration.Trial]
    ) -> [AgentPoint?] {
        trials.map { trial in
            let w = Double(trial.image.width)
            let h = Double(trial.image.height)
            let ppu = GroundingProfile(frame: frame, source: .calibrated).pixelsPerUnit(width: w, height: h)
            return AgentPoint(x: trial.box.midX / ppu.x, y: trial.box.midY / ppu.y)
        }
    }

    func testScoringAdoptsTheFrameTheModelAnswersIn() {
        let trials = GroundingCalibration.trials(budget: .standard)
        for frame in GroundingProfile.CoordinateFrame.allCases {
            let result = GroundingCalibration.score(points: answers(frame, for: trials), trials: trials)
            XCTAssertEqual(result.outcome, .frame(frame))
            XCTAssertEqual(result.hits[frame], trials.count)
            for other in GroundingProfile.CoordinateFrame.allCases where other != frame {
                XCTAssertEqual(result.hits[other], 0, "\(frame) answers must not score under \(other)")
            }
        }
    }

    func testScoringFallsBackToMarksOnlyBelowTheThreshold() {
        let trials = GroundingCalibration.trials(budget: .standard)
        var points = answers(.normalized1000, for: trials)
        // Three of five is below the two-thirds bar.
        points[0] = nil
        points[1] = AgentPoint(x: 1, y: 1)
        XCTAssertEqual(GroundingCalibration.score(points: points, trials: trials).outcome, .marksOnly)
        XCTAssertEqual(
            GroundingCalibration.score(points: Array(repeating: nil, count: trials.count), trials: trials).outcome,
            .marksOnly
        )
    }

    // MARK: Run

    func testRunNamesNoConventionAndScoresTheModelsAnswers() async throws {
        let trials = GroundingCalibration.trials(budget: .standard)
        let expected = answers(.normalized1000, for: trials)
        var index = 0
        var prompts: [[ChatMessage]] = []
        let result = try await GroundingCalibration.run(budget: .standard) { messages in
            prompts.append(messages)
            defer { index += 1 }
            let point = try XCTUnwrap(expected[index])
            let args = #"{"verb":"click","target":{"point":{"x":\#(point.x),"y":\#(point.y)}}}"#
            return ComputerUseLoop.ModelStepResult(call: ModelActionCall(id: "c\(index)", arguments: args), tokensPerSecond: 20)
        }
        XCTAssertEqual(result.outcome, .frame(.normalized1000))
        XCTAssertEqual(result.decodeTokensPerSecond.count, trials.count)

        let first = try XCTUnwrap(prompts.first)
        let system = try XCTUnwrap(first.first?.content)
        XCTAssertFalse(system.contains("pixel coordinates"))
        XCTAssertFalse(system.contains("0–1000"))
        XCTAssertTrue(first.last?.contentParts?.contains { if case .imageUrl = $0 { true } else { false } } ?? false)
    }

    func testRunStopsWhenInterrupted() async {
        do {
            _ = try await GroundingCalibration.run(budget: .standard, isInterrupted: { true }) { _ in
                XCTFail("no model step after an interrupt")
                return ComputerUseLoop.ModelStepResult(call: nil)
            }
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
