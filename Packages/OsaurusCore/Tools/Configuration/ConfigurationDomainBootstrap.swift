//
//  ConfigurationDomainBootstrap.swift
//  osaurus
//
//  Launch-time entry point that registers every shipped
//  `ConfigurationDomain`. Called once from
//  `AppDelegate.applicationDidFinishLaunching`.
//
//  Since the declarative-config consolidation there is exactly ONE
//  configure write surface: `osaurus_config` (export / plan / apply a
//  YAML document). The nine legacy per-domain write tools
//  (osaurus_settings, osaurus_agent, osaurus_mcp, osaurus_model,
//  osaurus_plugin, osaurus_provider, osaurus_search, osaurus_schedule,
//  osaurus_watcher) were removed in its favor.
//

import Foundation

@MainActor
enum ConfigurationDomainBootstrap {
    private static var didBootstrap = false

    /// Idempotent — a second call is a no-op. The registry itself
    /// also dedupes by `domain.id`; this latch just short-circuits
    /// the array walk.
    static func registerBuiltIns() {
        guard !didBootstrap else { return }
        didBootstrap = true

        ConfigurationDomainRegistry.shared.register(ConfigDeclarativeDomain.domain)
    }

    /// Test-only: reset the latch so a fresh `registerBuiltIns()`
    /// call works after `registry._resetForTests()`.
    static func _resetForTests() {
        didBootstrap = false
    }
}
