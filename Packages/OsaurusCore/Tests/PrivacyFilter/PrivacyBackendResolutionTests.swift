//
//  PrivacyBackendResolutionTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pin-down for `resolvedAIBackend`: AI detection must run with whatever
//  privacy model is actually installed. The user's default only wins when
//  its bundle is on disk; a lone installed model is always used; nothing
//  installed resolves to nil so the pipeline can fail closed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Privacy AI backend resolution")
struct PrivacyBackendResolutionTests {

    private func config(default backend: PrivacyAIBackend) -> PrivacyFilterConfiguration {
        PrivacyFilterConfiguration(aiDetectionBackend: backend)
    }

    @Test func onlyRampartInstalled_usesRampartEvenWhenDefaultIsOpenAI() {
        let resolved = config(default: .openai).resolvedAIBackend { $0 == .rampart }
        #expect(resolved == .rampart)
    }

    @Test func onlyOpenAIInstalled_usesOpenAIEvenWhenDefaultIsRampart() {
        let resolved = config(default: .rampart).resolvedAIBackend { $0 == .openai }
        #expect(resolved == .openai)
    }

    @Test func bothInstalled_honorsUserDefault() {
        #expect(config(default: .rampart).resolvedAIBackend { _ in true } == .rampart)
        #expect(config(default: .openai).resolvedAIBackend { _ in true } == .openai)
    }

    @Test func nothingInstalled_resolvesToNil() {
        #expect(config(default: .openai).resolvedAIBackend { _ in false } == nil)
        #expect(config(default: .rampart).resolvedAIBackend { _ in false } == nil)
    }
}
