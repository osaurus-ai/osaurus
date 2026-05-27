//
//  ProviderCredentialPromptService.swift
//  osaurus
//
//  Modal credential collection for remote providers. Modeled after
//  `ToolPermissionPromptService` — owns its own NSPanel, runs a SwiftUI
//  view inside, and resolves a `CheckedContinuation` when the user is
//  done. The configure-agent tools call this and suspend until the
//  user pastes an API key (and optionally tests it inline) or completes
//  an OAuth flow. The secret never enters LLM context: it travels back
//  through `ProviderCredentialResult` and is written to Keychain by the
//  tool implementation.
//
//  Concurrency: at most one prompt is active at a time. Subsequent
//  callers serialize through `pendingTask`.
//

import AppKit
import Foundation
import SwiftUI

/// Outcome of a single credential prompt. The non-cancel variants
/// carry the entered secret to the caller — they're never logged or
/// attributed to the chat turn.
public enum ProviderCredentialResult: Sendable {
    /// User pasted an API key. `headers` is non-nil only when the
    /// provider supports custom secret headers (today: legacy
    /// OpenAI-compatible servers).
    case apiKey(key: String, headers: [String: String]? = nil)
    /// User completed an OAuth flow and we now hold their tokens.
    case oauthTokens(RemoteProviderOAuthTokens)
    /// User dismissed the sheet or cancelled the OAuth callback.
    case cancelled
}

/// Mode the prompt is opened in. Drives the sheet title and whether
/// the "Test connection" button uses the existing provider's persisted
/// fields (rotate) or the in-flight new draft (addNew).
public enum ProviderCredentialPromptMode: Sendable, Equatable {
    case addNew
    case rotate(existingId: UUID)
}

/// Inputs the sheet needs to render and the service uses to drive
/// the inline test-connection call.
public struct ProviderCredentialRequest: Sendable {
    public let providerType: RemoteProviderType
    public let providerName: String
    public let mode: ProviderCredentialPromptMode
    public let instructions: ProviderCredentialInstructions

    public init(
        providerType: RemoteProviderType,
        providerName: String,
        mode: ProviderCredentialPromptMode
    ) {
        self.providerType = providerType
        self.providerName = providerName
        self.mode = mode
        self.instructions = ProviderCredentialInstructionsCatalog.entry(for: providerType)
    }
}

@MainActor
public enum ProviderCredentialPromptService {
    private static var window: NSPanel?
    private static var closeObserver: NSObjectProtocol?
    private static var pendingTask: Task<Void, Never>?

    /// Hook used by tests to short-circuit the sheet. When set,
    /// `requestCredentials(_:)` immediately resolves to whatever the
    /// closure returns instead of mounting a window. Production code
    /// must leave this `nil`.
    public static var bypassUI: (@MainActor (ProviderCredentialRequest) -> ProviderCredentialResult)?

    /// Open the credential prompt and suspend until the user pastes a
    /// key (and optionally tests it), completes an OAuth flow, or
    /// dismisses the sheet. The returned value is what the caller
    /// should hand to `RemoteProviderManager.addProvider(_:apiKey:oauthTokens:)`
    /// / `updateProvider(_:apiKey:oauthTokens:)`.
    public static func requestCredentials(
        _ request: ProviderCredentialRequest
    ) async -> ProviderCredentialResult {
        // Serialize: chain behind any pending sheet so two simultaneous
        // tool calls don't open two windows.
        let previous = pendingTask
        let serializer = Task<Void, Never> { await previous?.value }
        pendingTask = serializer
        await serializer.value

        if let bypass = bypassUI {
            return bypass(request)
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<ProviderCredentialResult, Never>) in
            present(request: request, continuation: cont)
        }
    }

    // MARK: - Presentation

    private static func present(
        request: ProviderCredentialRequest,
        continuation: CheckedContinuation<ProviderCredentialResult, Never>
    ) {
        var hasResumed = false

        let resolve: (ProviderCredentialResult) -> Void = { result in
            guard !hasResumed else { return }
            hasResumed = true
            dismiss()
            continuation.resume(returning: result)
        }

        let themeManager = ThemeManager.shared
        let view = ProviderCredentialPromptSheet(
            request: request,
            onComplete: resolve
        )
        .environment(\.theme, themeManager.currentTheme)

        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.fullSizeContentView, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .alertPanel
        panel.contentViewController = hosting

        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(
            width: max(fitting.width, 520),
            height: max(fitting.height, 380)
        )

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let x = visible.origin.x + (visible.width - size.width) / 2
            let y = visible.origin.y + (visible.height - size.height) / 2
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        } else {
            panel.setContentSize(size)
            panel.center()
        }

        window = panel

        // Safety net: if the panel is closed externally, treat as cancel.
        nonisolated(unsafe) let onClose = resolve
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            onClose(.cancelled)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private static func dismiss() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window?.orderOut(nil)
        window = nil
    }
}
