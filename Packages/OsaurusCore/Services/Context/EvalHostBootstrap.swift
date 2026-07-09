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
    /// registry (built-ins + loaded plugin tools, minus always-loaded
    /// internals like `capabilities_discover`). Exposed so the
    /// OsaurusEvals `capability_claims` runner can seed an isolated eval
    /// agent's allowlist authoritatively — `ToolRegistry` itself stays
    /// internal to OsaurusCore. Empty until `loadInstalledPlugins()` (or
    /// the index bootstrap) has synced the registry.
    public static func dynamicToolNames() -> [String] {
        ToolRegistry.shared.listDynamicTools().map(\.name)
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
