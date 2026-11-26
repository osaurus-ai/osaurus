//
//  ComputerUseLoopPerceptionTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Pixels by default: a run whose frames reach the model without asking
//  (image model, Screen Recording on, on-device or already consented)
//  perceives with a marked screenshot from the first turn and on every
//  verify; the frame is fitted to the run's budget and `target.point` is
//  read in the fitted pixels. Remote models without consent, and runs
//  without Screen Recording, stay on the element list without a prompt.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseLoopPerceptionTests: XCTestCase {

    private let pid: Int32 = 5151
    private let window = CUScreenRegion(x: 0, y: 0, w: 800, h: 600)

    private func driver(screenRecording: Bool = true) throws -> MockMacDriver {
        let frame = try FramePreparationTests.solidImage(width: 400, height: 300, region: window)
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Main",
            tier: .som,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: [
                CUElement(id: "go", role: "button", label: "Go", x: 100, y: 100, w: 80, h: 30),
                CUElement(id: "delete", role: "button", label: "Delete", x: 300, y: 200, w: 80, h: 30),
            ],
            image: frame
        )
        return MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: screenRecording, skyLight: true),
            activeWindow: CUActiveWindow(pid: pid, app: "Demo", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snapshot]]
        )
    }

    private let localVision = VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false)

    private func run(
        _ driver: MockMacDriver,
        _ actions: [AgentAction],
        vision: VisionContext,
        feed: SubagentFeed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "goal"),
        transcripts: TranscriptLog = TranscriptLog(),
        requestConsent: @escaping @Sendable () async -> CloudVisionConsentChoice = { .deny }
    ) async -> ComputerUseRunResult {
        let script = ComputerUseLoop.scriptedProvider(actions + [AgentAction(verb: .giveUp, reason: "end")])
        return await ComputerUseLoop.run(
            goal: "goal",
            modelId: "test-model",
            driver: driver,
            gate: RunEverythingGate(),
            feed: feed,
            interrupt: InterruptToken(),
            confirm: { _ in true },
            requestCloudVisionConsent: requestConsent,
            limits: RunLimits(wallClockSeconds: 30),
            vision: vision,
            sessionId: "cu-perception",
            nextAction: { input in
                await transcripts.record(input.transcript)
                return try await script(input)
            }
        )
    }

    private static func screenshotNotes(_ turns: [AgentStepInput.Turn]) -> [String] {
        turns.filter { $0.role == "user" && $0.text.hasPrefix("Screenshot of the current view") }.map(\.text)
    }

    func testImageModelSeesAMarkedFrameOnTheFirstTurn() async throws {
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "goal")
        let log = TranscriptLog()
        _ = await run(try driver(), [], vision: localVision, feed: feed, transcripts: log)
        let turns = await log.turns
        let first = try XCTUnwrap(turns.first)
        let notes = Self.screenshotNotes(first)
        XCTAssertEqual(notes.count, 1, "The first decision already has a frame: \(first)")
        XCTAssertTrue(notes[0].contains("numbered red box"), notes[0])
        XCTAssertTrue(notes[0].contains("400×300"), notes[0])
        XCTAssertTrue(feed.currentEvents().contains { $0.step == 0 && $0.title == "Attached a screenshot" })
    }

    func testEveryVerifyCarriesAFreshFrame() async throws {
        let feed = SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "goal")
        _ = await run(
            try driver(),
            [AgentAction(verb: .click, target: AgentTarget(mark: 1))],
            vision: localVision,
            feed: feed
        )
        let attached = feed.currentEvents().filter { $0.title == "Attached a screenshot" }
        XCTAssertEqual(attached.map(\.step), [0, 1], "Initial frame, then the verify frame after the click")
    }

    func testWithoutScreenRecordingTheRunStaysOnTheElementList() async throws {
        let log = TranscriptLog()
        _ = await run(try driver(screenRecording: false), [], vision: localVision, transcripts: log)
        let turns = await log.turns
        let first = try XCTUnwrap(turns.first)
        XCTAssertTrue(Self.screenshotNotes(first).isEmpty)
    }

    func testRemoteModelWithoutConsentGetsNoDefaultFrameAndNoPrompt() async throws {
        let asked = ConsentAsks()
        let log = TranscriptLog()
        _ = await run(
            try driver(),
            [AgentAction(verb: .click, target: AgentTarget(mark: 1))],
            vision: VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: false),
            transcripts: log,
            requestConsent: {
                await asked.ask()
                return .deny
            }
        )
        let count = await asked.count
        XCTAssertEqual(count, 0, "Default perception must not ask for cloud vision")
        for turns in await log.turns {
            XCTAssertTrue(Self.screenshotNotes(turns).isEmpty)
        }
    }

    func testFrameIsFittedToTheBudgetAndPointsUseTheFittedPixels() async throws {
        let d = try driver()
        let log = TranscriptLog()
        let vision = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: true,
            cloudConsent: false,
            frameBudget: FrameBudget(maxLongEdge: 1568, maxPixels: 30_000)
        )
        _ = await run(
            d,
            [AgentAction(verb: .click, target: AgentTarget(point: AgentPoint(x: 50, y: 50)))],
            vision: vision,
            transcripts: log
        )
        let turns = await log.turns
        let first = try XCTUnwrap(turns.first)
        XCTAssertTrue(Self.screenshotNotes(first).first?.contains("200×150") == true, "\(first)")
        let clicks = await d.coordinateActions
        guard case .click(let x, let y, _, _, _)? = clicks.first else {
            return XCTFail("Expected a coordinate click; got \(clicks)")
        }
        XCTAssertEqual(x, 200)
        XCTAssertEqual(y, 200)
    }

    func testRestingTierFollowsTheVisionPosture() {
        let on = MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true)
        let off = MacDriverAvailability(accessibility: true, screenRecording: false, skyLight: true)
        XCTAssertEqual(ComputerUseLoop.restingTier(vision: localVision, availability: on), .som)
        XCTAssertEqual(ComputerUseLoop.restingTier(vision: localVision, availability: off), .ax)
        XCTAssertEqual(ComputerUseLoop.restingTier(vision: .none, availability: on), .ax)
        let remote = VisionContext(modelAcceptsImages: true, modelIsLocal: false, cloudConsent: false)
        XCTAssertEqual(ComputerUseLoop.restingTier(vision: remote, availability: on), .ax)
        XCTAssertEqual(ComputerUseLoop.restingTier(vision: remote.withConsent(true), availability: on), .som)
    }
}

actor TranscriptLog {
    private(set) var turns: [[AgentStepInput.Turn]] = []
    func record(_ transcript: [AgentStepInput.Turn]) { turns.append(transcript) }
}

private actor ConsentAsks {
    private(set) var count = 0
    func ask() { count += 1 }
}
