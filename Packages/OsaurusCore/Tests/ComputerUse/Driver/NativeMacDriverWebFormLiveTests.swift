//
//  NativeMacDriverWebFormLiveTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Opt-in live proof that `ComputerUseLoop` can drive a real local browser form
//  through the native macOS driver: fill fields, accept terms, submit, and
//  observe the submitted page through accessibility.
//
//  This lane opens a local `file://` fixture in Safari and requires a real GUI
//  session plus Accessibility permission. It is gated separately from the
//  lower-level live input tests so the default `ComputerUse` test filter skips
//  it in CI:
//
//    OSAURUS_CU_LIVE_WEB_FORM=1 \
//      swift test --package-path Packages/OsaurusCore \
//      --filter NativeMacDriverWebFormLiveTests
//
//  For privacy, the test skips when Safari is already running. That keeps the
//  AX tree scoped to the temporary local fixture instead of unrelated tabs.
//

import AppKit
import ApplicationServices
import Foundation
import XCTest

@testable import OsaurusCore

final class NativeMacDriverWebFormLiveTests: XCTestCase {

    private let driver = NativeMacDriver()
    private let browserBundleId = "com.apple.Safari"
    private let browserName = "Safari"

    private let teamValue = "Live Platform Team"
    private let emailValue = "access-request@example.invalid"
    private let justificationValue = "Validate local browser form completion."

    // MARK: - Proof

    func testStagedFixtureUsesLocalGetSubmission() throws {
        let staged = try stageLiveFixture()
        defer { try? FileManager.default.removeItem(at: staged) }

        let request = try String(
            contentsOf: staged.appendingPathComponent("request.html"),
            encoding: .utf8
        )
        #if os(macOS)
        XCTAssertTrue(request.contains(#"method="get""#))
        XCTAssertTrue(request.contains(#"action="submitted.html""#))
        XCTAssertFalse(request.contains(#"method="post""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("submitted.html").path))
        #endif
    }

    func testNativeDriverFillsAndSubmitsLocalSafariForm() async throws {
        try requireLiveWebFormLane()

        let launched = try await launchSafariWithLiveFixture()
        addTeardownBlock { [launched] in
            if launched.shouldTerminateBrowser {
                NSRunningApplication(processIdentifier: launched.pid)?.terminate()
            }
            try? FileManager.default.removeItem(at: launched.fixtureDirectory)
        }

        try await waitForRequestForm(pid: launched.pid, timeout: 10)

        let fillResult = await ComputerUseLoop.run(
            goal: "Fill out the local access request form, but do not submit it yet.",
            modelId: "scripted-live-web-form-fill",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "live-web-form-fill-\(UUID().uuidString)",
                kindId: "computer_use",
                title: "Fill local web form"
            ),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 6, wallClockSeconds: 60, modelStepTimeoutSeconds: 5),
            vision: .none,
            sessionId: "live-web-form-fill-\(UUID().uuidString)",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Team name"),
                    text: teamValue,
                    replace: true
                ),
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Email"),
                    text: emailValue,
                    replace: true
                ),
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Justification"),
                    text: justificationValue,
                    replace: true
                ),
                AgentAction(verb: .click, target: AgentTarget(describe: "Agree to terms")),
                AgentAction(verb: .done, reason: "The local form is filled and ready to submit."),
            ])
        )

        XCTAssertTrue(fillResult.outcome.isSuccess, "Form fill loop did not finish.")
        XCTAssertFalse(fillResult.metrics.cloudVisionUsed, "Live web-form proof should stay AX-only.")

        let filledState = try await pollRequestState(pid: launched.pid, timeout: 5)
        XCTAssertTrue(filledState.teamFilled, "Team field was not filled.")
        XCTAssertTrue(filledState.emailFilled, "Email field was not filled.")
        XCTAssertTrue(filledState.justificationFilled, "Justification field was not filled.")
        XCTAssertTrue(filledState.termsAccepted, "Terms checkbox was not accepted.")
        XCTAssertTrue(filledState.submitVisible, "Submit button was not visible after filling.")

