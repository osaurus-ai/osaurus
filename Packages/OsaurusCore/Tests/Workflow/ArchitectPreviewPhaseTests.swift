import Foundation
import Testing

@testable import OsaurusCore

struct ArchitectPreviewPhaseTests {
    private func phase(
        content: Bool = true, _ status: DraftStatus.Kind, generating: Bool = false, saved: Bool = false,
        published: Bool = false
    ) -> ArchitectPreviewPhase {
        ArchitectPreviewPhase.derive(
            hasContent: content, status: status, isGenerating: generating, isSaved: saved, isPublished: published)
    }

    @Test
    func nothingDrafted_isImagining_whetherOrNotTheArchitectIsWorking() {
        #expect(phase(content: false, .drafting, generating: true) == .imagining)
        #expect(phase(content: false, .drafting) == .imagining)
    }

    @Test
    func whileTheArchitectWorks_everyStateReadsBuilding() {
        let kinds: [DraftStatus.Kind] = [.drafting, .needsSetup, .ready, .testing, .tested, .testFailed]
        for kind in kinds {
            #expect(phase(kind, generating: true) == .building)
            #expect(phase(kind, generating: true, saved: true, published: true) == .building)
        }
    }

    @Test
    func afterTheArchitectStops_eachStatusHasItsOwnPhase() {
        #expect(phase(.drafting) == .almostThere)
        #expect(phase(.needsSetup) == .needsSomething)
        #expect(phase(.ready) == .readyToTry)
        #expect(phase(.testing) == .trying)
        #expect(phase(.testFailed) == .didntWork)
        #expect(phase(.tested) == .worked)
    }

    @Test
    func savedAndUnchanged_isAdded_thenLiveOncePublished() {
        #expect(phase(.tested, saved: true) == .added)
        #expect(phase(.ready, saved: true) == .added)
        #expect(phase(.needsSetup, saved: true) == .added)
        #expect(phase(.tested, saved: true, published: true) == .live)
    }

    @Test
    func aTryOnASavedWorkflow_stillShowsTryingAndFailures() {
        #expect(phase(.testing, saved: true) == .trying)
        #expect(phase(.testFailed, saved: true, published: true) == .didntWork)
    }

    @Test
    func editingAfterSaving_fallsBackToMakingOrTrying() {
        // An edit makes the draft unsaved again; the status follows the new steps.
        #expect(phase(.ready, saved: false, published: false) == .readyToTry)
        #expect(phase(.drafting, saved: false) == .almostThere)
    }

    @Test
    func phases_mapOntoMakeTryShare() {
        let make: [ArchitectPreviewPhase] = [.imagining, .building, .needsSomething, .almostThere]
        let tryIt: [ArchitectPreviewPhase] = [.readyToTry, .trying, .didntWork, .worked]
        let share: [ArchitectPreviewPhase] = [.added, .live]
        #expect(make.allSatisfy { $0.stage == .make })
        #expect(tryIt.allSatisfy { $0.stage == .tryIt })
        #expect(share.allSatisfy { $0.stage == .share })
        #expect(ArchitectPreviewPhase.building.isActive && ArchitectPreviewPhase.trying.isActive)
        #expect(!ArchitectPreviewPhase.worked.isActive)
    }

    // MARK: - Saved state

    private func savedDraft() -> (WorkflowDraft, Template) {
        var draft = WorkflowDraft(name: "Inbox Sorter", definition: WF.intake())
        let template = draft.template()
        draft.templateID = template.id
        draft.baseVersion = template.version
        return (draft, template)
    }

    @Test
    func aDraftMatchingItsLatestVersion_isSaved() {
        let (draft, template) = savedDraft()
        #expect(DraftSavedState.isSaved(draft, latest: template))
    }

    @Test
    func aNewDraft_orOneWithChangedSteps_orAnOlderBase_isNotSaved() {
        let (draft, template) = savedDraft()
        #expect(!DraftSavedState.isSaved(WorkflowDraft(name: "New", definition: WF.intake()), latest: nil))

        var edited = draft
        edited.definition.nodes.removeLast()
        #expect(!DraftSavedState.isSaved(edited, latest: template))

        var renamed = draft
        renamed.name = "Mail Sorter"
        #expect(!DraftSavedState.isSaved(renamed, latest: template))

        var newer = template
        newer.version += 1
        #expect(!DraftSavedState.isSaved(draft, latest: newer))
    }

    @Test
    func takenDownOrRemovedListings_areNotPublished() throws {
        #expect(!DraftSavedState.isPublished(nil))
        let page = try #require(URL(string: "https://store.osaurus.ai/w/s"))
        var record = WorkflowRegistryRecord(
            templateID: UUID(), registryID: "r", slug: "s", version: 1, contentHash: "h", url: page,
            rawURL: page, deepLink: page, address: "0xabc", registry: "https://store.osaurus.ai", sharedAt: Date())
        #expect(DraftSavedState.isPublished(record))
        record.takenDown = true
        #expect(!DraftSavedState.isPublished(record))
        record.takenDown = false
        record.removedByAdmin = true
        #expect(!DraftSavedState.isPublished(record))
    }
}
