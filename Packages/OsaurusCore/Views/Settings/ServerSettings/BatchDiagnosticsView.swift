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
                stat(
                    "Max per-model high-water",
                    value: "\(snapshot.activeHighWatermark)"
                )
                stat(
                    "Configured engine capacity",
                    value: engineCapacityValue(snapshot)
                )
                stat(
                    "Available engine slots",
                    value: "\(snapshot.nominalAvailableCapacity)"
                )
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
                stat("Paged evictions", value: "\(snapshot.pagedEvictions)")
                stat(
                    "Disk L2 hits / misses / stores",
                    value: "\(snapshot.diskL2Hits) / \(snapshot.diskL2Misses) / \(snapshot.diskL2Stores)",
                    identifier: "live-activity-disk-l2-hits-misses-stores"
                )
                stat(
                    "Disk L2 used / cap",
                    value: Self.diskUsageValue(snapshot),
                    identifier: "live-activity-disk-l2-used-cap"
                )
                stat(
                    "Disk L2 evictions / evicted",
                    value:
                        "\(snapshot.diskL2Evictions) / \(DiskCacheUsage.format(bytes: snapshot.diskL2EvictedBytes))",
                    identifier: "live-activity-disk-l2-evictions"
                )
                stat(
                    "Disk L2 quota passes / last pass",
                    value: Self.quotaPassValue(snapshot),
                    identifier: "live-activity-disk-l2-quota-passes"
                )
                stat(
                    "Disk L2 failed writes",
                    value: "\(snapshot.diskL2FailedIndexWrites)",
                    identifier: "live-activity-disk-l2-failed-writes"
                )
                stat(
                    "Disk L2 pressure",
                    value: Self.pressureValue(snapshot),
                    identifier: "live-activity-disk-l2-pressure"
                )
                stat(
                    "Last request cache restore",
                    value: Self.cacheRestoreValue(snapshot.lastCacheRestore),
                    identifier: "live-activity-last-cache-restore"
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

    /// One readout row. A row that carries an `identifier` is a single
    /// accessibility element — the label as its label, the figure as its
    /// value — so assistive tools and UI automation read the pair together
    /// instead of two unrelated texts.
    @ViewBuilder
    private func stat(_ label: String, value: String, identifier: String? = nil) -> some View {
        let row = HStack {
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
        if let identifier {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module))
                .accessibilityValue(Text(verbatim: value))
                .accessibilityIdentifier(identifier)
        } else {
            row
        }
    }

    /// Bytes on disk against the cap the runtime enforces, which can differ
    /// from the saved setting until the next model load.
    static func diskUsageValue(_ snapshot: BatchDiagnosticsSnapshot) -> String {
        let used = DiskCacheUsage.format(bytes: snapshot.diskL2PayloadBytes)
        guard snapshot.diskL2MaxBytes > 0 else { return "\(used) / —" }
        return "\(used) / \(DiskCacheUsage.format(bytes: snapshot.diskL2MaxBytes))"
    }

    static func quotaPassValue(_ snapshot: BatchDiagnosticsSnapshot) -> String {
        guard snapshot.diskL2QuotaPasses > 0 else { return "0 / —" }
        return "\(snapshot.diskL2QuotaPasses) / "
            + String(format: "%.1f ms", snapshot.diskL2LastQuotaPassMs)
    }

    /// The runtime's own name for the event, which is what its logs use.
    static func pressureValue(_ snapshot: BatchDiagnosticsSnapshot) -> String {
        guard snapshot.diskL2PressureEventSeq > 0 else { return L("none") }
        guard let kind = snapshot.diskL2PressureKind else {
            return "#\(snapshot.diskL2PressureEventSeq)"
        }
        let chat = snapshot.diskL2PressureChainId.map { " · chat \($0.prefix(8))" } ?? ""
        return "\(kind)\(chat) · #\(snapshot.diskL2PressureEventSeq)"
    }

    static func cacheRestoreValue(_ restore: CacheRestoreSummary?) -> String {
        guard let restore else { return L("No request yet") }
        guard restore.restoredTokens > 0 else { return L("none (cold)") }
        let counts = "\(restore.restoredTokens) / \(restore.promptTokens) \(L("tokens"))"
        guard let detail = restore.detail, !detail.isEmpty else { return counts }
        return "\(counts) · \(detail)"
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

    private func engineCapacityValue(_ snapshot: BatchDiagnosticsSnapshot) -> String {
        if let summary = snapshot.engineCapacitySummary, !summary.isEmpty {
            return summary
        }
        return "\(snapshot.configuredEngineCapacity)"
    }
}