        let submitRecorder = ConfirmationRecorder()
        let submitResult = await ComputerUseLoop.run(
            goal: "Submit the already-filled local access request form.",
            modelId: "scripted-live-web-form-submit",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "live-web-form-submit-\(UUID().uuidString)",
                kindId: "computer_use",
                title: "Submit local web form"
            ),
            interrupt: InterruptToken(),
            confirm: { preview in
                await submitRecorder.record(preview)
                return true
            },
            limits: RunLimits(maxSteps: 4, wallClockSeconds: 45, modelStepTimeoutSeconds: 5),
            vision: .none,
            sessionId: "live-web-form-submit-\(UUID().uuidString)",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(describe: "Submit request")),
                AgentAction(verb: .wait, seconds: 1),
                AgentAction(verb: .done, reason: "The local form was submitted."),
            ])
        )

        XCTAssertTrue(submitResult.outcome.isSuccess, "Form submit loop did not finish.")
        XCTAssertFalse(submitResult.metrics.cloudVisionUsed, "Submit proof should stay AX-only.")

        let confirmations = await submitRecorder.previews()
        XCTAssertEqual(confirmations.map(\.effect), [.consequential])

        let submitted = try await pollSubmittedState(pid: launched.pid, timeout: 10)
        XCTAssertTrue(submitted, "Submitted status was not visible through accessibility.")
    }

    // MARK: - Gating

    private func requireLiveWebFormLane() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OSAURUS_CU_LIVE_WEB_FORM"] == "1",
            "Live browser web-form lane — set OSAURUS_CU_LIVE_WEB_FORM=1 to run."
        )
        try XCTSkipUnless(AXIsProcessTrusted(), "Test runner lacks Accessibility permission.")
        try XCTSkipUnless(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleId) != nil,
            "\(browserName) is not installed."
        )
    }

    // MARK: - Browser / fixture

    private struct LaunchedBrowser {
        let pid: pid_t
        let shouldTerminateBrowser: Bool
        let fixtureDirectory: URL
    }

    private func launchSafariWithLiveFixture() async throws -> LaunchedBrowser {
        let preexistingPids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleId)
                .map(\.processIdentifier)
        )
        if !preexistingPids.isEmpty {
            throw XCTSkip(
                "\(browserName) is already running. Close it before running this live proof."
            )
        }

        let stagedFixture = try stageLiveFixture()
        let requestURL = stagedFixture.appendingPathComponent("request.html")
        var didReturnBrowser = false
        defer {
            if !didReturnBrowser {
                try? FileManager.default.removeItem(at: stagedFixture)
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-F", "-a", browserName, requestURL.absoluteString]
        do {
            try proc.run()
        } catch {
            throw XCTSkip("Could not launch \(browserName).")
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("\(browserName) launch command failed.")
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: browserBundleId)
            if let app = apps.first(where: { !preexistingPids.contains($0.processIdentifier) })
                ?? apps.first
            {
                app.activate(options: [.activateAllWindows])
                try await Task.sleep(nanoseconds: 1_500_000_000)
                didReturnBrowser = true
                return LaunchedBrowser(
                    pid: app.processIdentifier,
                    shouldTerminateBrowser: preexistingPids.isEmpty,
                    fixtureDirectory: stagedFixture
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw XCTSkip("\(browserName) did not come up within the deadline.")
    }

    private func stageLiveFixture() throws -> URL {
        let source = webFormFixtureDirectory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-cu-live-web-form-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let requestSource = source.appendingPathComponent("request.html")
        let submittedSource = source.appendingPathComponent("submitted.html")
        let requestDestination = directory.appendingPathComponent("request.html")
        let submittedDestination = directory.appendingPathComponent("submitted.html")

        var request = try String(contentsOf: requestSource, encoding: .utf8)
        request = request.replacingOccurrences(of: #"action="./submitted.html""#, with: #"action="submitted.html""#)
        request = request.replacingOccurrences(of: #"method="post""#, with: #"method="get""#)
        try request.write(to: requestDestination, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: submittedSource, to: submittedDestination)
        return directory
    }

    private func webFormFixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/WebForm", isDirectory: true)
            .standardizedFileURL
    }

    // MARK: - Polling

    private func waitForRequestForm(pid: pid_t, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastRoleCount = 0
        while Date() < deadline {
            let state = await requestState(pid: pid)
            if state.allControlsVisible { return }
            lastRoleCount = state.roleCount
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw XCTSkip(
            "\(browserName) did not expose the local form controls through accessibility "
                + "(\(lastRoleCount) roles observed)."
        )
    }

    private func pollRequestState(pid: pid_t, timeout: TimeInterval) async throws -> RequestFormState {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = RequestFormState.empty
        while Date() < deadline {
            latest = await requestState(pid: pid)
            if latest.isFilledAndReadyToSubmit { return latest }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return latest
    }

    private func pollSubmittedState(pid: pid_t, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await captureFullAX(pid: pid)
            if submittedStateVisible(in: snapshot) { return true }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func requestState(pid: pid_t) async -> RequestFormState {
        let snapshot = await captureFullAX(pid: pid)
        let elements = fixtureElements(in: snapshot)
        let team = formField(named: "Team name", in: elements)
        let email = formField(named: "Email", in: elements)
        let justification = formField(named: "Justification", in: elements)
        let terms = checkbox(named: "Agree to terms", in: elements)
        let submit = button(named: "Submit request", in: elements)

        return RequestFormState(
            teamVisible: team != nil,
            emailVisible: email != nil,
            justificationVisible: justification != nil,
            termsVisible: terms != nil,
            submitVisible: submit != nil,
            teamFilled: element(team, hasValue: teamValue),
            emailFilled: element(email, hasValue: emailValue),
            justificationFilled: element(justification, hasValue: justificationValue),
            termsAccepted: terms.map(isAcceptedCheckbox) ?? false,
            roleCount: Set(elements.map(\.role)).count
        )
    }

    private func captureFullAX(pid: pid_t) async -> CUSnapshot {
        await driver.capture(
            pid: pid,
            tier: .ax,
            windowId: nil,
            maxElements: nil,
            focusedWindowOnly: false,
            interactiveOnly: false
        )
    }

    // MARK: - AX matching

    private func fixtureElements(in snapshot: CUSnapshot) -> [CUElement] {
        let fixtureWindowIds = Set(
            snapshot.windows.compactMap { window -> Int? in
                guard let title = window.title?.lowercased() else { return nil }
                if title.contains("access request") || title.contains("request submitted") {
                    return window.id
                }
                return nil
            }
        )
        if !fixtureWindowIds.isEmpty {
            return snapshot.elements.filter { element in
                element.windowId.map { fixtureWindowIds.contains($0) } ?? false
            }
        }
        return []
    }

    private func formField(named name: String, in elements: [CUElement]) -> CUElement? {
        elements.first { element in
            let role = element.role.lowercased()
            guard role.contains("text") && !role.contains("static") else { return false }
            return matches(element, text: name)
        }
    }

    private func checkbox(named name: String, in elements: [CUElement]) -> CUElement? {
        elements.first { element in
            element.role.lowercased().contains("checkbox") && matches(element, text: name)
        }
    }

    private func button(named name: String, in elements: [CUElement]) -> CUElement? {
        elements.first { element in
            element.role.lowercased().contains("button") && matches(element, text: name)
        }
    }

    private func matches(_ element: CUElement, text: String) -> Bool {
        let needle = text.lowercased()
        return searchableText(element).contains(needle)
    }

    private func searchableText(_ element: CUElement) -> String {
        [
            element.label,
            element.value,
            element.placeholder,
            element.roleDescription,
            element.path,
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private func element(_ element: CUElement?, hasValue expected: String) -> Bool {
        guard let value = element?.value else { return false }
        return value == expected
    }

    private func isAcceptedCheckbox(_ element: CUElement) -> Bool {
        let value = element.value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "on", "checked", "yes"].contains(value ?? "") { return true }
        return searchableText(element).contains("checked")
    }

    private func submittedStateVisible(in snapshot: CUSnapshot) -> Bool {
        let windowTitles = snapshot.windows.compactMap(\.title).joined(separator: " ").lowercased()
        if windowTitles.contains("request submitted") { return true }
        let elements = fixtureElements(in: snapshot)
        return elements.contains { element in
            let role = element.role.lowercased()
            guard role.contains("static") || role.contains("text") || role.contains("heading") else {
                return false
            }
            let text = searchableText(element)
            return text.contains("request submitted") || text.contains("status: submitted")
        }
    }
}

private struct RequestFormState {
    let teamVisible: Bool
    let emailVisible: Bool
    let justificationVisible: Bool
    let termsVisible: Bool
    let submitVisible: Bool
    let teamFilled: Bool
    let emailFilled: Bool
    let justificationFilled: Bool
    let termsAccepted: Bool
    let roleCount: Int

    static let empty = RequestFormState(
        teamVisible: false,
        emailVisible: false,
        justificationVisible: false,
        termsVisible: false,
        submitVisible: false,
        teamFilled: false,
        emailFilled: false,
        justificationFilled: false,
        termsAccepted: false,
        roleCount: 0
    )

    var allControlsVisible: Bool {
        teamVisible && emailVisible && justificationVisible && termsVisible && submitVisible
    }

    var isFilledAndReadyToSubmit: Bool {
        allControlsVisible && teamFilled && emailFilled && justificationFilled && termsAccepted
    }
}

private actor ConfirmationRecorder {
    private var stored: [ActionPreview] = []

    func record(_ preview: ActionPreview) {
        stored.append(preview)
    }

    func previews() -> [ActionPreview] {
        stored
    }
}
