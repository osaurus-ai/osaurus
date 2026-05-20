//
//  ConcurrencySection.swift
//  osaurus
//
//  Concurrency & batching controls plus a live BatchEngine diagnostics
//  readout. `maxConcurrentSequences` + `prefillStepSize` +
//  `continuousBatching` are wired end-to-end through
//  `MLXBatchAdapter.Registry`; the rest persist for a follow-up bridge.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct ConcurrencySection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    @State private var maxConcurrentText: String = ""
    @State private var initialized: Bool = false
    @State private var diagnostics: BatchDiagnosticsSnapshot?
    @State private var diagnosticsTimer: Timer?

    var body: some View {
        SettingsSection(
            title: "Concurrency & Batching",
            icon: "gauge.with.dots.needle.bottom.0percent"
        ) {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .engineReady,
                    blurb:
                        "Max concurrent sequences and prefill step size feed BatchEngine through ModelRuntime."
                )

                SettingsStepperField(
                    label: "Max Concurrent Sequences",
                    help:
                        "BatchEngine maxBatchSize. 1 keeps compile path engaged; >1 enables continuous batching.",
                    text: $maxConcurrentText,
                    range: 1 ... 32,
                    step: 1,
                    defaultValue: 1
                )
                .onChange(of: maxConcurrentText) { _, _ in commitMaxConcurrent() }

                OptionalIntField(
                    label: "Prefill Step Size",
                    placeholder: "Empty = engine default",
                    help: "Chunk size for the prompt-prefill loop.",
                    value: $draft.concurrency.prefillStepSize
                )

                SettingsToggle(
                    title: L("Continuous Batching"),
                    description: "Allow new requests to join an in-flight batch for shared decode.",
                    isOn: $draft.concurrency.continuousBatching
                )

                SettingsDivider()

                SettingsSubsection(label: "Planned Batching Controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        ServerSettingsPlannedBanner(
                            blurb: "Persisted today; runtime consumers are not yet implemented."
                        )

                        OptionalIntField(
                            label: "Prefill Batch Size",
                            placeholder: "Empty = engine default",
                            help: "Number of prefill chunks decoded together.",
                            value: $draft.concurrency.prefillBatchSize
                        )

                        OptionalIntField(
                            label: "Completion Batch Size",
                            placeholder: "Empty = engine default",
                            help: "Number of decode steps run together.",
                            value: $draft.concurrency.completionBatchSize
                        )

                        SettingsField(
                            label: "SMELT Mode",
                            hint: "Selects the SMELT execution mode when supported by the model."
                        ) {
                            Picker("", selection: $draft.concurrency.smeltMode) {
                                ForEach(VMLXServerSmeltMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Live Diagnostics") {
                    BatchDiagnosticsView(snapshot: diagnostics)
                }
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            syncFromDraft()
            startDiagnostics()
        }
        .onDisappear { stopDiagnostics() }
        .onChange(of: draft.concurrency.maxConcurrentSequences) { _, _ in syncFromDraft() }
    }

    private func syncFromDraft() {
        let desired = draft.concurrency.maxConcurrentSequences.map(String.init) ?? "1"
        if maxConcurrentText != desired { maxConcurrentText = desired }
    }

    private func commitMaxConcurrent() {
        let trimmed = maxConcurrentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else { return }
        let clamped = min(parsed, 32)
        if draft.concurrency.maxConcurrentSequences != clamped {
            draft.concurrency.maxConcurrentSequences = clamped
        }
    }

    private func startDiagnostics() {
        refresh()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stopDiagnostics() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func refresh() {
        Task { @MainActor in
            diagnostics = await MLXBatchAdapter.snapshotDiagnostics()
        }
    }
}

/// Read-only stat grid for `BatchDiagnosticsSnapshot`. Renders an empty
/// state when no engine has been created yet.
private struct BatchDiagnosticsView: View {
    let snapshot: BatchDiagnosticsSnapshot?
    @Environment(\.theme) private var theme

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 8) {
                stat("Active slots", value: "\(snapshot.activeCount)")
                stat("Queued", value: "\(snapshot.pendingCount)")
                stat("High-water active", value: "\(snapshot.activeHighWatermark)")
                stat("Decode-split count", value: "\(snapshot.decodeSplitCount)")
                stat("TurboQuant compressions", value: "\(snapshot.turboQuantCompressions)")
                stat(
                    "Engine status",
                    value: snapshot.isAcceptingRequests ? L("Accepting requests") : L("Draining")
                )
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .foregroundColor(theme.tertiaryText)
                Text(
                    "No model loaded — diagnostics appear once a request creates a BatchEngine.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func stat(_ label: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.inputBackground)
        )
    }
}
