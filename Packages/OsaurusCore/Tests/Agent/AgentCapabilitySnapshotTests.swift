//
//  AgentCapabilitySnapshotTests.swift
//  osaurusTests
//
//  Regression coverage for `AgentManager.diffKnownCapabilities`, the pure
//  transform that decides which newly-registered tools/skills get auto-grown
//  into a seeded agent's allowlist on `.toolsListChanged`.
//
//  The bug this guards: at startup plugins register incrementally, so the
//  notification fires repeatedly with a *partial* live set. An earlier
//  implementation replaced the known-names snapshot with each partial set,
//  which made the not-yet-loaded tools look "newly discovered" on the next
//  event and re-grew them into agents the user had explicitly disabled them
//  on — capability toggles silently reverted across restart.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
@MainActor
struct AgentCapabilitySnapshotTests {

    @Test("first observation seeds the snapshot without growing")
    func firstObservationSeedsWithoutGrowing() {
        let result = AgentManager.diffKnownCapabilities(
            known: nil,
            live: ["a", "b", "c"]
        )
        #expect(result.toGrow.isEmpty)
        #expect(result.merged == ["a", "b", "c"])
    }

    @Test("a genuinely new capability is grown and added to the snapshot")
    func genuinelyNewCapabilityGrows() {
        let result = AgentManager.diffKnownCapabilities(
            known: ["a", "b"],
            live: ["a", "b", "c"]
        )
        #expect(result.toGrow == ["c"])
        #expect(result.merged == ["a", "b", "c"])
    }

    @Test("a partial live set never shrinks the snapshot")
    func partialLiveSetKeepsSnapshot() {
        // Restart: full set was known, but only one plugin has loaded so far.
        let result = AgentManager.diffKnownCapabilities(
            known: ["a", "b", "c"],
            live: ["a"]
        )
        #expect(result.toGrow.isEmpty)
        // b and c must survive even though they are absent from `live`.
        #expect(result.merged == ["a", "b", "c"])
    }

    @Test("incremental startup never resurrects a disabled capability")
    func incrementalStartupDoesNotResurrectDisabled() {
        // Full catalog seen in a prior session.
        let fullCatalog: Set<String> = ["browser_a", "browser_b", "calendar_a", "time_a"]
        var snapshot: Set<String>? = AgentManager.diffKnownCapabilities(
            known: nil,
            live: fullCatalog
        ).merged

        // User disabled the browser group; that only changes the agent
        // allowlist, not the known-names snapshot, so the snapshot still
        // holds every name.

        // Restart: plugins register one at a time. Each event carries only the
        // tools that have loaded so far. None of these should ever be flagged
        // for growth, because every name is already known.
        let startupSequence: [Set<String>] = [
            ["time_a"],
            ["time_a", "calendar_a"],
            ["time_a", "calendar_a", "browser_a"],
            fullCatalog,
        ]
        for live in startupSequence {
            let result = AgentManager.diffKnownCapabilities(known: snapshot, live: live)
            #expect(result.toGrow.isEmpty, "partial live \(live.sorted()) wrongly grew \(result.toGrow.sorted())")
            snapshot = result.merged
        }

        // Snapshot still contains the whole catalog after the noisy startup.
        #expect(snapshot == fullCatalog)
    }

    @Test("a new plugin installed mid-session still grows")
    func newPluginMidSessionGrows() {
        let snapshot: Set<String> = ["browser_a", "calendar_a"]
        let result = AgentManager.diffKnownCapabilities(
            known: snapshot,
            live: ["browser_a", "calendar_a", "newplugin_a", "newplugin_b"]
        )
        #expect(result.toGrow == ["newplugin_a", "newplugin_b"])
        #expect(result.merged == ["browser_a", "calendar_a", "newplugin_a", "newplugin_b"])
    }
}
