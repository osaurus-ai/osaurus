//
//  LiveActivitySection.swift
//  osaurus
//
//  Read-only "what is the engine doing right now" card. Pulls the
//  aggregated `BatchEngine` snapshot from `MLXBatchAdapter` every two
//  seconds while the user is on the Settings tab.
//

import SwiftUI

struct LiveActivitySection: View {
    @State private var snapshot: BatchDiagnosticsSnapshot?
    @State private var effectiveGeneration:
        [String: MLXBatchAdapter.EffectiveGenerationSettings] = [:]
    /// What the adaptive MTP controller ACTUALLY settled on last turn, per
    /// model. Completion-time, so it explains the common surprise — asking for
    /// depth 3 and getting depth 1 because acceptance collapsed — that the
    /// load-scoped MTP section (a request, not a result) cannot show.
    @State private var lastMTP: [String: MTPStatsSummary] = [:]
    @State private var inferenceActivities: [InferenceActivitySnapshot] = []
    @State private var refreshTimer: Timer?
    @Environment(\.theme) private var theme

    var body: some View {
        ServerSettingsCard(
            section: .liveActivity,
            status: .engineReady,
            blurb:
                "Aggregated BatchEngine readout across every model loaded right now. Refreshes every 2 seconds.",
            spacing: 16
        ) {
            BatchDiagnosticsView(snapshot: snapshot)

            SettingsDivider()
            inferenceActivityReadout

            if !effectiveGeneration.isEmpty {
                SettingsDivider()
                effectiveSamplerReadout
            }

            if !lastMTP.isEmpty {
                SettingsDivider()
                mtpRuntimeReadout
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var inferenceActivityReadout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Inference now"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            if inferenceActivities.isEmpty {
                Text(L("Idle — no active or queued inference"))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            ForEach(inferenceActivities) { activity in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.modelName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(
                            "\(activity.phase.displayName) · \(activity.source.displayName) · "
                                + "\(Self.shortID(activity.id))"
                        )
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(theme.tertiaryText)
                        .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button(activity.cancellationRequested ? L("Stopping…") : L("Stop")) {
                        Task {
                            _ = await InferenceActivityRegistry.shared.cancel(id: activity.id)
                            await refreshActivities()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!activity.canCancel || activity.cancellationRequested)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// The sampler the model ACTUALLY ran with, per model, after every
    /// merge step.
    ///
    /// `MLXBatchAdapter.effectiveGenerationSettings` resolves per-request
    /// values over the user's Sampling Defaults over the bundle's shipped
    /// `generation_config.json`, and until now the result was reachable only
    /// through the HTTP admin endpoint's `last_effective_generation`. So the
    /// panel showed what was *requested* and nothing showed what *ran* — the
    /// exact gap that let the Sampling Defaults sit inert behind bundle
    /// defaults without anyone seeing it. Warm-up prefills are excluded
    /// upstream by `shouldRecordAsLastEffectiveGeneration`, so this describes
    /// a real turn.
    private var effectiveSamplerReadout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Sampler last used"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            ForEach(effectiveGeneration.keys.sorted(), id: \.self) { model in
                if let effective = effectiveGeneration[model] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.describe(effective))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(theme.tertiaryText)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What speculative decoding did on the last real turn, per model.
    ///
    /// The MTP Mode picker and depth field are a REQUEST; the adaptive
    /// controller downshifts depth on the fly when draft acceptance drops
    /// (depth 3 → 2 below 0.60, → 1 below 0.50), and on prose depth-3 drafts
    /// are accepted only a few percent of the time — so "auto" or a requested
    /// depth 3 legitimately RUNS at depth 1–2. Without this line that correct
    /// behaviour looks like the control is ignored. Shown per model, populated
    /// only for turns that actually ran native MTP.
    private var mtpRuntimeReadout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Speculative decoding last run"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            ForEach(lastMTP.keys.sorted(), id: \.self) { model in
                if let stats = lastMTP[model] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.describeMTP(stats))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(theme.tertiaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func describeMTP(_ stats: MTPStatsSummary) -> String {
        var parts: [String] = []
        // Requested depth vs the depth adaptive control actually held. The
        // arrow is the whole point: it names the undershoot instead of hiding
        // it, so a depth-3 request that ran at 1 reads as a decision, not a bug.
        if stats.depth == stats.activeDepth {
            parts.append("depth \(stats.activeDepth)")
        } else {
            parts.append("depth \(stats.depth) → \(stats.activeDepth)")
        }
        if stats.adaptiveDownshifts > 0 {
            parts.append(
                "\(stats.adaptiveDownshifts) downshift"
                    + (stats.adaptiveDownshifts == 1 ? "" : "s"))
        }
        // How much speculation actually paid, in wall-clock terms: tokens
        // committed per verify cycle. 1.0 is break-even (no better than plain
        // decode), depth+1 is the ceiling. This is the artifact-free number —
        // NOT accepted/(accepted+rejected), which reads high at depth ≥ 2
        // because rejects count once per cycle. A low value here IS why a deep
        // request downshifted.
        parts.append(String(format: "%.1f tok/verify", stats.avgCommittedPerVerify))
        if stats.arFallbackTokens > 0 {
            parts.append("AR fallback \(stats.arFallbackTokens) tok")
        }
        // The controller's own machine reason, when it bailed to AR decode.
        if let reason = stats.adaptiveFallbackReason, !reason.isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    static func describe(
        _ effective: MLXBatchAdapter.EffectiveGenerationSettings
    ) -> String {
        var parts = [
            "temp \(trim(effective.temperature))",
            "top-p \(trim(effective.topP))",
            "top-k \(effective.topK)",
            "min-p \(trim(effective.minP))",
            "max \(effective.maxTokens)",
        ]
        if let penalty = effective.repetitionPenalty {
            parts.append("rep \(trim(penalty))")
        }
        // 0 is OpenAI's "no penalty" default and is treated as unset by
        // `makeGenerateParameters`, so printing it would claim an effect that
        // is not applied.
        if let presence = effective.presencePenalty, presence != 0 {
            parts.append("presence \(trim(presence))")
        }
        if let frequency = effective.frequencyPenalty, frequency != 0 {
            parts.append("frequency \(trim(frequency))")
        }
        // Temperature 0 is argmax, which makes top-p/top-k/min-p inert. Say
        // so rather than printing values that cannot have applied.
        if effective.temperature == 0 {
            parts.append("(greedy — top-p/top-k/min-p inert)")
        }
        // What actually drafted the tokens. The MTP Mode picker is a request,
        // not a result: a bundle whose tuning artifact never asserted
        // `output_equivalent` cannot run speculative decoding even on Force-On.
        // Without this line the picker looks inert on exactly those models, and
        // the reason — already computed, already logged — reaches nobody.
        // Whether the compiled batch-decode path ran. Native MTP uses its own
        // iterator, which does not take `enableCompiledBatchDecode` at all —
        // so speculation and compilation are mutually exclusive today, and a
        // tok/s comparison that does not say which one was active cannot be
        // attributed. Printed for both legs so the difference is visible.
        parts.append(effective.compiledBatchDecode ? "compiled" : "uncompiled")
        if let strategy = effective.draftStrategy {
            parts.append("draft \(strategy)")
        } else if let reason = effective.mtpFallbackReason {
            parts.append("MTP off — \(reason)")
        } else {
            parts.append("draft none")
        }
        return parts.joined(separator: " · ")
    }

    private static func trim(_ value: Float) -> String {
        String(format: "%g", value)
    }

    private func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        Task { @MainActor in
            snapshot = await MLXBatchAdapter.snapshotDiagnostics()
            effectiveGeneration =
                await MLXBatchAdapter.lastEffectiveGenerationSettingsSnapshot()
            lastMTP = await MLXBatchAdapter.lastMTPStatsSnapshot()
            await refreshActivities()
        }
    }

    @MainActor
    private func refreshActivities() async {
        inferenceActivities = await InferenceActivityRegistry.shared.snapshot()
    }
}
