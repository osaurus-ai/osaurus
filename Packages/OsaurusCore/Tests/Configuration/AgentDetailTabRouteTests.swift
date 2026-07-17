//
//  AgentDetailTabRouteTests.swift
//  OsaurusCoreTests
//
//  Guardrails for agent detail deep-link routing after the database
//  consolidation: the five legacy per-surface tab raws (home / schema /
//  data / views / activity) must keep resolving into the Database
//  workspace with the right section, canonical tab raws must pass
//  through unchanged, and unknown values must be rejected rather than
//  silently landing somewhere.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentDetailTabRouteTests {

    @Test func legacyDatabaseRawsMapToWorkspaceSections() {
        let expectations: [(raw: String, section: AgentDatabaseSection)] = [
            ("home", .overview),
            ("schema", .tables),
            ("data", .tables),
            ("views", .savedViews),
            ("activity", .history),
        ]
        for (raw, section) in expectations {
            let route = AgentDetailTabRoute.resolve(raw)
            #expect(route?.tabRawValue == "database", "\(raw) should land on the Database tab")
            #expect(route?.databaseSection == section, "\(raw) should open the \(section) section")
        }
    }

    @Test func canonicalRawsPassThroughWithoutSection() {
        for raw in AgentDetailTabRoute.canonicalTabRawValues {
            let route = AgentDetailTabRoute.resolve(raw)
            #expect(route?.tabRawValue == raw)
            #expect(route?.databaseSection == nil, "\(raw) should not force a database section")
        }
    }

    @Test func unknownRawsAreRejected() {
        #expect(AgentDetailTabRoute.resolve("") == nil)
        #expect(AgentDetailTabRoute.resolve("nonsense") == nil)
        // Legacy names are consumed by the mapping above, so they must not
        // appear in the canonical set (that would shadow the section routing).
        for legacy in ["home", "schema", "data", "views", "activity"] {
            #expect(!AgentDetailTabRoute.canonicalTabRawValues.contains(legacy))
        }
    }

    @Test func databaseIsACanonicalTab() {
        // The consolidated workspace itself must be directly addressable so
        // new callers (agent cards, Configure shortcut) can deep-link to it.
        let route = AgentDetailTabRoute.resolve("database")
        #expect(route == AgentDetailTabRoute(tabRawValue: "database"))
    }

    @Test func abilitiesOverviewIsACanonicalTab() {
        // The Abilities overview (capability cards + startup-context
        // estimate) must be directly addressable for deep links.
        let route = AgentDetailTabRoute.resolve("abilities")
        #expect(route == AgentDetailTabRoute(tabRawValue: "abilities"))
        #expect(route?.databaseSection == nil)
    }
}
