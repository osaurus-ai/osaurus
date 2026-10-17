//
//  AgentTemplateModelResolutionTests.swift
//  OsaurusCoreTests
//
//  A template written on one Mac names a model the next Mac may not have.
//  `preferred` falls back to the default model, `always` blocks, and an
//  installed model resolves to its canonical id. Pure: the catalog is
//  passed in.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentTemplateModelResolutionTests {

    private func template(model: String?, policy: TemplateRequirement.ModelPolicy?) -> AgentTemplate {
        var entry = AgentEntry(name: "T")
        if let model { entry.model = .value(model) }
        var requires: [TemplateRequirement] = []
        if let model, let policy {
            requires.append(TemplateRequirement(kind: .model, value: model, policy: policy))
        }
        return AgentTemplate(name: "T", agent: entry, requires: requires)
    }

    private let catalog = ConfigModelReference.Catalog(
        localModelIds: ["mlx-community/Qwen3-Coder-Next-4bit"],
        providers: [
            ConfigModelReference.ProviderModels(prefix: "anthropic", name: "Anthropic", models: ["sonnet-5"])
        ])

    @Test
    func installedLocalModel_isAvailableWithCanonicalCase() {
        let t = template(model: "MLX-COMMUNITY/qwen3-coder-next-4bit", policy: .preferred)
        #expect(t.modelResolution(catalog: catalog) == .available("mlx-community/Qwen3-Coder-Next-4bit"))
    }

    @Test
    func bareCloudId_resolvesToPrefixedForm() {
        let t = template(model: "sonnet-5", policy: .always)
        #expect(t.modelResolution(catalog: catalog) == .available("anthropic/sonnet-5"))
    }

    @Test
    func missingModel_preferredFallsBack_alwaysBlocks() {
        let preferred = template(model: "qwen3-coder-next-mlx", policy: .preferred)
        #expect(preferred.modelResolution(catalog: catalog) == .fallbackToDefault(requested: "qwen3-coder-next-mlx"))
        let always = template(model: "qwen3-coder-next-mlx", policy: .always)
        #expect(always.modelResolution(catalog: catalog) == .blocked(requested: "qwen3-coder-next-mlx"))
    }

    @Test
    func noRequirement_defaultsToPreferred() {
        let t = template(model: "nope", policy: nil)
        #expect(t.modelPolicy == .preferred)
        #expect(t.modelResolution(catalog: catalog) == .fallbackToDefault(requested: "nope"))
    }

    @Test
    func noModel_isAvailableNil() {
        let t = template(model: nil, policy: nil)
        #expect(t.modelResolution(catalog: catalog) == .available(nil))
    }
}
