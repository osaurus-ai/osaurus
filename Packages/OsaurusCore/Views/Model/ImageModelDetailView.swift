//
//  ImageModelDetailView.swift
//  osaurus
//
//  Detail modal for an on-device image-generation bundle. Mirrors the LLM
//  `ModelDetailView` chrome (accent header bar, details card, action footer)
//  but is scoped to what image bundles carry. The footer offers Delete and
//  Re-download for staged bundles — the path for fixing a not-ready bundle
//  (e.g. one missing its weight shards).
//

import AppKit
import SwiftUI

struct ImageModelDetailView: View, Identifiable {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloads = ImageModelDownloadService.shared

    /// Bundle directory name; also the `Identifiable` id for sheet presentation.
    let id: String
    let displayName: String
    /// Known source repo (curated catalog) or `nil` to resolve from the marker.
    let repoId: String?
    /// Present when the bundle is installed (carries readiness + specs).
    let info: ImageModelInfo?

    @State private var resolvedRepoId: String? = nil
    @State private var hasAppeared = false
    @State private var showPanel = false

    /// `true` when the bundle is installed, ready, and supports a manual
    /// generate/edit run (gen or edit kind — upscale has no prompt panel).
    private var canRunPanel: Bool {
        guard let info, info.ready else { return false }
        return info.kind == "imageGen" || info.kind == "imageEdit"
    }
    private var isEditKind: Bool { info?.kind == "imageEdit" }

    private func state() -> DownloadState { downloads.states[id] ?? .notStarted }
    private var isInstalled: Bool { downloads.isInstalled(id) }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(spacing: 14) {
                    detailsCard
                    if let info, !info.ready, !info.blockedReasons.isEmpty {
                        blockedCard(info.blockedReasons)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .opacity(hasAppeared ? 1 : 0)

            actionFooter
        }
        .frame(width: 560, height: 520)
        .background(theme.primaryBackground)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { hasAppeared = true }
            resolvedRepoId = repoId ?? downloads.sourceRepoId(for: id)
        }
        .sheet(isPresented: $showPanel) {
            ImageGenerationPanelView(modelId: id, displayName: displayName, isEdit: isEditKind)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: ModelCardGradient.colors(family: info?.canonicalName ?? id, id: id),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 3)

            HStack(spacing: 10) {
                Text(displayName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accentColor)
                }

                Text(L("Image"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))

                Spacer(minLength: 12)

                if let repo = resolvedRepoId {
                    Button(action: { openHuggingFace(repo) }) {
                        HStack(spacing: 5) {
                            Text("🤗").font(.system(size: 12))
                            Text("View on Hugging Face", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(theme.primaryBackground)
        .overlay(
            Rectangle().fill(theme.cardBorder).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(spacing: 0) {
            metaRow(L("Repository"), resolvedRepoId ?? L("Unknown"))
            divider
            metaRow(L("Model id"), id)
            if let info {
                if info.totalBytes > 0 {
                    divider
                    metaRow(
                        L("Size"),
                        ByteCountFormatter.string(
                            fromByteCount: Int64(info.totalBytes), countStyle: .file))
                }
                if let quant = quantText(bits: info.quantizationBits, id: id) {
                    divider
                    metaRow(L("Quant"), quant)
                }
                if let steps = info.defaultSteps {
                    divider
                    metaRow(L("Default steps"), "\(steps)")
                }
                divider
                metaRow(
                    L("Status"), info.ready ? L("Ready") : L("Not ready"),
                    valueColor: info.ready ? theme.successColor : theme.warningColor)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
        )
    }

    private func blockedCard(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.warningColor)
                Text("This bundle isn't ready", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            ForEach(reasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundColor(theme.tertiaryText)
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if resolvedRepoId != nil {
                Text("Re-download to fetch any missing files.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.3), lineWidth: 1))
        )
    }

    private var divider: some View {
        Rectangle().fill(theme.cardBorder).frame(height: 1).padding(.horizontal, 14)
    }

    private func metaRow(_ label: String, _ value: String, valueColor: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(valueColor ?? theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var actionFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if case .downloading(let progress) = state() {
                    downloadingFooter(progress: progress)
                } else if isInstalled {
                    completedFooter
                } else {
                    notStartedFooter
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var notStartedFooter: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Text("Cancel", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            if let repo = resolvedRepoId {
                primaryButton(icon: "arrow.down.circle", title: "Download") {
                    downloads.download(repoId: repo, displayName: displayName)
                    dismiss()
                }
            }
        }
    }

    private var completedFooter: some View {
        HStack(spacing: 12) {
            Button(action: {
                downloads.delete(id)
                dismiss()
            }) {
                Text("Delete", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.errorColor)
            }
            .buttonStyle(PlainButtonStyle())

            if let repo = resolvedRepoId {
                Button(action: {
                    downloads.download(repoId: repo, displayName: displayName)
                    dismiss()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        Text("Re-download", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer()

            if canRunPanel {
                primaryButton(
                    icon: isEditKind ? "wand.and.stars" : "sparkles",
                    title: isEditKind ? "Edit" : "Generate"
                ) {
                    showPanel = true
                }
            } else {
                Button(action: { dismiss() }) {
                    Text("Done", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func downloadingFooter(progress: Double) -> some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryBackground)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.accentColor)
                        .frame(width: max(0, geometry.size.width * progress))
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                if let line = downloads.metrics[id]?.formattedLine {
                    Text("•").foregroundColor(theme.tertiaryText)
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: { downloads.cancel(id) }) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.errorColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func primaryButton(
        icon: String, title: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title, bundle: .module).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Helpers

    private func openHuggingFace(_ repo: String) {
        guard let url = URL(string: "https://huggingface.co/\(repo)") else { return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func quantText(bits: Int?, id: String) -> String? {
        if let bits { return "\(bits)-bit" }
        let lower = id.lowercased()
        if lower.contains("fp8") { return "FP8" }
        if lower.contains("nf4") { return "NF4" }
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") { return "6-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        return nil
    }
}
