//
//  SystemStatusBar.swift
//  osaurus
//
//  Compact RAM + storage status bar shared by the Models download view and
//  the Image Generation download sub-tab. Extracted from `ModelDownloadView`
//  so both surfaces render identical resource gauges.
//

import SwiftUI

// MARK: - System Status Bar

/// Compact bar showing available memory and storage with mini gauges.
struct SystemStatusBar: View {
    @Environment(\.theme) private var theme

    let totalMemoryGB: Double
    let usedMemoryGB: Double
    let availableStorageGB: Double
    let totalStorageGB: Double

    var body: some View {
        HStack(spacing: 20) {
            ResourceGauge(
                label: L("RAM"),
                icon: "memorychip",
                usedFraction: totalMemoryGB > 0 ? usedMemoryGB / totalMemoryGB : 0,
                detail: String(
                    format: L("%.0f GB free / %.0f GB"),
                    max(0, totalMemoryGB - usedMemoryGB),
                    totalMemoryGB
                )
            )

            ResourceGauge(
                label: L("Storage"),
                icon: DirectoryPickerService.shared.hasValidDirectory ? "externaldrive" : "internaldrive",
                usedFraction: totalStorageGB > 0
                    ? (totalStorageGB - availableStorageGB) / totalStorageGB : 0,
                detail: String(
                    format: L("%.0f GB free / %.0f GB"),
                    availableStorageGB,
                    totalStorageGB
                )
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground)
    }
}

/// Reusable mini gauge showing a label, icon, detail text, and color-coded progress bar.
struct ResourceGauge: View {
    @Environment(\.theme) private var theme

    let label: String
    let icon: String
    let usedFraction: Double
    let detail: String

    private var clampedFraction: Double { min(1.0, max(0, usedFraction)) }

    private var barColor: Color {
        if clampedFraction < 0.7 { return theme.successColor }
        if clampedFraction < 0.9 { return theme.warningColor }
        return theme.errorColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(barColor)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.tertiaryBackground)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geometry.size.width * clampedFraction)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
