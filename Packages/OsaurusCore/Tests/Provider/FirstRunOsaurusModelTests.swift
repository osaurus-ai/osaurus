//
//  FirstRunOsaurusModelTests.swift
//  OsaurusCoreTests
//
//  The first-run Osaurus Cloud model: the newest DeepSeek Flash in the
//  Router catalog, never older than V4.1, with its product name.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct FirstRunOsaurusModelTests {
    private func newest(_ ids: [String]) -> String? {
        RemoteProviderManager.newestFirstRunOsaurusModelId(in: ids)
    }

    @Test
    func theFixedSlugAlone_resolvesToItself() {
        #expect(newest(["osaurus/claude-opus-5-5", "osaurus/deepseek-v4-1-flash"]) == "osaurus/deepseek-v4-1-flash")
    }

    @Test
    func aNewerFlash_wins_byVersionNotOrder() {
        #expect(
            newest(["osaurus/deepseek-v4-2-flash", "osaurus/deepseek-v4-1-flash"]) == "osaurus/deepseek-v4-2-flash")
        #expect(
            newest(["osaurus/deepseek-v4-1-flash", "osaurus/deepseek-v4-10-flash", "osaurus/deepseek-v4-9-flash"])
                == "osaurus/deepseek-v4-10-flash")
        #expect(newest(["osaurus/deepseek-v4-2-flash", "osaurus/deepseek-v5-flash"]) == "osaurus/deepseek-v5-flash")
        #expect(newest(["osaurus/venice/DeepSeek-V4-2-Flash"]) == "osaurus/venice/DeepSeek-V4-2-Flash")
    }

    @Test
    func noFlash_orOnlyARetiredOne_resolvesToNothing() {
        #expect(newest(["osaurus/claude-opus-5-5", "osaurus/gpt-6-astra"]) == nil)
        #expect(newest(["osaurus/deepseek-v4-flash", "osaurus/deepseek-v4-0-flash"]) == nil)
        #expect(newest(["osaurus/deepseek-v4-2-pro", "osaurus/deepseek-v4-x-flash", "osaurus/deepseek-v-flash"]) == nil)
    }

    @Test
    func displayName_comesFromTheId() {
        #expect(RemoteProviderManager.firstRunOsaurusModelDisplayName("osaurus/deepseek-v4-1-flash") == "DeepSeek V4.1 Flash")
        #expect(RemoteProviderManager.firstRunOsaurusModelDisplayName("osaurus/deepseek-v4-2-flash") == "DeepSeek V4.2 Flash")
        #expect(RemoteProviderManager.firstRunOsaurusModelDisplayName("osaurus/deepseek-v5-flash") == "DeepSeek V5 Flash")
        #expect(RemoteProviderManager.firstRunOsaurusModelDisplayName("osaurus/gpt-6-astra") == nil)
    }

    @Test
    func theTemporaryCloudModel_isTheNewestFlash() {
        func router(_ id: String) -> ModelPickerItem {
            ModelPickerItem(
                id: id, displayName: id,
                source: .remote(providerName: "Osaurus", providerId: RemoteProviderManager.osaurusRouterProviderId),
                inputPriceMicroPerMTok: 1, outputPriceMicroPerMTok: 1, contextLength: 65_536, supportsToolCalling: true)
        }
        let items = [router("osaurus/deepseek-v4-1-flash"), router("osaurus/deepseek-v4-2-flash"), router("osaurus/x")]
        #expect(ChatSession.osaurusRouterValueCandidate(in: items)?.id == "osaurus/deepseek-v4-2-flash")
    }
}
