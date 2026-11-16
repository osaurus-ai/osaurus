//
//  AppleScriptAutomationConsent.swift
//  osaurus
//
//  Asks for Automation consent for every app a script targets BEFORE the
//  script runs. Left to the script's first Apple Event, the macOS "wants
//  access to control" dialog sits inside the executor's 45 s script budget,
//  so a person who takes longer to answer gets a timeout instead of a run.
//  A target that is already denied gets the Osaurus permission panel, the
//  same as a denied permission at the tool gate.
//

import AppKit
import Foundation

@MainActor
enum AppleScriptAutomationConsent {
    /// How long the macOS dialog may wait for an answer; the same bound as
    /// the gate's Automation probe.
    static let askTimeout: TimeInterval = SystemPermissionService.automationProbeTimeout

    /// The error message of a refusal this preflight produced after the
    /// person chose Not Now (or did not answer), so the loop does not tell
    /// the model to retry into the same panel.
    nonisolated static let declinedMessagePrefix = "Osaurus asked for Automation access to "

    struct Target: Equatable, Sendable {
        let appName: String
        let bundleIdentifier: String
    }

    /// Returns a `.permissionRequired` result when a target app stays
    /// denied, nil when the script may run. A target whose consent cannot
    /// be read (not installed, did not answer) is left to the script, which
    /// reports its own error.
    static func preflight(source: String, toolName: String) async -> AppleScriptExecutionResult? {
        if RuntimeEnvironment.isUnderTests { return nil }
        for target in targets(in: source).compactMap(resolve) {
            if await consent(target, ask: false) == .granted { continue }
            _ = await AppleScriptBridge.ensureRunning(bundleIdentifier: target.bundleIdentifier, appName: target.appName)
            switch await askBounded(target) {
            case .granted, .unknown: continue
            case .denied: break
            }
            let answer = await SystemPermissionPanelService.ask(
                .init(
                    permission: permission(for: target),
                    toolName: toolName,
                    requesterName: SystemPermissionGate.requesterName(),
                    reason: .turnedOff
                ),
                recheck: { _ in await consent(target, ask: false) == .granted }
            )
            if answer == .granted { continue }
            let why = answer == .timedOut ? "they did not answer" : "they chose Not Now"
            return AppleScriptExecutionResult(
                status: .permissionRequired,
                output: nil,
                errorNumber: AppleScriptExecutor.permissionDeniedErrorNumber,
                errorMessage:
                    "\(declinedMessagePrefix)\(target.appName) and \(why). It is off for Osaurus in System Settings → Privacy & Security → Automation."
            )
        }
        return nil
    }

    // MARK: - Targets

    enum Reference: Equatable, Sendable {
        case name(String)
        case bundleIdentifier(String)
    }

    /// Apps a script addresses: `tell application "X"` / `tell app "X"` in
    /// AppleScript, `Application("X")` in JavaScript, and `tell application
    /// id "bundle.id"`.
    nonisolated static func targets(in source: String) -> [Reference] {
        let patterns: [(String, (String) -> Reference)] = [
            (#"(?i)\btell\s+(?:application|app)\s+id\s+"([^"]+)""#, Reference.bundleIdentifier),
            (#"(?i)\btell\s+(?:application|app)\s+"([^"]+)""#, Reference.name),
            (#"\bApplication\(\s*["']([^"']+)["']\s*\)"#, Reference.name),
        ]
        var seen = Set<String>()
        var references: [Reference] = []
        let range = NSRange(source.startIndex..., in: source)
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: range) {
                guard let r = Range(match.range(at: 1), in: source) else { continue }
                let value = String(source[r]).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
                references.append(make(value))
            }
        }
        return references
    }

    /// Bundle id for a referenced app, from the running apps or the
    /// standard app folders. Osaurus itself needs no consent.
    static func resolve(_ reference: Reference) -> Target? {
        let own = Bundle.main.bundleIdentifier
        let name: String
        switch reference {
        case .bundleIdentifier(let id):
            return id == own ? nil : Target(appName: id, bundleIdentifier: id)
        case .name(let value):
            name = value
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }), let id = running.bundleIdentifier {
            return id == own ? nil : Target(appName: name, bundleIdentifier: id)
        }
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices", "/Applications/Utilities",
        ]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).app")
            if let id = Bundle(url: url)?.bundleIdentifier {
                return id == own ? nil : Target(appName: name, bundleIdentifier: id)
            }
        }
        return nil
    }

    /// The permission the panel names for a target: the app's own
    /// Automation entry where Osaurus has one, otherwise Automation.
    static func permission(for target: Target) -> SystemPermission {
        let specific: [SystemPermission] = [
            .automationMail, .automationMessages, .automationMusic, .notes, .maps, .automationCalendar,
        ]
        return specific.first {
            SystemPermissionService.automationProbeBundleIdentifier(for: $0) == target.bundleIdentifier
        } ?? .automation
    }

    // MARK: - Consent

    private static func consent(_ target: Target, ask: Bool) async -> PermissionProbeResult.Status {
        let id = target.bundleIdentifier
        return await Task.detached(priority: .userInitiated) {
            SystemPermissionService.automationConsent(bundleIdentifier: id, askUserIfNeeded: ask)
        }.value
    }

    /// The asking call blocks its thread until the person answers, so it
    /// runs detached and the wait gives up after `askTimeout`; a late answer
    /// still lands in TCC for the next script.
    private static func askBounded(_ target: Target) async -> PermissionProbeResult.Status {
        let id = target.bundleIdentifier
        let timeout = askTimeout
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(SystemPermissionService.automationConsent(bundleIdentifier: id, askUserIfNeeded: true))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                once.resume(.unknown)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PermissionProbeResult.Status, Never>?

        init(_ continuation: CheckedContinuation<PermissionProbeResult.Status, Never>) {
            self.continuation = continuation
        }

        func resume(_ status: PermissionProbeResult.Status) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: status)
        }
    }
}
