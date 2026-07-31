// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Tool permission prompt presentation")
struct ToolPermissionPromptServiceTests {
    @Test("run-scoped approval expires outside the task-local lease")
    func runScopedApprovalExpires() {
        let first = ToolPermissionRunScope()
        ChatExecutionContext.$toolPermissionRunScope.withValue(first) {
            #expect(ChatExecutionContext.toolPermissionRunScope?.allows("shell_run") == false)
            ChatExecutionContext.toolPermissionRunScope?.allow("shell_run")
            #expect(ChatExecutionContext.toolPermissionRunScope?.allows("shell_run") == true)
        }
        #expect(ChatExecutionContext.toolPermissionRunScope == nil)
        #expect(ToolPermissionRunScope().allows("shell_run") == false)
    }

    @Test("a task cancelled before approval is denial-shaped")
    @MainActor
    func cancelledApprovalDoesNotOpenOrGrantALease() async {
        let task = Task { @MainActor in
            await ToolPermissionPromptService.requestApprovalOutcome(
                toolName: "shell_run",
                description: "Run a command",
                argumentsJSON: #"{"command":"true"}"#
            )
        }
        task.cancel()
        #expect(await task.value == .denied)
        #expect(ChatExecutionContext.toolPermissionRunScope == nil)
    }

    @Test("launching app window wins over mouse and fallback displays")
    func launchingWindowScreenHasPriority() {
        #expect(
            ToolPermissionPromptService.preferredPresentationCandidate(
                keyWindow: "key",
                mainWindow: "main",
                mouse: "mouse",
                fallback: "fallback"
            ) == "key"
        )
        #expect(
            ToolPermissionPromptService.preferredPresentationCandidate(
                keyWindow: Optional<String>.none,
                mainWindow: "main",
                mouse: "mouse",
                fallback: "fallback"
            ) == "main"
        )
        #expect(
            ToolPermissionPromptService.preferredPresentationCandidate(
                keyWindow: Optional<String>.none,
                mainWindow: Optional<String>.none,
                mouse: "mouse",
                fallback: "fallback"
            ) == "mouse"
        )
    }

    @Test("Return and Escape require the visible focused prompt in the active app")
    func keyboardShortcutRequiresFocusedPrompt() {
        #expect(
            ToolPermissionPromptService.shouldAcceptKeyboardShortcut(
                isVisible: true,
                isKeyWindow: true,
                isAppActive: true
            )
        )

        for state in [
            (false, true, true),
            (true, false, true),
            (true, true, false),
            (false, false, false),
        ] {
            #expect(
                !ToolPermissionPromptService.shouldAcceptKeyboardShortcut(
                    isVisible: state.0,
                    isKeyWindow: state.1,
                    isAppActive: state.2
                )
            )
        }
    }

    @Test("panel never sizes past the visible screen area")
    func windowSizeClampsToVisibleFrame() {
        let visible = NSSize(width: 1440, height: 875)

        let oversized = ToolPermissionPromptService.clampedWindowSize(
            NSSize(width: 744, height: 2114),
            to: visible
        )
        #expect(oversized == NSSize(width: 744, height: 875))

        let fitting = ToolPermissionPromptService.clampedWindowSize(
            NSSize(width: 480, height: 620),
            to: visible
        )
        #expect(fitting == NSSize(width: 480, height: 620))
    }

    @Test("production prompt has one app-local keyboard monitor")
    func promptDoesNotListenToOtherApps() throws {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(
            "Services/ToolPermissionPromptService.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("addGlobalMonitorForEvents"))
        #expect(source.contains("styleMask: [.titled, .fullSizeContentView]"))
        #expect(source.contains("isKeyWindow: permissionWindow?.isKeyWindow == true"))
        #expect(source.contains("keyWindow: NSApp.keyWindow?.screen"))
        #expect(source.contains("pendingApprovalPrompt"))
        #expect(source.contains("cancelApprovalPrompt(id: requestID)"))
    }
}
