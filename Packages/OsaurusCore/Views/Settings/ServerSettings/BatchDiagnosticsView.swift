//
//  BatchDiagnosticsView.swift
//  osaurus
//
//  Stat grid that renders a `BatchDiagnosticsSnapshot`. Owned by the
//  Server → Settings sidebar so multiple sections can render the same
//  live readout if needed (today only `LiveActivitySection` does).
//

import SwiftUI

struct BatchDiagnosticsView: View {
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
                stat("Loaded models", value: "\(snapshot.loadedModelCount)")
                stat(
                    "Native MTP",
                    value: nativeMTPValue(snapshot)
                )
                stat(
                    "Cache-enabled models",
                    value: "\(snapshot.cacheEnabledModelCount)"
                )
                stat("Hybrid caches", value: "\(snapshot.hybridModelCount)")
                stat(
                    "Paged-incompatible caches",
                    value: "\(snapshot.pagedIncompatibleModelCount)"
                )
                stat(
                    "Prefix hits / misses",
                    value: "\(snapshot.prefixHits) / \(snapshot.prefixMisses)"
                )
                stat(
                    "Disk L2 hits / misses / stores",
                    value: "\(snapshot.diskL2Hits) / \(snapshot.diskL2Misses) / \(snapshot.diskL2Stores)"
                )
                stat(
                    "SSM hits / misses / re-derives",
                    value:
                        "\(snapshot.ssmCompanionHits) / \(snapshot.ssmCompanionMisses) / \(snapshot.ssmCompanionReDerives)"
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

    private func nativeMTPValue(_ snapshot: BatchDiagnosticsSnapshot) -> String {
        guard snapshot.nativeMTPModelCount > 0 else { return L("Not active") }
        if let depthSummary = snapshot.nativeMTPDepthSummary,
            !depthSummary.isEmpty
        {
            return "\(snapshot.nativeMTPModelCount) \(L("active")) (\(depthSummary))"
        }
        return "\(snapshot.nativeMTPModelCount) \(L("active"))"
    }
}
