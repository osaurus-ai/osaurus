//
//  CredentialReveal.swift
//  osaurus
//
//  "Show" and "Copy" on the Keys page. Reading a value for a person to see
//  asks for Touch ID or the login password first; runtime reads (MCP,
//  sandbox, plugins) never go through here and never prompt.
//

import AppKit
import Foundation
import LocalAuthentication

@MainActor
enum CredentialReveal {
    /// How long one successful prompt covers further Show / Copy clicks.
    static let authenticationWindow: TimeInterval = 60
    /// A shown value is masked again after this long.
    static let remaskAfter: Duration = .seconds(10)
    /// A copied value is cleared from the clipboard after this long, unless
    /// something else was copied in the meantime.
    static let clipboardClearAfter: Duration = .seconds(60)

    private static var authenticatedAt: Date?
    /// Test seam for the Touch ID / password prompt.
    static var makeContext: () -> LAContext = { LAContext() }

    static func authenticate(reason: String) async -> Bool {
        if let authenticatedAt, Date().timeIntervalSince(authenticatedAt) < authenticationWindow { return true }
        let context = makeContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { authenticatedAt = Date() }
            return ok
        } catch {
            return false
        }
    }

    /// Like `authenticate`, for account actions that must stay possible on a
    /// Mac with no login password or Touch ID: there it passes.
    static func confirmOwner(reason: String) async -> Bool {
        var error: NSError?
        guard makeContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.domain == LAErrorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
        }
        return await authenticate(reason: reason)
    }

    /// Authenticates, then reads the value off the main actor.
    static func read(reason: String, _ load: @escaping @Sendable () -> String?) async -> String? {
        guard await authenticate(reason: reason) else { return nil }
        return await Task.detached(priority: .userInitiated) { load() }.value
    }

    /// Copies without offering the value to other devices (Universal Clipboard).
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(value, forType: .string)
        let changeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: clipboardClearAfter)
            if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
        }
    }

    static func _resetForTesting() {
        authenticatedAt = nil
        makeContext = { LAContext() }
    }
}
