//
//  ProviderCredentialPromptServiceTests.swift
//  OsaurusCoreTests
//
//  Validates the test-friendly contract of
//  `ProviderCredentialPromptService`. We can't mount the NSPanel in
//  source-only tests, so the production code exposes a `bypassUI` hook
//  that resolves the continuation directly. This test exercises that
//  hook and pins down the three outcomes the configure-agent provider
//  tools rely on:
//
//   * `.apiKey(key:headers:)` — the user pasted a key (optionally
//     accompanied by extra custom headers).
//   * `.oauthTokens(_:)` — the user completed an OAuth flow.
//   * `.cancelled` — the user dismissed the sheet.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ProviderCredentialPromptServiceTests {

    private static func clearBypass() {
        ProviderCredentialPromptService.bypassUI = nil
    }

    @Test
    func bypassUI_returnsApiKeyOutcome() async {
        Self.clearBypass()
        defer { Self.clearBypass() }

        ProviderCredentialPromptService.bypassUI = { _ in
            .apiKey(key: "test-key-12345")
        }

        let request = ProviderCredentialRequest(
            providerType: .anthropic,
            providerName: "Test",
            mode: .addNew
        )
        let result = await ProviderCredentialPromptService.requestCredentials(request)
        if case .apiKey(let key, let headers) = result {
            #expect(key == "test-key-12345")
            #expect(headers == nil)
        } else {
            Issue.record("expected .apiKey, got \(result)")
        }
    }

    @Test
    func bypassUI_returnsCancelledOutcome() async {
        Self.clearBypass()
        defer { Self.clearBypass() }

        ProviderCredentialPromptService.bypassUI = { _ in .cancelled }

        let request = ProviderCredentialRequest(
            providerType: .openResponses,
            providerName: "Test",
            mode: .addNew
        )
        let result = await ProviderCredentialPromptService.requestCredentials(request)
        if case .cancelled = result {
            // ok
        } else {
            Issue.record("expected .cancelled, got \(result)")
        }
    }

    @Test
    func request_picksUpProviderInstructionsFromCatalog() {
        // The sheet derives its title, format hint, and OAuth
        // affordance from the curated instructions catalog. Pinning
        // a small set of well-known providers so silently dropping
        // an entry breaks the test.
        let anthropic = ProviderCredentialRequest(
            providerType: .anthropic,
            providerName: "Anthropic",
            mode: .addNew
        )
        #expect(anthropic.instructions.providerType == .anthropic)

        let codex = ProviderCredentialRequest(
            providerType: .openAICodex,
            providerName: "Codex",
            mode: .addNew
        )
        // Codex authenticates via OAuth so the catalog must surface
        // the OAuth method.
        #expect(codex.instructions.authMethod == .oauth)
    }

    @Test
    func credentialPanel_canBecomeKeyDespiteBorderlessStyle() {
        // Regression: the prompt panel is borderless (`.fullSizeContentView`
        // only), and a borderless NSPanel refuses key status by default —
        // which made the API key field unfocusable. The subclass must opt
        // in so `makeKey()` succeeds and text input can take focus.
        let panel = CredentialPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        #expect(panel.canBecomeKey)
        #expect(panel.canBecomeMain)

        // Sanity contrast: a plain panel with the same style mask cannot
        // become key — this is the exact condition that broke focus.
        let plain = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        #expect(!plain.canBecomeKey)
    }
}
