//
//  CLIAccessPrompt.swift
//  osaurus
//
//  The Allow / Don't Allow alert raised when the `osaurus` CLI asks for
//  access (`POST /cli/access`). It closes by itself when the request times
//  out or the CLI disconnects (Ctrl-C), so a stale prompt never approves a
//  command that is gone.
//

import AppKit
import Foundation

enum CLIAccessPromptOutcome: Equatable, Sendable {
    case allowed
    case denied
    /// Timed out or the CLI went away before anyone answered.
    case closed
}

/// Injectable so the HTTP tests can answer without an alert.
struct CLIAccessPrompter: Sendable {
    let ask:
        @Sendable (_ label: String, _ timeout: TimeInterval, _ isCancelled: @escaping @Sendable () -> Bool) async ->
            CLIAccessPromptOutcome

    static let live = CLIAccessPrompter { label, timeout, isCancelled in
        await MainActor.run { CLIAccessPrompt.present(label: label, timeout: timeout, isCancelled: isCancelled) }
    }
}

@MainActor
enum CLIAccessPrompt {
    static func present(
        label: String,
        timeout: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> CLIAccessPromptOutcome {
        let command = label.isEmpty ? "osaurus" : label
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Allow the osaurus command-line tool?")
        alert.informativeText = L(
            "A Terminal command on this Mac (\(command)) is asking to use Osaurus. If you allow it, osaurus commands can reach this server while Expose to Network or Require Access Key for Local Admin Routes is on, start your workflows, and answer tool approvals for agent runs they start. You can revoke this in Settings → Server → Command-Line Tool Access."
        )
        alert.addButton(withTitle: L("Allow"))
        alert.addButton(withTitle: L("Don't Allow"))

        let deadline = Date().addingTimeInterval(timeout)
        let closedFlag = ClosedFlag()
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            guard isCancelled() || Date() >= deadline else { return }
            closedFlag.closed = true
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }

        NSApp.activate(ignoringOtherApps: true)
        // `runModal` blocks the main run loop until answered; pause the hang
        // watchdog so the wait is not reported as an app hang.
        let response = CrashReportingService.shared.withAppHangTrackingPaused { alert.runModal() }
        if closedFlag.closed || response == .abort { return .closed }
        return response == .alertFirstButtonReturn ? .allowed : .denied
    }

    private final class ClosedFlag: @unchecked Sendable {
        var closed = false
    }
}
