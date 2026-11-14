//
//  TemplateShareOptions.swift
//  osaurus
//
//  What export can add so the file sets itself up on the other Mac: the
//  models this Mac runs for slots the template leaves open, and how to
//  connect the MCP servers it names (`MCPServerHint`, names only, never
//  values). Both are suggestions the receiver can change in setup.
//

import Foundation

enum TemplateShareOptions {

    /// Slot -> the model this Mac binds, for slots with no preferred model.
    static func suggestableModels(_ template: Template, bindings: InstallBindings?) -> [String: String] {
        guard template.kind == .workflow, let bindings else { return [:] }
        var out: [String: String] = [:]
        for slot in template.requirements.models where slot.preferred == nil {
            if let model = bindings.models[slot.slot], !model.isEmpty { out[slot.slot] = model }
        }
        return out
    }

    /// `template` with `models` as the preferred model of each slot.
    static func withSuggestedModels(_ template: Template, _ models: [String: String]) -> Template {
        guard !models.isEmpty, var def = template.workflow else { return template }
        for (slot, model) in models {
            if let i = def.modelSlots.firstIndex(where: { $0.slot == slot }) {
                def.modelSlots[i].preferred = model
            } else if var derived = template.requirements.models.first(where: { $0.slot == slot }) {
                derived.preferred = model
                def.modelSlots.append(derived)
            }
        }
        var copy = template
        copy.payload = .workflow(def)
        return copy.sealed()
    }

    /// Hints for servers the template names that are configured here and
    /// have none yet. `servers` maps a template server name to the
    /// provider it runs on here.
    static func suggestableHints(
        _ template: Template, servers: [String: MCPProvider], directory: [MCPProviderTemplate]
    ) -> [MCPServerHint] {
        template.requirements.mcpServers.compactMap { name in
            guard template.serverHint(named: name) == nil, let provider = servers[name] else { return nil }
            let entry =
                provider.transport == .http
                ? directory.first { entry in
                    MCPServerResolution.endpointKey(entry.url).map { $0 == MCPServerResolution.endpointKey(provider.url) }
                        ?? false
                }
                : nil
            var hint = MCPServerHint.from(provider, as: name, directoryID: entry?.id)
            // A Directory entry already says how to connect; its canonical
            // URL replaces whatever this Mac's copy carries.
            if let entry { hint.url = entry.url }
            return TemplateExportSanitizer.sanitized(hint)
        }
    }

    static func withHints(_ template: Template, _ hints: [MCPServerHint]) -> Template {
        guard !hints.isEmpty else { return template }
        var copy = template
        copy.serverHints += hints
        return copy.sealed()
    }

    /// Template server name -> configured provider: through the install
    /// binding, else the same name.
    @MainActor
    static func liveServers(for template: Template, bindings: InstallBindings?) -> [String: MCPProvider] {
        let providers = MCPProviderManager.shared.configuration.providers
        var out: [String: MCPProvider] = [:]
        for name in template.requirements.mcpServers {
            let local = bindings?.mcpServers[name] ?? name
            if let provider = providers.first(where: { $0.name == local })
                ?? providers.first(where: { MCPServerResolution.sameName($0.name, name) })
            {
                out[name] = provider
            }
        }
        return out
    }
}
