//
//  WorkflowModelResolution.swift
//  osaurus
//
//  What it takes to run a template's preferred model on this Mac. A
//  preferred id that does not resolve here is either a local MLX repo that
//  can be downloaded, a cloud model whose provider can be connected, or
//  something Osaurus cannot get on its own. The setup wizard turns each
//  answer into one button next to the slot.
//

import Foundation

enum WorkflowModelResolution {

    enum Plan: Equatable {
        /// The template names no model.
        case none
        /// Resolves here to this id.
        case ready(String)
        /// A Hugging Face repo that is not installed.
        case download(repoId: String)
        /// A cloud model whose provider is not set up here. (A provider that
        /// is set up resolves its prefixed ids even while offline.)
        case connectProvider(ProviderPreset, model: String)
        /// Not installed, and nothing here says where it comes from.
        case unavailable(String)
    }

    /// The preset whose provider id prefix is `prefix` ("anthropic", "openai").
    static func preset(forPrefix prefix: String) -> ProviderPreset? {
        let wanted = prefix.lowercased()
        return ProviderPreset.allCases.first {
            $0 != .custom && RemoteProviderManager.pickerPrefix(for: $0.name) == wanted
        }
    }

    /// `knownRepos` are repo ids the model catalog lists (curated and
    /// fetched), used to place a bare id like "qwen3-coder-30b".
    static func plan(
        for preferred: String?, catalog: ConfigModelReference.Catalog, knownRepos: [String] = []
    ) -> Plan {
        guard let raw = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .none }
        if case .resolved(let id) = ConfigModelReference.resolve(raw, catalog: catalog) { return .ready(id) }
        if let known = knownRepos.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return .download(repoId: known)
        }
        if let slash = raw.firstIndex(of: "/") {
            let prefix = String(raw[..<slash])
            let rest = String(raw[raw.index(after: slash)...])
            if let preset = preset(forPrefix: prefix), !rest.isEmpty {
                return .connectProvider(preset, model: rest)
            }
            if !prefix.isEmpty, !rest.isEmpty, !rest.contains("/") { return .download(repoId: raw) }
            return .unavailable(raw)
        }
        let matches = knownRepos.filter { repo in
            guard let last = repo.split(separator: "/").last else { return false }
            return String(last).caseInsensitiveCompare(raw) == .orderedSame
        }
        if matches.count == 1 { return .download(repoId: matches[0]) }
        return .unavailable(raw)
    }

    @MainActor
    static func livePlan(for preferred: String?) -> Plan {
        let manager = ModelManager.shared
        let repos = (manager.suggestedModels + manager.availableModels).map(\.id)
        return plan(for: preferred, catalog: ConfigModelReference.liveCatalog(), knownRepos: repos)
    }
}
