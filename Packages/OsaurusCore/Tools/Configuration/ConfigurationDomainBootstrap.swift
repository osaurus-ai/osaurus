//
//  ConfigurationDomainBootstrap.swift
//  osaurus
//
//  Launch-time entry point that registers every shipped
//  `ConfigurationDomain`. Called once from
//  `AppDelegate.applicationDidFinishLaunching`. Adding a new domain
//  is one new file under `Tools/Configuration/` plus one register
//  call here.
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

        let registry = ConfigurationDomainRegistry.shared
        registry.register(ProviderConfigurationDomain.domain)
        registry.register(ModelConfigurationDomain.domain)
        registry.register(MCPProviderConfigurationDomain.domain)
        registry.register(PluginConfigurationDomain.domain)
        registry.register(ScheduleConfigurationDomain.domain)
        registry.register(AgentConfigurationDomain.domain)
    }

    /// Test-only: reset the latch so a fresh `registerBuiltIns()`
    /// call works after `registry._resetForTests()`.
    static func _resetForTests() {
        didBootstrap = false
    }
}
