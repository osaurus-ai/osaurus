//
//  TemplateCascadePlanTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct TemplateCascadePlanTests {
    private static let alice = "0xa11ce00000000000000000000000000000000001"
    private static let bob = "0xb0b0000000000000000000000000000000000002"

    private func workflow(
        _ name: String, version: Int = 1, signedBy address: String? = nil, signature: String? = "0xsig"
    ) -> Template {
        var t = WF.template(WF.intake(), name: name)
        t.version = version
        if let address { t.author = TemplateAuthor(name: nil, address: address, signature: signature) }
        return t
    }

    private func agent(_ workflows: [Template]) -> Template {
        var a = AgentTemplate(name: "Desk", agent: AgentEntry(name: "Desk"))
        a.bundled = workflows
        return a
    }

    private func record(
        _ t: Template, version: Int, address: String = alice, takenDown: Bool = false, removed: Bool = false
    ) -> WorkflowRegistryRecord {
        var r = WorkflowRegistryRecord(
            templateID: t.id, registryID: "r-\(t.name)", slug: t.name, version: version, contentHash: "",
            url: URL(string: "https://web.test/w/x")!, rawURL: URL(string: "https://registry.test/x")!,
            deepLink: URL(string: "osaurus://templates-import?url=x")!, address: address, registry: "https://registry.test",
            sharedAt: Date(timeIntervalSince1970: 0))
        r.registryLatestVersion = version
        r.takenDown = takenDown
        r.removedByAdmin = removed
        return r
    }

    private func plan(
        _ workflows: [Template], visibility: WorkflowVisibility = .public, own: String? = alice,
        publishWorkflows: Bool = true, records: [WorkflowRegistryRecord] = [], builtIn: Set<UUID> = []
    ) -> TemplateCascadePlan {
        TemplateCascadePlan.make(
            template: agent(workflows), visibility: visibility, ownAddress: own, publishWorkflows: publishWorkflows,
            record: { id in records.first { $0.templateID == id } }, isBuiltIn: { builtIn.contains($0) })
    }

    @Test func yoursUnpublishedPublishes_andSomeoneElsesLinks() {
        let mine = workflow("Mine")
        let signedByMe = workflow("Signed by me", signedBy: Self.alice.uppercased())
        let theirs = workflow("Theirs", signedBy: Self.bob)
        let p = plan([mine, signedByMe, theirs])
        #expect(p.rows.map(\.state) == [.willPublish, .willPublish, .linkedToAuthor(address: Self.bob)])
        #expect(p.toPublish.map(\.id) == [mine.id, signedByMe.id])
        #expect(p.visibility == .public)
    }

    @Test func liveAtThatVersionIsAlreadyPublished_aNewerBundledVersionPublishes() {
        let same = workflow("Same", version: 2)
        let newer = workflow("Newer", version: 3)
        let live = record(same, version: 2)
        let older = record(newer, version: 2)
        let p = plan([same, newer], records: [live, older])
        #expect(p.rows.map(\.state) == [.alreadyPublished(live), .willPublish])
        #expect(p.rows[1].record == older, "an update keeps the record it updates")
    }

    @Test func visibilityIsInherited_aPasswordAgentKeepsThemBundled() {
        let mine = workflow("Mine")
        #expect(plan([mine], visibility: .hidden).visibility == .hidden)
        let locked = plan([mine], visibility: .password)
        #expect(locked.visibility == nil)
        #expect(locked.rows.map(\.state) == [.bundledOnly(.passwordProtected)])
        #expect(locked.toPublish.isEmpty)
        #expect(TemplateCascadePlan.inheritedVisibility(.public) == .public)
    }

    @Test func aWorkspaceAgentKeepsItsWorkflowsBundled_andNoPageFollowsIt() {
        let mine = workflow("Mine")
        let shared = plan([mine], visibility: .workspace)
        #expect(shared.visibility == nil)
        #expect(shared.rows.map(\.state) == [.bundledOnly(.workspaceOnly)])
        #expect(!shared.mayPublish)

        var unlisted = record(mine, version: 1)
        unlisted.visibility = .hidden
        var inWorkspace = record(workflow("Other"), version: 1)
        inWorkspace.visibility = .workspace
        #expect(TemplateCascadePlan.visibilityFollowers([unlisted, inWorkspace], agentVisibility: .workspace).isEmpty)
        #expect(
            TemplateCascadePlan.visibilityFollowers([unlisted, inWorkspace], agentVisibility: .public)
                .map(\.templateID) == [unlisted.templateID],
            "a workflow shared with workspaces on its own doesn't follow its agent")
        #expect(!TemplateCascadeCopy.agentLinks(to: inWorkspace, agentVisibility: .workspace))
        #expect(TemplateCascadeCopy.agentLinks(to: unlisted, agentVisibility: .workspace))
    }

    @Test func builtInsTakeDownsAndRemovalsStayBundled() {
        let builtIn = workflow("Built in")
        let down = workflow("Down")
        let removed = workflow("Removed")
        let p = plan(
            [builtIn, down, removed],
            records: [record(down, version: 1, takenDown: true), record(removed, version: 1, removed: true)],
            builtIn: [builtIn.id])
        #expect(p.rows.map(\.state) == [.bundledOnly(.builtIn), .bundledOnly(.takenDown), .bundledOnly(.removedByAdmin)])
    }

    @Test func turningItOffKeepsTheRestOfThePlan() {
        let mine = workflow("Mine")
        let live = workflow("Live")
        let liveRecord = record(live, version: 1)
        let p = plan([mine, live], publishWorkflows: false, records: [liveRecord])
        #expect(p.rows.map(\.state) == [.bundledOnly(.turnedOff), .alreadyPublished(liveRecord)])
    }

    /// Without the address (the sheet before the key is read), a copy with
    /// an author address is yours when this Mac published it; any other
    /// is decided on publish, not called someone else's.
    @Test func anUnknownAddressFallsBackToThisMacsRecords_andLeavesTheRestToPublish() {
        let mine = workflow("Mine", version: 2, signedBy: Self.alice)
        let unknown = workflow("Unknown", signedBy: Self.bob)
        let p = plan([mine, unknown], own: nil, records: [record(mine, version: 1)])
        #expect(p.rows.map(\.state) == [.willPublish, .checksOnPublish(address: Self.bob)])
        #expect(p.toPublish.map(\.id) == [mine.id])
        #expect(plan([unknown], own: nil).mayPublish, "the toggle shows when publishing may give it a page")
        #expect(!plan([unknown]).mayPublish, "known to be someone else's")
        #expect(TemplateCascadeCopy.chip(.checksOnPublish(address: Self.bob), agentVisibility: .public).text == "Checked on publish")
    }

    /// Editing someone else's workflow re-seals it, which drops their
    /// signature but keeps their address. It's still theirs.
    @Test func someoneElsesAddressWithoutASignatureIsStillTheirs() {
        let edited = workflow("Edited", version: 2, signedBy: Self.bob, signature: nil)
        let mineUnsigned = workflow("Mine", signedBy: Self.alice, signature: nil)
        let p = plan([edited, mineUnsigned])
        #expect(p.rows.map(\.state) == [.linkedToAuthor(address: Self.bob), .willPublish])
        #expect(p.toPublish.map(\.id) == [mineUnsigned.id])
        let blank = workflow("Blank", signedBy: "", signature: nil)
        #expect(plan([blank]).rows.map(\.state) == [.willPublish], "an empty address is no author")
    }

    @Test func workflowPagesFollowTheAgentsVisibility_exceptPasswordAndDown() {
        func page(_ name: String, _ visibility: WorkflowVisibility, takenDown: Bool = false) -> WorkflowRegistryRecord {
            var r = record(workflow(name), version: 1, takenDown: takenDown)
            r.visibility = visibility
            return r
        }
        let pub = page("Public", .public)
        let hidden = page("Unlisted", .hidden)
        let locked = page("Locked", .password)
        let down = page("Down", .public, takenDown: true)
        let all = [pub, hidden, locked, down]
        #expect(TemplateCascadePlan.visibilityFollowers(all, agentVisibility: .hidden) == [pub])
        #expect(TemplateCascadePlan.visibilityFollowers(all, agentVisibility: .public) == [hidden])
        #expect(TemplateCascadePlan.visibilityFollowers(all, agentVisibility: .password).isEmpty)
    }

    @Test func theAgentsPageLinksOnlyToWhatItsVisitorsMaySee() {
        let t = workflow("W")
        var r = record(t, version: 1)
        #expect(TemplateCascadeCopy.agentLinks(to: r, agentVisibility: .public))
        r.visibility = .hidden
        #expect(!TemplateCascadeCopy.agentLinks(to: r, agentVisibility: .public))
        #expect(TemplateCascadeCopy.agentLinks(to: r, agentVisibility: .hidden))
        r.visibility = .password
        #expect(!TemplateCascadeCopy.agentLinks(to: r, agentVisibility: .hidden))
    }
}
