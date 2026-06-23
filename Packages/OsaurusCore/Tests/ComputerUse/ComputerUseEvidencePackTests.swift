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
            feed: ComputerUseFeed(toolCallId: "evidence-ax", goal: "read the title field"),
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
}
