//
//  ComputerUseLoopGroundingTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The loop reads `target.point` and zoom regions in the run's grounding
//  frame, tells the model that frame in the schema, prompt, and image note,
//  refuses coordinates when the model has no profile, and calibrates an
//  unstated local bundle once through its own model step.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseLoopGroundingTests: XCTestCase {

    private let pid: Int32 = 6161
    private let window = CUScreenRegion(x: 0, y: 0, w: 800, h: 600)

    private func driver() throws -> MockMacDriver {
        let frame = try FramePreparationTests.solidImage(width: 400, height: 300, region: window)
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: .som,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: [CUElement(id: "go", role: "button", label: "Go", x: 360, y: 280, w: 80, h: 40)],
            image: frame
        )
        return MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true),
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snapshot]]
        )
    }

    private func vision(_ grounding: GroundingProfile?) -> VisionContext {
        VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false, grounding: grounding)
    }

    private func run(
        _ driver: MockMacDriver,
        _ actions: [AgentAction],
        vision: VisionContext,
        transcripts: TranscriptLog
    ) async -> ComputerUseRunResult {
        let script = ComputerUseLoop.scriptedProvider(actions + [AgentAction(verb: .giveUp, reason: "end")])
        return await ComputerUseLoop.run(
            goal: "goal",
            modelId: "test-model",
            driver: driver,
            gate: RunEverythingGate(),
            feed: SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "goal"),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(wallClockSeconds: 30),
            vision: vision,
            sessionId: "cu-grounding",
            nextAction: { input in
                await transcripts.record(input.transcript)
                return try await script(input)
            }
        )
    }

    // MARK: Frames in the loop

    func testNormalizedPointMapsThroughTheProfile() async throws {
        let d = try driver()
        let log = TranscriptLog()
        _ = await run(
            d,
            [AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 500, y: 500)))],
            vision: vision(GroundingProfile(frame: .normalized1000, source: .calibrated)),
            transcripts: log
        )
        let clicks = await d.coordinateActions
        guard case .click(let x, let y, _, _, _)? = clicks.first else {
            return XCTFail("Expected a coordinate click; got \(clicks)")
        }
        XCTAssertEqual(x, 400)
        XCTAssertEqual(y, 300)

        let turns = await log.turns
        let first = try XCTUnwrap(turns.first)
        XCTAssertTrue(first.first?.text.contains("0–1000 scale of the latest screenshot") == true)
        let note = try XCTUnwrap(first.first { $0.text.hasPrefix("Screenshot of the current view") })
        XCTAssertTrue(note.text.contains("0–1000 scale"), note.text)
        XCTAssertFalse(note.text.contains("400×300 pixels"), note.text)
    }

    func testNormalizedZoomRegionMapsThroughTheProfile() async throws {
        let d = try driver()
        _ = await run(
            d,
            [AgentAction(verb: .zoom, region: AgentRegion(x: 250, y: 250, width: 500, height: 500))],
            vision: vision(GroundingProfile(frame: .normalized1000, source: .declared)),
            transcripts: TranscriptLog()
        )
        let zooms = await d.zoomCalls
        XCTAssertEqual(zooms, [CUScreenRegion(x: 200, y: 150, w: 400, h: 300)])
    }

    func testWithoutAProfilePointsAndZoomAreRefused() async throws {
        let d = try driver()
        let log = TranscriptLog()
        _ = await run(
            d,
            [
                AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 200, y: 150))),
                AgentAction(verb: .zoom, region: AgentRegion(x: 0, y: 0, width: 100, height: 100)),
            ],
            vision: vision(nil),
            transcripts: log
        )
        let clicks = await d.coordinateActions
        XCTAssertTrue(clicks.isEmpty, "A model without a profile never clicks by coordinates: \(clicks)")
        let zooms = await d.zoomCalls
        XCTAssertTrue(zooms.isEmpty)

        let turns = await log.turns
        let first = try XCTUnwrap(turns.first)
        let system = try XCTUnwrap(first.first?.text)
        XCTAssertFalse(system.contains("`target.point` with"), system)
        XCTAssertFalse(system.contains("`zoom`"), system)
        let note = try XCTUnwrap(first.first { $0.text.hasPrefix("Screenshot of the current view") })
        XCTAssertTrue(note.text.hasSuffix("address it by `mark` or `describe`."), note.text)
        let results = turns.flatMap { $0 }.map(\.text)
        XCTAssertTrue(results.contains { $0.contains(ScreenshotPointing.ungroundedPointReason) })
        XCTAssertTrue(results.contains { $0.contains(ScreenshotPointing.ungroundedZoomReason) })
    }

    func testSchemaNamesTheFrame() throws {
        func pointText(_ pointing: PointingSurface) -> String { AgentAction.pointDescription(pointing) }
        XCTAssertTrue(pointText(.frame(.pixels)).hasPrefix("Pixel coordinates"))
        XCTAssertTrue(pointText(.frame(.normalized1000)).contains("0–1000"))
        XCTAssertTrue(pointText(.frame(.normalizedUnit)).contains("0–1 scale"))
        XCTAssertTrue(pointText(.marksOnly).contains("Not available"))
        for frame in ["Pixel", "pixel", "0–1000", "0–1 "] {
            XCTAssertFalse(pointText(.unstated).contains(frame), "calibration must not name a convention")
        }
        XCTAssertEqual(
            AgentAction.toolSpec(pointing: .frame(.pixels)).function.parameters, AgentAction.schema,
            "The pixel schema is the unchanged default"
        )
    }

    // MARK: Calibration

    /// Answers each calibration screen at its target's center in 0–1000.
    private actor ThousandsEngine: ResponsesEngineProtocol {
        let trials: [GroundingCalibration.Trial]
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(trials: [GroundingCalibration.Trial]) { self.trials = trials }

        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            let index = requests.count
            requests.append(request)
            let trial = trials[index % trials.count]
            let x = trial.box.midX / Double(trial.image.width) * 1000
            let y = trial.box.midY / Double(trial.image.height) * 1000
            let call = ResponsesFunctionCall(
                id: "fc\(index)", callID: "call\(index)", name: AgentAction.toolName,
                arguments: #"{"verb":"click","target":{"point":{"x":\#(x),"y":\#(y)}}}"#
            )
            return AsyncThrowingStream { continuation in
                continuation.yield(.inputTokenCount(900))
                continuation.yield(
                    .responseCompleted(
                        .init(
                            responseID: "r\(index)", status: .completed, functionCalls: [call],
                            tokenCount: 20, tokensPerSecond: 25, unclosedReasoning: false, stopReason: "stop",
                            promptTokensPerSecond: nil, mtp: nil
                        )
                    )
                )
            }
        }
    }

    func testUnstatedBundleIsCalibratedOnceAndCached() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-grounding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GroundingCalibrationStore(fileURL: directory.appendingPathComponent("grounding.json"))
        let key = GroundingCalibrationKey(modelId: "local-vl", fingerprint: "abc", budget: .standard)
        let pending = VisionContext(
            modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false, grounding: nil,
            pendingCalibration: key
        )
        let engine = ThousandsEngine(trials: GroundingCalibration.trials(budget: .standard))
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "goal")

        let grounded = await ComputerUseLoop.groundedVision(
            pending,
            engine: engine,
            modelId: "local-vl",
            sessionId: "s",
            enableThinking: nil,
            reasoningEffort: nil,
            limits: RunLimits(wallClockSeconds: 30),
            interrupt: InterruptToken(),
            feed: feed,
            store: store
        )
        XCTAssertEqual(grounded.grounding, GroundingProfile(frame: .normalized1000, source: .calibrated))
        XCTAssertNil(grounded.pendingCalibration)
        XCTAssertEqual(store.outcome(for: key), .frame(.normalized1000))
        XCTAssertTrue(feed.currentEvents().contains { $0.title == "This model points in a 0–1000 scale" })

        let requests = await engine.requests
        XCTAssertEqual(requests.count, GroundingCalibration.screenSizes.count)
        let schema = try XCTUnwrap(requests.first?.tools?.first?.function.parameters)
        XCTAssertEqual(schema, GroundingCalibration.toolSpec.function.parameters)
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(schema), encoding: .utf8))
        XCTAssertFalse(text.contains("\"mark\"") || text.contains("describe"))
        XCTAssertFalse(text.lowercased().contains("pixel") || text.contains("1000"))
        XCTAssertEqual(requests.first?.input.first?.content, GroundingCalibration.systemPrompt)
    }
}
