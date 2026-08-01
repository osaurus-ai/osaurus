//
//  EvalHostBootstrap.swift
//  osaurus
//
//  Public, off-process bootstrap helpers for the OsaurusEvals package and
//  future scoreboards. Brings the eval CLI's view of plugins + search
//  indices in line with the host app so `capability_search` /
//  `capability_claims` domains see the same catalog the chat path does.
//

import Foundation

@MainActor
public enum EvalHostBootstrap {

    /// Plugin ids currently registered with the host. Exposed for the
    /// OsaurusEvals runner so it can `skip + warn` cases whose
    /// `requirePlugins` aren't installed locally instead of failing
    /// them. Includes native dylib plugins (osaurus.browser, etc.) —
    /// kept narrow on purpose; if future eval cases need MCP/sandbox
    /// fixture introspection too, extend this surface explicitly
    /// rather than exposing the full `PluginManager`.
    ///
    /// Returns an empty set if `loadInstalledPlugins()` hasn't been
    /// called yet — `PluginManager.plugins` only lists plugins LOADED
    /// in this process (via `dlopen`), not just installed on disk.
    public static func installedPluginIds() -> Set<String> {
        var ids: Set<String> = []
        for loaded in PluginManager.shared.plugins {
            ids.insert(loaded.plugin.id)
        }
        return ids
    }

    /// Names of the agent-enableable dynamic tools currently in the
    /// registry (loaded MCP, plugin, and sandbox-plugin tools; authoritative
    /// built-ins are excluded). Exposed so the
    /// OsaurusEvals `capability_claims` runner can seed an isolated eval
    /// agent's allowlist authoritatively — `ToolRegistry` itself stays
    /// internal to OsaurusCore. Empty until `loadInstalledPlugins()` (or
    /// the index bootstrap) has synced the registry.
    public static func dynamicToolNames() -> [String] {
        ToolRegistry.shared.listDynamicTools().map(\.name)
    }

    /// Stable eval-only dynamic tool used to prove the positive
    /// `capabilities_load` path without pretending an authoritative built-in
    /// is loadable. The AgentLoop runner registers it only around the one
    /// fixture that requests it and removes it before the next case.
    nonisolated public static let dynamicLoadProbeToolName = "eval_dynamic_load_probe"

    public static func registerDynamicLoadProbe() {
        let probe = EvalDynamicLoadProbeTool()
        ToolRegistry.shared.registerPluginTool(probe)
        ToolRegistry.shared.setEnabled(true, for: probe.name)
    }

    public static func unregisterDynamicLoadProbe() {
        ToolRegistry.shared.unregister(names: [dynamicLoadProbeToolName])
    }

    /// True when at least one curated AppleScript bundle is installed and
    /// ready — the gate the `applescript` / `mac_query` tools use before
    /// appearing in the composed schema.
    public static var hasReadyAppleScriptModel: Bool {
        ModelPickerItemCache.shared.hasReadyAppleScriptModel
    }

    /// Boot every subsystem the chat path's capability search depends on
    /// so an out-of-process eval CLI sees the same indices the host app
    /// does. Mirrors the relevant slice of
    /// `AppDelegate.applicationDidFinishLaunching`. Idempotent.
    ///
    /// Subsystem coverage:
    /// - **plugins** — dlopen every installed plugin into
    ///   `PluginManager` / `ToolRegistry` / `SkillManager` so plugin
    ///   tools become visible to `listDynamicTools()` and
    ///   `installedPluginIds()`.
    /// - **tools index** — open `ToolDatabase`, init
    ///   `ToolSearchService`, sync from registry. Without these,
    ///   `capabilities_discover` cannot surface installed tools.
    /// - **methods + skills indices** — open `MethodDatabase`, init
    ///   `MethodSearchService`, force `SkillManager.refresh()` +
    ///   `SkillSearchService` init/rebuild. Without these, every
    ///   method/skill recall fixture would silently report 0 raw
    ///   hits, making "infrastructure not booted" indistinguishable
    ///   from "real recall miss". The explicit `refresh()` await
    ///   replaces relying on `SkillManager`'s eager init Task —
    ///   out-of-process callers can start querying before that Task
    ///   ever gets scheduled.
    public static func loadInstalledPlugins() async {
        await PluginManager.shared.loadAll()

        try? ToolDatabase.shared.open()
        await ToolSearchService.shared.initialize()
        await ToolIndexService.shared.syncFromRegistry()

        try? MethodDatabase.shared.open()
        await MethodSearchService.shared.initialize()
        await SkillManager.shared.refresh()
        await SkillSearchService.shared.initialize()
        await SkillSearchService.shared.rebuildIndex()
    }
}

private struct EvalDynamicLoadProbeTool: OsaurusTool {
    let name = EvalHostBootstrap.dynamicLoadProbeToolName
    let description =
        "Return a deterministic acknowledgement that a deferred dynamic tool loaded and executed."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON _: String) async throws -> String {
        ToolEnvelope.success(tool: name, text: "dynamic load probe executed")
    }
}
