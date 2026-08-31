//
//  MemoryPressureWiringTests.swift
//  OsaurusCoreTests
//
//  Two things this pins that the model-level tests cannot.
//
//  1. That the advisory is CONNECTED. A warning computed correctly and never
//     rendered is the exact shape of an earlier defect in this codebase —
//     vmlx populated nativeMTPStats every turn and the app never read it.
//
//  2. That it only ever WARNS. The standing rule is that an estimate may
//     advise and may never refuse: a heuristic about memory must not become a
//     wall between a user and their model. This asserts the advisory path
//     contains no throw, no refusal, and no gate, so a later edit cannot
//     quietly turn a hint into a block.
//
//  Source coverage rather than UI-driven, because the popover cannot be driven
//  reliably in this harness and a wiring assertion that only runs when someone
//  can click is one that silently stops running.
//

import XCTest

@testable import OsaurusCore

final class MemoryPressureWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Connected

    func testLocalMemoryWarningsDoNotApplyToCloudModelsOrRemoteAgentRuns() {
        XCTAssertTrue(
            FloatingInputCard.localMemoryWarningsApply(
                isSelectedModelLocal: true,
                isRemoteAgentRun: false
            )
        )
        XCTAssertFalse(
            FloatingInputCard.localMemoryWarningsApply(
                isSelectedModelLocal: false,
                isRemoteAgentRun: false
            )
        )
        XCTAssertFalse(
            FloatingInputCard.localMemoryWarningsApply(
                isSelectedModelLocal: true,
                isRemoteAgentRun: true
            )
        )
    }

    func testComposerClearsAndSuppressesStaleLocalMemoryWarnings() throws {
        let src = try source("Views/Chat/FloatingInputCard.swift")
        XCTAssertTrue(src.contains("guard localMemoryWarningsApplyToSelectedModel else"))
        XCTAssertTrue(src.contains("if localMemoryWarningsApplyToSelectedModel,"))
        XCTAssertTrue(
            src.contains("guard selectedModel == model, localMemoryWarningsApplyToSelectedModel else")
        )
    }

    func testAdvisoryIsRenderedInTheContextPanel() throws {
        let src = try source("Views/Chat/FloatingInputCard.swift")
        XCTAssertTrue(
            src.contains("memoryPressureSection(memoryPressure)"),
            "the advisory is computed but never rendered")
        XCTAssertTrue(
            src.contains("var memoryPressure: MemoryPressureAdvisory?"),
            "the panel takes no advisory input")
    }

    func testProbeIsActuallySampledWhilePanelIsOpen() throws {
        let src = try source("Views/Chat/FloatingInputCard.swift")
        XCTAssertTrue(
            src.contains("HostMemoryPressureProbe.sample()"),
            "nothing ever reads host memory, so the advisory can never fire")
        XCTAssertTrue(
            src.contains("MemoryPressureAdvisory.evaluate("),
            "samples are taken but never evaluated")
    }

    /// The signal is a RATE. One sample cannot produce one, and a stale
    /// baseline from a previous opening would average over however long the
    /// panel was closed.
    func testBaselineIsResetWhenThePanelOpens() throws {
        let src = try source("Views/Chat/FloatingInputCard.swift")
        XCTAssertTrue(
            src.contains("previousMemorySample = nil"),
            "a stale baseline would produce a rate averaged over the closed period")
    }

    // MARK: - Advises, never refuses

    /// The whole advisory surface must be inert with respect to control flow.
    func testAdvisoryPathContainsNoRefusal() throws {
        for path in [
            "Models/Chat/MemoryPressureAdvisory.swift",
            "Services/ModelRuntime/HostMemoryPressureProbe.swift",
        ] {
            let src = try source(path)
            for forbidden in ["throw ", "fatalError", "preconditionFailure", "exit("] {
                XCTAssertFalse(
                    src.contains(forbidden),
                    "\(path) contains '\(forbidden)' — an advisory must never refuse")
            }
        }
    }

    /// A failed probe must be "no sample", never a fabricated reading that
    /// could either warn spuriously or mask a real problem.
    func testFailedProbeReturnsNilRatherThanAFabricatedReading() throws {
        let src = try source("Services/ModelRuntime/HostMemoryPressureProbe.swift")
        XCTAssertTrue(src.contains("guard result == KERN_SUCCESS else { return nil }"))
        XCTAssertTrue(src.contains("guard sysctlbyname(\"vm.swapusage\""))
    }

    /// Nothing may consult the advisory to decide whether to load or generate.
    func testNothingGatesLoadingOnMemoryPressure() throws {
        for path in [
            "Services/ModelRuntime.swift",
            "Services/Chat/AgentToolLoop.swift",
        ] {
            let src = try source(path)
            XCTAssertFalse(
                src.contains("MemoryPressureAdvisory"),
                "\(path) consults the advisory — it must not influence loading or generation")
        }
    }

    // MARK: - Threshold provenance

    /// Guards the trap this feature nearly shipped with: swap percentage looks
    /// like the obvious trigger and is unusable, because macOS grows swap on
    /// demand and healthy machines sit high.
    func testSwapFractionIsNotUsedAsTheTrigger() throws {
        let src = try source("Models/Chat/MemoryPressureAdvisory.swift")
        let evaluate = src.range(of: "static func evaluate").map { String(src[$0.lowerBound...]) }
        let body = try XCTUnwrap(evaluate).prefix(900)
        XCTAssertFalse(
            body.contains("swapUsedFraction"),
            "swap percentage is not a valid trigger — healthy Macs read high")
        XCTAssertTrue(body.contains("freeBytes"))
        XCTAssertTrue(body.contains("decompressionRate"))
    }
}
