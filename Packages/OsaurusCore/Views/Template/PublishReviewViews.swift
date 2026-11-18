//
//  PublishReviewViews.swift
//  osaurus
//
//  Store review, drawn: the four-step tracker (Listing → Signed and
//  uploaded → Review → In the store), the dashboard's Review panel with the
//  reviewer's note and the Revise / Resubmit loop, and the library chip.
//

import SwiftUI

// MARK: - Steps

extension PublishReviewState {
    /// The tracker for a submission that has reached the registry.
    func steps(uploadedVersion: Int, now: Date = Date()) -> [SettingsStep] {
        let review = self.review
        let reviewStep: SettingsStep
        let storeStep: SettingsStep
        switch phase {
        case .inReview:
            reviewStep = SettingsStep(
                id: "review", title: L("Review"),
                detail: review.map { L("Submitted \(PublishedWorkflowDashboard.relative($0.submittedAt, now: now))") },
                state: .waiting)
            storeStep = SettingsStep(
                id: "store", title: L("In the store"),
                detail: listedVersion.map { L("v\($0) stays listed") } ?? L("Unlisted until approved"),
                state: listedVersion == nil ? .upcoming : .done)
        case .changesRequested:
            reviewStep = SettingsStep(id: "review", title: L("Review"), detail: L("Changes requested"), state: .attention)
            storeStep = SettingsStep(
                id: "store", title: L("In the store"),
                detail: listedVersion.map { L("v\($0) stays listed") } ?? L("Still unlisted"),
                state: listedVersion == nil ? .upcoming : .done)
        case .listed:
            reviewStep = SettingsStep(
                id: "review", title: L("Review"),
                detail: review?.decidedAt.map { L("Approved \(PublishedWorkflowDashboard.relative($0, now: now))") }
                    ?? L("Approved"),
                state: .done)
            storeStep = SettingsStep(
                id: "store", title: L("In the store"), detail: listedVersion.map { L("v\($0) listed") }, state: .done)
        case .linkOnly, .takenDown, .removed:
            reviewStep = SettingsStep(id: "review", title: L("Review"), detail: L("Not needed"), state: .skipped)
            storeStep = SettingsStep(id: "store", title: L("In the store"), detail: L("Link only"), state: .skipped)
        }
        return [
            SettingsStep(id: "listing", title: L("Listing"), detail: visibility.title, state: .done),
            SettingsStep(
                id: "upload", title: L("Signed and uploaded"),
                detail: L("v\(review?.version ?? uploadedVersion)"), state: .done),
            reviewStep,
            storeStep,
        ]
    }

    /// The tracker while the Share sheet signs and uploads.
    static func publishingSteps(visibility: WorkflowVisibility) -> [SettingsStep] {
        let reviewed = visibility == .public
        return [
            SettingsStep(id: "listing", title: L("Listing"), detail: visibility.title, state: .done),
            SettingsStep(id: "upload", title: L("Signed and uploaded"), detail: L("Signing…"), state: .working),
            SettingsStep(
                id: "review", title: L("Review"), detail: reviewed ? nil : L("Not needed"),
                state: reviewed ? .upcoming : .skipped),
            SettingsStep(
                id: "store", title: L("In the store"), detail: reviewed ? nil : L("Link only"),
                state: reviewed ? .upcoming : .skipped),
        ]
    }

    var chipTone: StatusChip.Tone { phase == .changesRequested ? .warning : .info }
    var chipIcon: String { phase == .changesRequested ? "exclamationmark.bubble" : "clock" }
}

// MARK: - Chip

/// "In review" or "Changes requested" for library cards and pages, with a
/// dot while the decision is unopened. Nothing when review isn't the story.
struct PublishReviewChip: View {
    let record: WorkflowRegistryRecord

    var body: some View {
        let state = PublishReviewState(record: record)
        if let text = state.chipText {
            StatusChip(
                text, tone: state.chipTone, icon: state.unseen ? nil : state.chipIcon, showsDot: state.unseen,
                help: state.detail())
        } else if state.unseen, state.phase == .listed {
            StatusChip(L("Approved"), tone: .success, showsDot: true, help: state.detail())
        }
    }
}

// MARK: - Panel

/// The dashboard's top section while store review is part of the story:
/// where it stands, when it'll be decided, and, when changes were
/// requested, the reviewer's note with Revise with Architect and Resubmit.
struct PublishReviewPanel: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var watcher = RegistryReviewWatcher.shared

    let record: WorkflowRegistryRecord
    /// The library's latest version, when it's ahead of the registry's.
    let localAhead: Template?
    let banned: Bool
    /// Nil hides Revise (agent templates change in their agent).
    let onRevise: (() -> Void)?
    let onResubmit: (Template) -> Void

    private var state: PublishReviewState { PublishReviewState(record: record) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                SettingsFieldLabel("Store Review")
                Spacer()
                if state.phase == .inReview { watchingNote }
            }
            VStack(alignment: .leading, spacing: theme.space.s16) {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(verbatim: state.headline)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(headlineTint)
                    Text(verbatim: state.detail())
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsStepTracker(
                    steps: state.steps(uploadedVersion: record.registryLatestVersion ?? record.version))
            }
            .padding(theme.space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.card)
            if state.phase == .changesRequested { changesRequested }
        }
        .settingsLandingAnchor(record.kind == .agent ? "agents.templates.review" : "workflows.review")
    }

    private var headlineTint: Color {
        switch state.phase {
        case .changesRequested: theme.status.warning.foreground
        case .listed: theme.status.success.foreground
        default: theme.text.primary
        }
    }

    private var watchingNote: some View {
        HStack(spacing: theme.space.s4) {
            if watcher.isWatching {
                StatusChip(L("Watching"), tone: .info, showsDot: true, help: L("Osaurus hears the decision within seconds and lets you know."))
            } else {
                Text("You'll see the decision here.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
        }
    }

    private var changesRequested: some View {
        let version = state.reviewedVersion ?? record.version
        return SettingsCallout(
            icon: "exclamationmark.bubble",
            title: "What the Osaurus team asked for",
            message: localAhead != nil
                ? "A newer version is on this Mac. Resubmit it when it addresses the note."
                : record.kind == .agent
                    ? "Change the agent, save it as a template with the same name, then resubmit it here."
                    : "Fix it, save a new version, then resubmit it here.",
            tone: .warning,
            quote: state.review?.note ?? L("No note was left for version \(version).")
        ) {
            if let onRevise {
                Button(action: onRevise) {
                    Label {
                        Text("Revise with Architect", bundle: .module)
                    } icon: {
                        Image(systemName: "wand.and.stars")
                    }
                }
                .buttonStyle(.settings(localAhead == nil ? .primary : .secondary, size: .compact))
                .help(L("Opens it in the Architect with the reviewer's note"))
            }
            if let localAhead {
                Button {
                    onResubmit(localAhead)
                } label: {
                    Text(verbatim: L("Resubmit v\(localAhead.version)"))
                }
                .buttonStyle(.settings(.primary, size: .compact))
                .disabled(banned)
            }
        }
    }
}
