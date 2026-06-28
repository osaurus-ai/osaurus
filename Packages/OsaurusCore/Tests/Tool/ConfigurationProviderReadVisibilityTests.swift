//
//  ConfigurationProviderReadVisibilityTests.swift
//  OsaurusCoreTests
//
//  The configure READ tools (`osaurus_status` / `osaurus_list` /
//  `osaurus_describe`) hide the eval harness's ephemeral run/judge provider
//  when `OSAURUS_EVALS_HIDE_EPHEMERAL_PROVIDERS` is set, so a `default_agent`
//  honesty case ("which providers are connected?") sees the genuine
//  user-configured state instead of the provider the harness connected to
//  drive a remote model. These tests pin the pure filter logic so the
//  isolation can't silently regress (and so production, which never sets the
//  flag, keeps every provider visible).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ConfigurationProviderReadVisibilityTests {

    @Test
    func filtered_passesEverythingWhenNotHiding() {
        let persisted = RemoteProvider(name: "Persisted", host: "api.example.com")
        let ephemeral = RemoteProvider(name: "Ephemeral", host: "api.x.ai")
        let result = ConfigurationProviderReadVisibility.filtered(
            [persisted, ephemeral],
            hidesEphemeral: false,
            isEphemeral: { $0 == ephemeral.id }
        )
        // Production path: flag off → discovered/ephemeral providers stay visible.
        #expect(result.map { $0.id } == [persisted.id, ephemeral.id])
    }

    @Test
    func filtered_dropsEphemeralWhenHiding() {
        let persisted = RemoteProvider(name: "Persisted", host: "api.example.com")
        let ephemeral = RemoteProvider(name: "Ephemeral", host: "api.x.ai")
        let result = ConfigurationProviderReadVisibility.filtered(
            [persisted, ephemeral],
            hidesEphemeral: true,
            isEphemeral: { $0 == ephemeral.id }
        )
        // Eval path: flag on → the harness's ephemeral provider is hidden.
        #expect(result.map { $0.id } == [persisted.id])
    }

    @Test
    func filtered_keepsAllWhenNoneEphemeral() {
        let one = RemoteProvider(name: "One", host: "api.one.com")
        let two = RemoteProvider(name: "Two", host: "api.two.com")
        let result = ConfigurationProviderReadVisibility.filtered(
            [one, two],
            hidesEphemeral: true,
            isEphemeral: { _ in false }
        )
        // Hiding is enabled but nothing is ephemeral → genuine user state passes.
        #expect(result.count == 2)
    }
}
