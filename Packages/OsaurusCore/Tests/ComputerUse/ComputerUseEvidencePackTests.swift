//
//  ComputerUseEvidencePackTests.swift
//  OsaurusCoreTests — Computer Use
//
//  CI-safe evidence for the contract documented in docs/COMPUTER_USE.md.
//  These tests intentionally stay on pure seams: prompt/tool resolution,
//  MockMacDriver-backed loop runs, the policy gate, the prompt queue, and
//  screen-context injection. They do not require Accessibility or Screen
//  Recording permissions.
//

import AppKit
import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseEvidencePackTests: XCTestCase {

    func testComputerUseGoalContractDoesNotExpandUserScope() {
        let tool = ComputerUseTool()
        XCTAssertTrue(tool.description.contains("preserve the user's requested scope exactly"))
        XCTAssertTrue(tool.description.contains("do not add saving"))
        XCTAssertEqual(
            ComputerUseTool.authoritativeGoal(
                modelGoal: "In TextEdit, replace “old” with “new” and save the file",
                userRequest: "In TextEdit, replace “old” with “new”. Do not save."
            ),
            "In TextEdit, replace “old” with “new”. Do not save.",
            "The exact user replacement, not the parent's expanded delegation, owns side-effect scope."
        )
        XCTAssertEqual(
            ComputerUseTool.authoritativeGoal(
                modelGoal: "Open the previously discussed report in TextEdit",
                userRequest: "Yes, do it"
            ),
            "Open the previously discussed report in TextEdit",
            "Non-replacement turns keep the parent model's resolved context."
        )
        XCTAssertEqual(
            ComputerUseTool.authoritativeGoal(
                modelGoal: "Open Calculator",
                userRequest: nil
            ),
            "Open Calculator",
            "Programmatic callers without a published user turn keep the explicit tool argument."
        )
    }

    private func makeSnapshot(
        agentId: UUID = UUID(),
        toolMode: ToolSelectionMode = .auto,
        manualToolNames: [String]? = nil,
        computerUseEnabled: Bool
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: true,
            autonomousConfig: nil,
            toolMode: toolMode,
            model: nil,
            manualToolNames: manualToolNames,
            systemPrompt: "",
            dbEnabled: false,
            computerUseEnabled: computerUseEnabled
        )
    }

    @MainActor
    private func toolNames(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode = .none,
        additionalToolNames: Set<String> = []
    ) -> Set<String> {
        Set(
            SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: executionMode,
                additionalToolNames: additionalToolNames
            ).map { $0.function.name }
        )
    }

    @MainActor
    func testComputerUseToolIsCustomAgentOptInOnly() {
        XCTAssertTrue(
            toolNames(snapshot: makeSnapshot(computerUseEnabled: true))
                .contains(ComputerUseTool.toolName),
            "A custom agent that opts in should see the computer_use tool."
        )

        XCTAssertFalse(
            toolNames(snapshot: makeSnapshot(computerUseEnabled: false))
                .contains(ComputerUseTool.toolName),
            "Computer Use must stay hidden until the custom agent opts in."
        )

        XCTAssertFalse(
            toolNames(
                snapshot: makeSnapshot(computerUseEnabled: false),
                additionalToolNames: [ComputerUseTool.toolName]
            ).contains(ComputerUseTool.toolName),
            "capabilities_load/additional tools must not bypass the opt-in gate."
        )

        XCTAssertFalse(
            toolNames(
                snapshot: makeSnapshot(
                    toolMode: .manual,
                    manualToolNames: [ComputerUseTool.toolName],
                    computerUseEnabled: false
                )
            ).contains(ComputerUseTool.toolName),
            "Manual tool selection must not bypass the opt-in gate."
        )

        XCTAssertFalse(
            toolNames(
                snapshot: makeSnapshot(
                    agentId: Agent.defaultId,
                    computerUseEnabled: true
                )
            ).contains(ComputerUseTool.toolName),
            "The Default agent allowlist must keep Computer Use custom-agent only."
        )
    }

    func testAxResolvedRunStaysAxOnlyAndDoesNotUseScreenshots() async {
        let pid: Int32 = 4242
        let window = CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Notes",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(id: "title", role: "textfield", label: "Title", value: "", windowId: 1),
                CUElement(id: "save", role: "button", label: "Save", windowId: 1),
            ],
            image: nil
        )
        let driver = MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true),
            activeWindow: CUActiveWindow(pid: pid, app: "Notes", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snapshot]]
        )

        let result = await ComputerUseLoop.run(
            goal: "read the title field",
            modelId: "scripted",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            feed: SubagentFeed(toolCallId: "evidence-ax", kindId: "computer_use", title: "read the title field"),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 2, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-ax",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .done, reason: "Title field is visible")
            ])
        )

        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(result.metrics.maxTier, .ax)
        XCTAssertFalse(result.metrics.cloudVisionUsed)
    }

    func testBrowserFormLoopFillsFieldsAndSubmitsDeterministically() async {
        let pid: Int32 = 5150
        // MockMacDriver advances one snapshot per capture: initial observe,
        // one post-action verify per acting verb, then one final assertion read.
        // Keep status as Draft through snapshot 5 so the submit click resolves
        // against the pre-submit tree, then expose the submitted state on 6-7.
        let snapshots = [
            browserFormSnapshot(snapshotId: 1, pid: pid),
            browserFormSnapshot(snapshotId: 2, pid: pid, team: "Synthetic Platform Team"),
            browserFormSnapshot(
                snapshotId: 3,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com"
            ),
            browserFormSnapshot(
                snapshotId: 4,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request."
            ),
            browserFormSnapshot(
                snapshotId: 5,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request.",
                termsAccepted: true
            ),
            browserFormSnapshot(
                snapshotId: 6,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request.",
                termsAccepted: true,
                status: "Submitted"
            ),
            browserFormSnapshot(
                snapshotId: 7,
                pid: pid,
                team: "Synthetic Platform Team",
                email: "ops@example.com",
                justification: "Automate a repetitive access request.",
                termsAccepted: true,
                status: "Submitted"
            ),
        ]
        let driver = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: snapshots]
        )
        let confirmationRecorder = ConfirmationRecorder()

        let result = await ComputerUseLoop.run(
            goal: "Fill out and submit the access request web form.",
            modelId: "scripted-browser-form",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-browser-form",
                kindId: "computer_use",
                title: "Fill out the form"
            ),
            interrupt: InterruptToken(),
            confirm: { preview in
                await confirmationRecorder.record(preview)
                return true
            },
            limits: RunLimits(maxSteps: 8, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-browser-form",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Team name"),
                    text: "Synthetic Platform Team"
                ),
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Email"),
                    text: "ops@example.com"
                ),
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Justification"),
                    text: "Automate a repetitive access request."
                ),
                AgentAction(verb: .click, target: AgentTarget(describe: "Agree to terms")),
                AgentAction(verb: .click, target: AgentTarget(describe: "Submit request")),
                AgentAction(verb: .done, reason: "The access request form was submitted."),
            ])
        )

        XCTAssertTrue(result.outcome.isSuccess, "Expected form completion; got \(result.outcome)")
        XCTAssertEqual(result.metrics.maxTier, .ax)
        XCTAssertFalse(result.metrics.cloudVisionUsed)
        XCTAssertEqual(result.metrics.targetResolveAttempts, 5)
        XCTAssertEqual(result.metrics.targetResolveSuccesses, 5)
        XCTAssertEqual(result.metrics.actsAttempted, 5)
        XCTAssertEqual(result.metrics.verifyChanged, 5)
        XCTAssertEqual(result.metrics.confirmsRequested, 1)
        XCTAssertEqual(result.metrics.confirmsApproved, 1)

        let confirmed = await confirmationRecorder.previews()
        XCTAssertEqual(confirmed.map(\.effect), [.consequential])
        XCTAssertEqual(confirmed.first?.targetLabel, "button \"Submit request\"")

        let actions = await driver.elementActions
        XCTAssertEqual(
            privacySafeActionTrace(actions),
            [
                "setValue:team:length=23",
                "setValue:email:length=15",
                "setValue:justification:length=37",
                "click:terms",
                "click:submit",
            ]
        )
        let coordinateActions = await driver.coordinateActions
        XCTAssertTrue(coordinateActions.isEmpty, "Resolved AX form controls should not need coordinate fallback.")

        let finalSnapshot = await driver.capture(pid: pid, tier: .ax)
        XCTAssertTrue(value(in: finalSnapshot, id: "team") == "Synthetic Platform Team", "Team field did not match.")
        XCTAssertTrue(value(in: finalSnapshot, id: "email") == "ops@example.com", "Email field did not match.")
        XCTAssertTrue(
            value(in: finalSnapshot, id: "justification") == "Automate a repetitive access request.",
            "Justification field did not match."
        )
        XCTAssertTrue(value(in: finalSnapshot, id: "terms") == "checked", "Terms checkbox did not stay checked.")
        XCTAssertTrue(value(in: finalSnapshot, id: "status") == "Submitted", "Status field did not match.")
    }

    func testAmbiguousWebFormTargetStopsBeforeTyping() async {
        let pid: Int32 = 5151
        let window = CUWindowSummary(
            id: 1,
            title: "Access request form",
            focused: true,
            x: 0,
            y: 0,
            w: 1280,
            h: 900
        )
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Safari",
            focusedWindow: "Access request form",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(id: "primary-email", role: "textfield", label: "Email", value: "", windowId: 1),
                CUElement(id: "recovery-email", role: "textfield", label: "Email", value: "", windowId: 1),
                CUElement(id: "submit", role: "button", label: "Submit request", windowId: 1),
            ],
            image: nil
        )
        let driver = MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: false, skyLight: true),
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: [snapshot]]
        )

        let result = await ComputerUseLoop.run(
            goal: "Fill the email field.",
            modelId: "scripted-ambiguous-form",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-ambiguous-form",
                kindId: "computer_use",
                title: "Fill email"
            ),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(
                maxSteps: 5,
                maxConsecutiveReobserve: 2,
                maxConsecutiveDeadEnd: 1,
                wallClockSeconds: 30
            ),
            vision: .none,
            sessionId: "evidence-ambiguous-form",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Email"),
                    text: "ops@example.com"
                )
            ])
        )

        guard case .deadEnd(let reason) = result.outcome else {
            return XCTFail("Expected ambiguous target to dead-end; got \(result.outcome)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("resolve"), "Unexpected dead-end reason: \(reason)")
        XCTAssertEqual(result.metrics.targetResolveAttempts, 2)
        XCTAssertEqual(result.metrics.targetResolveSuccesses, 0)
        let elementActions = await driver.elementActions
        let coordinateActions = await driver.coordinateActions
        XCTAssertTrue(elementActions.isEmpty, "Ambiguous target must never reach element actions.")
        XCTAssertTrue(coordinateActions.isEmpty, "Ambiguous target must not fall back to coordinates.")
    }

    func testTextInputRoutesToResolvedWebFormField() async {
        let pid: Int32 = 5152
        let driver = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [
                pid: [
                    browserFormSnapshot(snapshotId: 1, pid: pid),
                    browserFormSnapshot(snapshotId: 2, pid: pid, email: "ops@example.com"),
                ]
            ]
        )

        let result = await ComputerUseLoop.run(
            goal: "Type the email address into the email field.",
            modelId: "scripted-text-routing",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-text-routing",
                kindId: "computer_use",
                title: "Type email"
            ),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-text-routing",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(describe: "Email"),
                    text: "ops@example.com"
                ),
                AgentAction(verb: .done, reason: "Email typed."),
            ])
        )

        XCTAssertTrue(result.outcome.isSuccess, "Expected resolved text routing; got \(result.outcome)")
        let actions = await driver.elementActions
        XCTAssertEqual(actions.count, 1)
        guard case .typeText(let id, let routedPid, let text, let replace) = actions.first else {
            return XCTFail("Expected typeText into the resolved field; got \(actions)")
        }
        XCTAssertEqual(id, "email")
        XCTAssertEqual(routedPid, pid)
        XCTAssertEqual(text, "ops@example.com")
        XCTAssertTrue(replace)
        let coordinateActions = await driver.coordinateActions
        XCTAssertTrue(coordinateActions.isEmpty, "Resolved text input should not use coordinates.")
    }

    func testWebFormFixtureIsLocalOnlyAndMatchesProofControls() throws {
        let request = try String(contentsOf: webFormFixtureFile("request.html"), encoding: .utf8)
        let submitted = try String(contentsOf: webFormFixtureFile("submitted.html"), encoding: .utf8)
        let combined = request + "\n" + submitted

        XCTAssertTrue(request.contains(#"action="./submitted.html""#))
        XCTAssertTrue(request.contains(#"autocomplete="off""#))
        XCTAssertTrue(request.contains(#"method="post""#))
        XCTAssertTrue(request.contains("form-action 'self'"))
        XCTAssertTrue(submitted.contains(#"href="./request.html""#))

        for forbidden in ["http://", "https://", "fetch(", "XMLHttpRequest", "sendBeacon", "src="] {
            XCTAssertFalse(
                combined.localizedCaseInsensitiveContains(forbidden),
                "The local web-form fixture must not reference external resources: \(forbidden)"
            )
        }
        for rawValue in ["Synthetic Platform Team", "ops@example.com", "Automate a repetitive access request."] {
            XCTAssertFalse(
                combined.contains(rawValue),
                "The fixture page should not contain proof-run typed contents."
            )
        }

        let requiredControls = [
            #"id="team""#,
            #"id="email""#,
            #"id="justification""#,
            #"id="terms""#,
            ">Submit request<",
        ]
        for control in requiredControls {
            XCTAssertTrue(request.contains(control), "Missing expected form control marker: \(control)")
        }
    }

    func testDangerousAppConfirmGuardrailCannotBeBypassedByAutonomousPreset() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous))
        let decision = await gate.evaluate(
            action: AgentAction(verb: .click, target: AgentTarget(describe: "New Window")),
            effect: .navigate,
            appName: "Terminal.app",
            targetLabel: "New Window"
        )

        guard case .confirm(let preview) = decision else {
            return XCTFail("Terminal navigation should require confirmation even under autonomous.")
        }
        XCTAssertEqual(preview.appName, "Terminal.app")
        XCTAssertEqual(preview.effect, .navigate)
    }

    func testDangerousOpenDeclineKeepsActionsInCurrentWebForm() async {
        let pid: Int32 = 5153
        let driver = MockMacDriver(
            apps: [
                CUAppListing(pid: pid, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: [browserFormSnapshot(snapshotId: 1, pid: pid)]]
        )
        let confirmationRecorder = ConfirmationRecorder()

        let result = await ComputerUseLoop.run(
            goal: "Try to open Terminal, then click the web form team field.",
            modelId: "scripted-dangerous-open",
            driver: driver,
            gate: ComputerUseGate(
                policy: AutonomyPolicy(
                    globalPreset: .autonomous,
                    allowlist: ["Safari", "Terminal"]
                )
            ),
            feed: SubagentFeed(
                toolCallId: "evidence-dangerous-open",
                kindId: "computer_use",
                title: "Open boundary"
            ),
            interrupt: InterruptToken(),
            confirm: { preview in
                await confirmationRecorder.record(preview)
                return false
            },
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-dangerous-open",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .open, app: "Terminal.app"),
                AgentAction(verb: .click, target: AgentTarget(describe: "Team name")),
                AgentAction(verb: .done, reason: "Stayed in the form."),
            ])
        )

        XCTAssertTrue(result.outcome.isSuccess, "Expected run to recover after declined open; got \(result.outcome)")
        let confirmed = await confirmationRecorder.previews()
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertEqual(confirmed.first?.appName, "Terminal.app")
        XCTAssertEqual(confirmed.first?.effect, .navigate)
        XCTAssertEqual(result.metrics.confirmsDeclined, 1)
        let openCalls = await driver.openCalls
        XCTAssertTrue(openCalls.isEmpty, "Declining the dangerous open must prevent the driver open call.")
        let actions = await driver.elementActions
        XCTAssertEqual(actions.count, 1)
        guard case .click(let id, _, _) = actions.first else {
            return XCTFail("Expected the follow-up action to click the original form; got \(actions)")
        }
        XCTAssertEqual(id, "team")
    }

    func testSecureWebFormFieldValuesStayOutOfScreenContextEvidence() async {
        let pid: Int32 = 5154
        let secret = "p@ssw0rd-do-not-leak"
        let window = CUWindowSummary(
            id: 1,
            title: "Access request form",
            focused: true,
            x: 0,
            y: 0,
            w: 1280,
            h: 900
        )
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Safari",
            focusedWindow: "Access request form",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [
                CUElement(id: "email", role: "textfield", label: "Email", value: "ops@example.com", windowId: 1),
                CUElement(
                    id: "password",
                    role: "securetextfield",
                    label: "Password",
                    value: secret,
                    selectedText: secret,
                    placeholder: "Password",
                    windowId: 1,
                    focused: true
                ),
            ],
            image: nil
        )
        let driver = MockMacDriver(
            apps: [
                CUAppListing(pid: pid, bundleId: "com.apple.Safari", name: "Safari", active: true, hidden: false)
            ],
            windowsByPid: [
                pid: [
                    CUWindowInfo(
                        windowId: 1,
                        title: "Access request form",
                        focused: true,
                        minimized: false,
                        x: 0,
                        y: 0,
                        w: 1280,
                        h: 900
                    )
                ]
            ],
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Access request form",
                x: 0,
                y: 0,
                w: 1280,
                h: 900
            ),
            snapshots: [pid: [snapshot]],
            focusedContent: [
                pid: CUFocusedContent(
                    role: "securetextfield",
                    label: "Password",
                    placeholder: "Password",
                    value: secret,
                    selectedText: secret,
                    viewport: secret
                )
            ]
        )
        let transcriptRecorder = TranscriptRecorder()

        let captured = await ScreenContextDistiller().capture(
            using: driver,
            selfPid: 9999,
            selfBundleId: "ai.osaurus.osaurus",
            preferredPid: nil
        )
        let rendered = captured.render()

        XCTAssertEqual(captured.focusedElement?.label, "Password")
        XCTAssertNil(captured.focusedElement?.value)
        XCTAssertNil(captured.focusedElement?.selectedText)
        XCTAssertNil(captured.focusedElement?.viewing)
        XCTAssertFalse(rendered.contains(secret))
        XCTAssertFalse(captured.sampledContents.contains { $0.contains(secret) })

        let result = await ComputerUseLoop.run(
            goal: "Inspect the secure web form.",
            modelId: "scripted-secure-field",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .trusted)),
            feed: SubagentFeed(
                toolCallId: "evidence-secure-field",
                kindId: "computer_use",
                title: "Inspect secure field"
            ),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 1, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-secure-field",
            nextAction: { input in
                await transcriptRecorder.record(input.transcript)
                let action = AgentAction(verb: .done, reason: "Secure field inspected.")
                return ModelActionCall(id: "scripted-secure-field", arguments: action.argumentsJSON())
            }
        )

        XCTAssertTrue(result.outcome.isSuccess, "Expected secure-field inspection to finish; got \(result.outcome)")
        let transcript = await transcriptRecorder.text()
        XCTAssertTrue(transcript.contains("Email"))
        XCTAssertTrue(transcript.contains("ops@example.com"))
        XCTAssertTrue(transcript.contains("Password"))
        XCTAssertFalse(transcript.contains(secret), "Secure field value leaked into the loop transcript.")
    }

    func testCloudVisionRequiresConsentAndScrubbedFrameRoute() async {
        let rawFrame = renderEvidenceCUImage(text: "Visible account number 1234")
        let noConsent = VisionContext(
            modelAcceptsImages: true,
            modelIsLocal: false,
            cloudConsent: false,
            cloudScrubMode: .allText
        )
        let available = MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true)

        XCTAssertEqual(
            VisionAttachment.decide(image: rawFrame, context: noConsent, availability: available),
            .none
        )
        XCTAssertTrue(
            VisionAttachment.wouldAttachWithConsent(
                image: rawFrame,
                context: noConsent,
                availability: available
            )
        )

        let consented = noConsent.withConsent(true)
        XCTAssertEqual(
            VisionAttachment.decide(image: rawFrame, context: consented, availability: available),
            .needsScrubForCloud(rawFrame)
        )

        let scrubbed = await FrameScrubber.scrub(rawFrame, mode: .allText)
        guard let scrubbed else {
            return XCTFail("Expected a valid rendered image to produce a ScrubbedFrame.")
        }
        XCTAssertNil(
            CaptureRouter.cloudRoute(
                scrubbed: scrubbed,
                consentGranted: false,
                availability: available
            )
        )

        guard
            case .cloudVision(let carried)? = CaptureRouter.cloudRoute(
                scrubbed: scrubbed,
                consentGranted: true,
                availability: available
            )
        else {
            return XCTFail("Consent + Screen Recording + ScrubbedFrame should produce a cloud route.")
        }
        XCTAssertEqual(carried, scrubbed)
    }

    @MainActor
    func testStopCancelResolvesPendingConfirmationAndCloudConsentPrompts() async {
        let queue = ComputerUsePromptQueue.shared
        let toolCallId = "evidence-stop-\(UUID().uuidString)"
        let preview = ActionPreview(
            appName: "Notes",
            actionLabel: "Type text",
            targetLabel: "Body",
            effect: .edit,
            note: nil,
            typedText: "hello"
        )

        let confirmation = Task { @MainActor in
            await queue.requestConfirmation(preview, toolCallId: toolCallId)
        }
        let consent = Task { @MainActor in
            await queue.requestCloudVisionConsent(toolCallId: toolCallId)
        }

        await waitForPromptQueue(toolCallId: toolCallId)
        XCTAssertTrue(queue.pending.contains { $0.toolCallId == toolCallId })
        XCTAssertTrue(queue.pendingConsent.contains { $0.toolCallId == toolCallId })

        queue.cancelAll(forToolCallId: toolCallId)

        let approved = await confirmation.value
        let consentChoice = await consent.value
        XCTAssertFalse(approved)
        XCTAssertEqual(consentChoice, .deny)
        XCTAssertFalse(queue.pending.contains { $0.toolCallId == toolCallId })
        XCTAssertFalse(queue.pendingConsent.contains { $0.toolCallId == toolCallId })
    }

    func testScreenContextPrivacyPathInjectsFrozenBlockIntoLatestUserTurnOnly() {
        let frozenBlock = """
            [Screen Context]
            Doing: In Safari
            Focused field: text field "Search"
            [/Screen Context]
            """
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "stable system prefix"),
            ChatMessage(role: "user", content: "first turn"),
            ChatMessage(role: "assistant", content: "reply"),
            ChatMessage(role: "user", content: "latest turn"),
        ]

        SystemPromptComposer.injectScreenContextPrefix(frozenBlock, into: &messages)

        XCTAssertEqual(messages[0].content, "stable system prefix")
        XCTAssertEqual(messages[1].content, "first turn")
        XCTAssertEqual(messages[3].content, "\(frozenBlock)\n\nlatest turn")
    }

    @MainActor
    private func waitForPromptQueue(toolCallId: String) async {
        for _ in 0 ..< 100 {
            if ComputerUsePromptQueue.shared.pending.contains(where: { $0.toolCallId == toolCallId }),
                ComputerUsePromptQueue.shared.pendingConsent.contains(where: { $0.toolCallId == toolCallId })
            {
                return
            }
            await Task.yield()
        }
    }

    private func renderEvidenceCUImage(text: String) -> CUImage {
        let size = CGSize(width: 640, height: 140)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: CGPoint(x: 20, y: 50), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let cg = rep.cgImage!
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        return CUImage(
            base64: png.base64EncodedString(),
            mimeType: "image/png",
            width: cg.width,
            height: cg.height
        )
    }

    private func webFormFixtureFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WebForm", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func browserFormSnapshot(
        snapshotId: Int,
        pid: Int32,
        team: String = "",
        email: String = "",
        justification: String = "",
        termsAccepted: Bool = false,
        status: String = "Draft"
    ) -> CUSnapshot {
        let window = CUWindowSummary(
            id: 1,
            title: "Access request form",
            focused: true,
            x: 0,
            y: 0,
            w: 1280,
            h: 900
        )
        let elements = [
            CUElement(
                id: "team",
                role: "textfield",
                label: "Team name",
                value: team,
                windowId: 1,
                x: 120,
                y: 120,
                w: 360,
                h: 32,
                actions: ["setValue"]
            ),
            CUElement(
                id: "email",
                role: "textfield",
                label: "Email",
                value: email,
                windowId: 1,
                x: 120,
                y: 180,
                w: 360,
                h: 32,
                actions: ["setValue"]
            ),
            CUElement(
                id: "justification",
                role: "textview",
                label: "Justification",
                value: justification,
                windowId: 1,
                x: 120,
                y: 240,
                w: 520,
                h: 120,
                actions: ["setValue"]
            ),
            CUElement(
                id: "terms",
                role: "checkbox",
                label: "Agree to terms",
                value: termsAccepted ? "checked" : "unchecked",
                windowId: 1,
                x: 120,
                y: 390,
                w: 220,
                h: 28,
                actions: ["press"]
            ),
            CUElement(
                id: "submit",
                role: "button",
                label: "Submit request",
                windowId: 1,
                x: 120,
                y: 450,
                w: 180,
                h: 36,
                actions: ["press"]
            ),
            CUElement(
                id: "status",
                role: "staticText",
                label: "Status",
                value: status,
                windowId: 1,
                x: 120,
                y: 520,
                w: 520,
                h: 24
            ),
        ]
        return CUSnapshot(
            snapshotId: snapshotId,
            pid: pid,
            app: "Safari",
            focusedWindow: "Access request form",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: elements,
            image: nil
        )
    }

    private func privacySafeActionTrace(_ actions: [CUElementAction]) -> [String] {
        actions.map { action in
            switch action {
            case .click(let id, _, _):
                return "click:\(id)"
            case .setValue(let id, let value):
                return "setValue:\(id):length=\(value.count)"
            case .typeText(let id, _, let text, let replace):
                return "typeText:\(id ?? "pid"):length=\(text.count):replace=\(replace)"
            case .pressKey(_, let key, let modifiers):
                return "pressKey:\((modifiers + [key]).joined(separator: "+"))"
            case .clearField(let id):
                return "clear:\(id)"
            }
        }
    }

    private func value(in snapshot: CUSnapshot, id: String) -> String? {
        snapshot.elements.first(where: { $0.id == id })?.value
    }

    /// An explicit `open` verb must launch the app FOREGROUND (`background: false`).
    /// A background launch sets `config.hides = true`; a hidden Cocoa app exposes no
    /// AX windows, so the readiness poll times out, the verify capture is empty, and
    /// the model reports the open as failed even though the app did launch. Regression
    /// guard for the 0.22.3 report: "launches the app but never brings the window to
    /// the foreground, then incorrectly reports the task as failed."
    @MainActor
    func testOpenVerbLaunchesForegroundSoTheWindowIsVisibleAndVerifiable() async {
        let pid: Int32 = 7420
        let window = CUWindowSummary(id: 1, title: "Untitled", focused: true, x: 0, y: 0, w: 600, h: 400)
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "TextEdit",
            focusedWindow: "Untitled",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [CUElement(id: "doc", role: "textarea", label: "Document", value: "", windowId: 1)],
            image: nil
        )
        let driver = MockMacDriver(
            availability: MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true),
            apps: [CUAppListing(pid: pid, bundleId: "com.apple.TextEdit", name: "TextEdit", active: false, hidden: false)],
            snapshots: [pid: [snapshot, snapshot]]
        )

        let result = await ComputerUseLoop.run(
            goal: "Open TextEdit.",
            modelId: "scripted-open",
            driver: driver,
            gate: ComputerUseGate(
                policy: AutonomyPolicy(globalPreset: .autonomous, allowlist: ["TextEdit"])
            ),
            feed: SubagentFeed(toolCallId: "evidence-open-fg", kindId: "computer_use", title: "Open TextEdit"),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30),
            vision: .none,
            sessionId: "evidence-open-fg",
            nextAction: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .open, app: "TextEdit"),
                AgentAction(verb: .done, reason: "TextEdit is open."),
            ])
        )

        XCTAssertTrue(result.outcome.isSuccess, "Open run should succeed; got \(result.outcome)")
        let openCalls = await driver.openCalls
        XCTAssertEqual(openCalls.count, 1, "The open verb must reach the driver exactly once.")
        XCTAssertEqual(openCalls.first?.identifier, "TextEdit")
        XCTAssertEqual(
            openCalls.first?.background,
            false,
            """
            The `open` verb launched the app in background mode. Background launching sets \
            config.hides = true, so the app never comes to the foreground and exposes no AX \
            windows — the model then reports a successful launch as a failure. An explicit \
            open must foreground the app.
            """)
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

private actor TranscriptRecorder {
    private var turns: [AgentStepInput.Turn] = []

    func record(_ transcript: [AgentStepInput.Turn]) {
        turns = transcript
    }

    func text() -> String {
        turns.map(\.text).joined(separator: "\n")
    }
}
