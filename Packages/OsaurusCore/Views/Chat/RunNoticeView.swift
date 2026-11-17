//
//  RunNoticeView.swift
//  osaurus
//
//  The row under a run that ended without an answer: what happened in one
//  sentence, Try Again, the one remedy that fits, and the runtime's own
//  numbers behind a Details disclosure.
//

import SwiftUI

struct RunNoticeView: View {
    let outcome: ChatRunOutcome
    let onTryAgain: () -> Void
    var onContinue: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var showsDetails = false
    @State private var isFreeingMemory = false
    @State private var freedSummary: String?

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.caption, weight: .medium)
                .foregroundColor(theme.status.warning.foreground)
                .accessibilityHidden(true)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: theme.space.s6) {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(outcome.title)
                        .textStyle(.label, weight: 500)
                        .foregroundColor(theme.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(freedSummary ?? outcome.explanation)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
                if showsDetails { details }
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space.s12)
        .settingsChrome(.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run-notice-\(outcome.kind.rawValue)")
    }

    private var icon: String {
        switch outcome.cause {
        case .memory: return "memorychip"
        case .modelBusy: return "hourglass"
        case .outputLimit, .contextTooLong: return "text.badge.xmark"
        case .incomplete: return "exclamationmark.bubble"
        case .stopped: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: theme.space.s8) {
            if outcome.offersContinue, let onContinue {
                Button(L("Continue")) {
                    record("continue")
                    onContinue()
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .accessibilityIdentifier("run-notice-continue")
            }
            if outcome.retryable {
                Button(L("Try Again")) {
                    record("try_again")
                    onTryAgain()
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .disabled(isFreeingMemory)
                .accessibilityIdentifier("run-notice-try-again")
            }
            if outcome.canFreeMemory {
                Button(L("Free Up Memory"), action: freeUpMemory)
                    .assignedSettingsButtonStyle(.secondary, isLoading: isFreeingMemory, size: .compact)
                    .disabled(isFreeingMemory)
                    .help(freeUpMemoryHelp)
                    .accessibilityIdentifier("run-notice-free-memory")
            }
            if hasDetails {
                Button(showsDetails ? L("Hide Details") : L("Details")) { showsDetails.toggle() }
                    .assignedSettingsButtonStyle(.tertiary, size: .compact)
                    .accessibilityIdentifier("run-notice-details")
            }
        }
    }

    private var hasDetails: Bool {
        !outcome.facts.isEmpty || outcome.settingId != nil
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            ForEach(Array(outcome.facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Text(fact.label)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                    Text(fact.value)
                        .textStyle(.footnote, monospacedDigit: true)
                        .foregroundColor(theme.text.secondary)
                        .textSelection(.enabled)
                }
            }
            if let note = outcome.settingNote {
                Text(note)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let settingId = outcome.settingId {
                Button(L("Open Setting")) {
                    record("open_setting")
                    SettingsLanding.open(id: settingId)
                }
                    .assignedSettingsButtonStyle(.tertiary, size: .compact)
                    .accessibilityIdentifier("run-notice-open-setting")
            }
        }
    }

    private var freeUpMemoryHelp: String {
        outcome.freeableModels.isEmpty
            ? L("Releases cached memory, then tries again.")
            : String(
                format: L("Unloads %@ and releases cached memory, then tries again."),
                outcome.freeableModels.joined(separator: ", "))
    }

    private func record(_ remedy: String) {
        FeatureTelemetry.runOutcomeRemedy(kind: outcome.kind.rawValue, remedy: remedy)
    }

    private func freeUpMemory() {
        isFreeingMemory = true
        let candidates = outcome.freeableModels
        record("free_up_memory")
        Task { @MainActor in
            let result = await ModelRuntime.shared.freeUpMemory(unloading: candidates)
            freedSummary = result.summary
            isFreeingMemory = false
            onTryAgain()
        }
    }
}
