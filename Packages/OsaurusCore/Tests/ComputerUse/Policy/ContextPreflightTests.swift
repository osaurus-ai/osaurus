//
//  ContextPreflightTests.swift
//  OsaurusCoreTests -- Computer Use
//
//  Pure coverage for run-start contextual-integrity checks. These checks
//  protect the initial rendered view before it enters the inner model
//  transcript; action-level gates still protect subsequent clicks/typing.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseContextPreflightTests: XCTestCase {
    func testDisabledPreflightAllowsEverything() {
        let decision = ComputerUseContextPreflight.disabled.evaluate(
            goal: "read the inbox",
            appName: "Mail",
            focusedWindow: "Inbox"
        )
        XCTAssertEqual(decision, .allow)
    }

    func testRejectsOutOfScopeStartingAppBeforeModelContext() {
        let preflight = ComputerUseContextPreflight(
            policy: AutonomyPolicy(allowlist: ["Notes"]),
            modelIsLocal: true
        )
        let decision = preflight.evaluate(
            goal: "summarize this",
            appName: "Mail",
            focusedWindow: "Inbox"
        )

        guard case .reject(let reason) = decision else {
            return XCTFail("Expected allowlist preflight rejection; got \(decision)")
        }
        XCTAssertTrue(reason.contains("Mail"))
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("allowlist"))
    }

    func testAllowsMissingStartingAppEvenWithAllowlist() {
        let preflight = ComputerUseContextPreflight(
            policy: AutonomyPolicy(allowlist: ["Notes"]),
            modelIsLocal: true
        )

        XCTAssertEqual(
            preflight.evaluate(goal: "open Notes", appName: nil, focusedWindow: nil),
            .allow
        )
    }

    func testDangerousStartingAppRequiresConfirmationEvenForLocalModel() {
        let preflight = ComputerUseContextPreflight(
            policy: AutonomyPolicy(globalPreset: .autonomous),
            modelIsLocal: true
        )
        let decision = preflight.evaluate(
            goal: "check the shell",
            appName: "Terminal.app",
            focusedWindow: "zsh"
        )

        guard case .confirm(let preview, let reason) = decision else {
            return XCTFail("Expected dangerous app preflight confirmation; got \(decision)")
        }
        XCTAssertEqual(preview.appName, "Terminal.app")
        XCTAssertEqual(preview.actionLabel, "Start Computer Use")
        XCTAssertEqual(preview.targetLabel, "zsh")
        XCTAssertEqual(preview.effect, .read)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("secrets"))
    }

    func testRemotePrivacySensitiveContextRequiresConfirmation() {
        let remote = ComputerUseContextPreflight(modelIsLocal: false)
        let local = ComputerUseContextPreflight(modelIsLocal: true)

        guard case .confirm(let preview, let reason) = remote.evaluate(
            goal: "summarize the message",
            appName: "Mail",
            focusedWindow: "Inbox"
        ) else {
            return XCTFail("Remote Mail context should confirm before AX text leaves the Mac")
        }
        XCTAssertEqual(preview.appName, "Mail")
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("not local"))

        XCTAssertEqual(
            local.evaluate(goal: "summarize the message", appName: "Mail", focusedWindow: "Inbox"),
            .allow
        )
    }
}
