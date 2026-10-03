//
//  ConfigApplierWorkingFolderGapTests.swift
//  OsaurusCoreTests
//
//  When the orchestrator applies an agent whose `working_folder` this Mac
//  cannot reach, the apply reports `needs_user_action` — but the gap also
//  has to survive ON the agent record, because that record is the only
//  thing `AgentSetupChecker` can see.
//
//  A live run showed what happens when it does not. The applier reported
//  the folder as needing action but wrote nothing to the agent, so the
//  agent looked perfectly configured: no Needs Setup badge, no folder step
//  in the wizard, and `SpawnAgentTool.setupRefusal` found a clean report,
//  cleared the marker, and let the spawn run into a sandbox with no such
//  folder. The refusal that was supposed to stop it never fired.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ConfigApplierWorkingFolderGapTests {

    /// A path that cannot exist, so no bookmark can ever be made for it.
    private static let unreachable = "/osaurus-tests/definitely/not/here"

    private func entry(folder: String) -> AgentEntry {
        var entry = AgentEntry(name: "Probe")
        entry.workingFolder = .value(folder)
        return entry
    }

    @Test
    func unreachableFolder_isRecordedAsAPathWithNoBookmark() {
        let (agent, outcome) = ConfigApplier.draftAgent(from: entry(folder: Self.unreachable))
        // The apply still tells the orchestrator a step remains.
        #expect(outcome.needsUserAction)
        // And the agent carries the request, so the gap is visible later.
        #expect(agent.workingFolderPath == Self.unreachable)
        #expect(agent.workingFolderBookmark == nil)
    }

    /// The whole point of recording it: the readiness check must now block,
    /// which is what keeps `setupRefusal` from clearing the marker.
    @Test
    func recordedGap_blocksTheReadinessCheck() {
        let (agent, _) = ConfigApplier.draftAgent(from: entry(folder: Self.unreachable))
        let report = AgentSetupChecker.check(
            agent,
            environment: AgentSetupChecker.Environment(
                registeredToolNames: ["fetch", "time"],
                modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
                isPermissionGranted: { _ in true },
                bookmarkResolves: { _ in true },
                knowledgeCollectionExists: { _ in true })
        )
        #expect(!report.isClean)
        #expect(report.hasBlockers)
        let folder = report.blocking.first { $0.kind == .workingFolder }
        #expect(folder != nil)
        #expect(folder?.value == Self.unreachable)
    }

    @Test
    func tildeIsExpandedBeforeItIsRecorded() {
        // The orchestrator writes `~/Projects/...` verbatim; a stored tilde
        // would never match the folder the user later picks.
        let (agent, _) = ConfigApplier.draftAgent(from: entry(folder: "~/osaurus-tests/nope"))
        let path = agent.workingFolderPath ?? ""
        #expect(!path.hasPrefix("~"))
        #expect(path.hasSuffix("/osaurus-tests/nope"))
    }

    @Test
    func absentFolderKeyLeavesTheAgentAlone() {
        let (agent, outcome) = ConfigApplier.draftAgent(from: AgentEntry(name: "Probe"))
        #expect(agent.workingFolderPath == nil)
        #expect(!outcome.needsUserAction)
    }
}
