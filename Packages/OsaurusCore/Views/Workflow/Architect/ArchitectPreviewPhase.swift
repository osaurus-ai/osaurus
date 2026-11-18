//
//  ArchitectPreviewPhase.swift
//  osaurus
//
//  Where a workflow being made stands, in the living preview's words. One
//  phase at a time, each with one thing to do next: the Architect is
//  imagining or building it, it needs one thing first, it is ready to try,
//  it is being tried, it didn't work, it worked, it was added, it is live.
//  Derived from `DraftStatus` so the preview and the details never disagree.
//

import Foundation

enum ArchitectPreviewPhase: Equatable {
    /// Nothing drafted yet.
    case imagining
    /// The Architect is changing the draft; the preview is read-only.
    case building
    /// Something has to be set up before it can run.
    case needsSomething
    /// The Architect stopped with steps that can't run yet.
    case almostThere
    case readyToTry
    case trying
    case didntWork
    /// The latest try passed on the current steps.
    case worked
    /// Saved, and unchanged since.
    case added
    /// Saved, unchanged, and published.
    case live

    /// The pure rule, on plain inputs so tests need no stores.
    /// `isGenerating` wins: while the Architect works, nothing in the
    /// preview asks the person for anything.
    static func derive(
        hasContent: Bool, status: DraftStatus.Kind, isGenerating: Bool, isSaved: Bool, isPublished: Bool
    ) -> Self {
        guard hasContent else { return .imagining }
        if isGenerating { return .building }
        switch status {
        case .testing: return .trying
        case .testFailed: return .didntWork
        default: break
        }
        if isSaved { return isPublished ? .live : .added }
        switch status {
        case .drafting: return .almostThere
        case .needsSetup: return .needsSomething
        case .tested: return .worked
        case .ready, .testing, .testFailed: return .readyToTry
        }
    }

    @MainActor
    static func derive(draft: WorkflowDraft, status: DraftStatus, isGenerating: Bool) -> Self {
        let saved = DraftRevisionCache.savedState(draft)
        return derive(
            hasContent: !ArchitectSidebarPanel.hasNothingDrafted(draft.definition), status: status.kind,
            isGenerating: isGenerating, isSaved: saved.isSaved, isPublished: saved.isPublished)
    }

    /// Build → Run → Share.
    var stage: WorkflowMakeStage {
        switch self {
        case .imagining, .building, .needsSomething, .almostThere: return .make
        case .readyToTry, .trying, .didntWork, .worked: return .tryIt
        case .added, .live: return .share
        }
    }

    /// Whether the stepper's current marker pulses: something is happening
    /// that the person is waiting on.
    var isActive: Bool { self == .imagining || self == .building || self == .trying }
}

/// Whether a draft is the saved workflow as it is now, and whether that
/// workflow is published.
struct DraftSavedState: Equatable {
    var isSaved: Bool
    var isPublished: Bool

    static let unsaved = DraftSavedState(isSaved: false, isPublished: false)

    /// Saved means the draft continues the latest saved version, and its
    /// steps and name are still that version's.
    static func isSaved(_ draft: WorkflowDraft, latest: Template?) -> Bool {
        guard draft.templateID != nil, let latest, draft.baseVersion == latest.version,
            let saved = latest.workflow
        else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == latest.name.trimmingCharacters(in: .whitespacesAndNewlines)
            && WorkflowDiff.plainLines(from: saved, to: draft.definition).isEmpty
    }

    /// A live listing: published from this Mac and neither taken down nor
    /// removed.
    static func isPublished(_ record: WorkflowRegistryRecord?) -> Bool {
        record?.isLive ?? false
    }

    @MainActor
    static func live(_ draft: WorkflowDraft) -> DraftSavedState {
        guard let templateID = draft.templateID else { return .unsaved }
        let saved = isSaved(draft, latest: TemplateStore.shared.latest(id: templateID))
        return DraftSavedState(
            isSaved: saved,
            isPublished: saved && isPublished(WorkflowRegistryRecordStore.shared.record(for: templateID)))
    }
}
