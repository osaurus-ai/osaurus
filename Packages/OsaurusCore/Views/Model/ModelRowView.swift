//
//  ModelRowView.swift
//  osaurus
//
//  Card-based model row with polished hover animations.
//  Includes download progress, actions, and smooth transitions.
//

import AppKit
import Foundation
import SwiftUI

/// The row has a hover effect and adapts its appearance based on download
/// state. Tapping the card opens the model's detail sheet via `onViewDetails`.
struct ModelRowView: View {
    // MARK: - Dependencies

    @Environment(\.theme) private var theme

    // MARK: - Properties

    /// Presentation values for the card. Built from an `MLXModel` for the LLM
    /// tabs and directly for image models, so both render identically.
    let content: ModelCardContent

    /// Current download state (not started, downloading, completed, or failed)
    let downloadState: DownloadState

    /// Optional download metrics (speed, ETA, bytes transferred)
    let metrics: ModelDownloadService.DownloadMetrics?

    /// Callback when user taps the Details button
    let onViewDetails: () -> Void

    /// Callback when the user taps a non-MLX (greyed) card. When set and the
    /// card is unsupported, this fires instead of `onViewDetails` so the host
    /// can explain that the model can't be used rather than open its details.
    var onUnsupportedTap: (() -> Void)? = nil

    /// Optional cancel action when downloading or paused
    let onCancel: (() -> Void)?

    /// Optional pause action while a download is in flight
    var onPause: (() -> Void)? = nil

    /// Optional resume action while a download is paused
    var onResume: (() -> Void)? = nil

    // MARK: - State

    /// Whether the user is currently hovering over this row
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            if content.isUnsupportedFormat, let onUnsupportedTap {
                onUnsupportedTap()
            } else {
                onViewDetails()
            }
        }) {
            VStack(spacing: 0) {
                gradientHeader

                VStack(alignment: .leading, spacing: 10) {
                    leadTags

                    statStrip

                    if !content.description.isEmpty {
                        Text(content.description)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Push the footer to the bottom so the popularity /
                    // release line sits at the same place on every card,
                    // keeping rows easy to scan and compare.
                    Spacer(minLength: 0)

                    cardFooter
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHovering ? theme.accentColor.opacity(0.25) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.shadowColor.opacity(
                    isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                ),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            // Grey out bundles the local engine can't load (non-MLX format)
            // while keeping the card tappable so its detail sheet can explain
            // why. Desaturate + fade so it reads as "present but unavailable".
            .saturation(content.isUnsupportedFormat ? 0 : 1)
            .opacity(content.isUnsupportedFormat ? 0.6 : 1)
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .localizedHelp(content.isUnsupportedFormat ? "Not an MLX model — the local engine can't load this bundle" : "")
    }

    // MARK: - Gradient Header

    private var gradientHeader: some View {
        ZStack {
            LinearGradient(
                colors: content.gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            highlightLayer

            RadialGradient(
                colors: [.black.opacity(0.30), .black.opacity(0)],
                center: UnitPoint(x: 0.88, y: 0.95),
                startRadius: 4,
                endRadius: 240
            )

            Text(content.name)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 16)

            VStack {
                HStack(alignment: .top, spacing: 6) {
                    // Download state lives on the left so the Top Pick
                    // ribbon keeps a fixed slot on the right and never
                    // shifts as state changes.
                    stateChip
                    Spacer(minLength: 0)
                    if content.isTopSuggestion {
                        topPickRibbon
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                headerProgressStrip
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var headerProgressStrip: some View {
        switch downloadState {
        case .downloading(let progress):
            progressStrip(progress: progress, isPaused: false)
        case .paused(let progress):
            progressStrip(progress: progress, isPaused: true)
        default:
            EmptyView()
        }
    }

    private func progressStrip(progress: Double, isPaused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.25))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isPaused ? Color.white.opacity(0.6) : .white)
                            .frame(width: geometry.size.width * progress)
                            .animation(.easeOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 4)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)

                if isPaused, let onResume {
                    Button(action: onResume) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Resume download")
                } else if !isPaused, let onPause {
                    Button(action: onPause) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Pause download")
                }

                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Cancel download")
                }
            }

            if isPaused {
                Text("Paused", bundle: .module)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            } else if let line = metrics?.formattedLine {
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var highlightLayer: some View {
        if isHovering {
            // TimelineView only ticks while it's in the view tree, so
            // un-hovered cards don't pay any animation cost.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let x = 0.34 + sin(t * 0.7) * 0.22
                let y = 0.28 + cos(t * 0.5) * 0.18
                RadialGradient(
                    colors: [.white.opacity(0.38), .white.opacity(0)],
                    center: UnitPoint(x: x, y: y),
                    startRadius: 4,
                    endRadius: 220
                )
            }
            .transition(.opacity)
        } else {
            RadialGradient(
                colors: [.white.opacity(0.32), .white.opacity(0)],
                center: UnitPoint(x: 0.22, y: 0.18),
                startRadius: 4,
                endRadius: 220
            )
            .transition(.opacity)
        }
    }

    private var topPickRibbon: some View {
        headerChip(icon: "star.fill", text: L("Top Pick"))
    }

    /// Unified download-state indicator pinned to the header's top-left.
    /// Live downloads/pauses still surface their controls and metrics via
    /// `headerProgressStrip`; this chip is the at-a-glance state.
    @ViewBuilder
    private var stateChip: some View {
        switch downloadState {
        case .downloading(let progress):
            headerChip(
                icon: "arrow.down.circle.fill",
                text: "\(L("Downloading")) \(Int(progress * 100))%"
            )
        case .paused(let progress):
            headerChip(
                icon: "pause.circle.fill",
                text: "\(L("Paused")) \(Int(progress * 100))%"
            )
        default:
            if content.isDownloaded {
                headerChip(icon: "checkmark.circle.fill", text: L("Downloaded"))
            }
        }
    }

    /// Shared capsule style for the header's corner chips so the state
    /// indicator and Top Pick ribbon read as one family.
    private func headerChip(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule().fill(.black.opacity(0.28))
        )
    }

    // MARK: - Body Sections

    /// Editorial / decision tags. Use-case leads (when set), followed by
    /// the colored compatibility verdict and the LLM/VLM type so the eye
    /// lands on "what is it / will it run" before raw specs.
    private var leadTags: some View {
        FlowLayout(spacing: 6) {
            if let useCase = content.useCase {
                // Tint + icon come from `ModelUseCase` so the vocabulary
                // matches the onboarding picker's `.useCase(...)` chip.
                TintedPill(
                    icon: useCase.iconName,
                    label: Text(useCase.displayName, bundle: .module),
                    color: useCase.tintColor
                )
            }
            if content.isUnsupportedFormat {
                TintedPill(
                    icon: "exclamationmark.octagon",
                    label: Text(L("Not MLX")),
                    color: theme.errorColor
                )
            }
            compatibilityBadge
            if let type = content.type {
                modelTypeBadge(type)
            }
        }
    }

    /// Fixed three-column spec strip. Columns stay in the same order with
    /// a "—" placeholder for missing values so cards line up for
    /// side-by-side comparison. Family cards replace the quant column (the
    /// representative build's quant would be misleading for a multi-build
    /// card) with the number of available versions; single-build cards keep
    /// the quant label since it's what distinguishes them.
    private var statStrip: some View {
        HStack(spacing: 0) {
            StatSegment(label: L("Size"), value: content.size)
            statDivider
            StatSegment(label: L("Params"), value: content.params)
            statDivider
            if content.variantCount > 1 {
                StatSegment(label: L("Versions"), value: "\(content.variantCount)")
            } else {
                StatSegment(label: L("Quant"), value: content.quant)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
        )
    }

    private var statDivider: some View {
        Rectangle()
            .fill(theme.cardBorder)
            .frame(width: 1, height: 22)
    }

    /// Muted footer with popularity and release recency. Pinned to the
    /// bottom of the card via a `Spacer` so it aligns across rows.
    @ViewBuilder
    private var cardFooter: some View {
        let downloads = content.downloadsText
        let released = content.releaseText
        if downloads != nil || released != nil {
            HStack(spacing: 8) {
                if let downloads {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 9, weight: .medium))
                        Text(L("\(downloads) downloads"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(theme.tertiaryText)
                }

                // Push popularity to the leading edge and release recency
                // to the trailing edge so the two read as distinct stats.
                Spacer(minLength: 8)

                // Curated entries set `releasedAt` explicitly; HF
                // auto-fetched ones pick it up from `lastModified` —
                // either way the prefix is "Released".
                if let released {
                    Text(L("Released \(released)"))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    /// Plain-language fit verdict. When the RAM estimate is known it reads
    /// as "Runs Well · needs ~10 GB" so new users get the "will this work on
    /// my Mac" answer without decoding quant/param jargon.
    @ViewBuilder
    private var compatibilityBadge: some View {
        switch content.compatibility {
        case .compatible:
            TintedPill(
                icon: "checkmark.shield",
                label: Text(fitText(verdict: L("Runs Well"))),
                color: theme.successColor
            )
        case .tight:
            TintedPill(
                icon: "exclamationmark.triangle",
                label: Text(fitText(verdict: L("Tight Fit"))),
                color: theme.warningColor
            )
        case .tooLarge:
            TintedPill(
                icon: "xmark.circle",
                label: Text(fitText(verdict: L("Too Large"))),
                color: theme.errorColor
            )
        case .unknown:
            EmptyView()
        }
    }

    private func fitText(verdict: String) -> String {
        guard let memory = content.memoryNeeded else { return verdict }
        return "\(verdict) · \(L("needs \(memory)"))"
    }

    /// Badge showing whether the model is an LLM, VLM, or image generator.
    @ViewBuilder
    private func modelTypeBadge(_ type: ModelCardType) -> some View {
        switch type {
        case .llm:
            TintedPill(icon: "text.bubble", label: Text(L("LLM")), color: theme.accentColor)
        case .vlm:
            TintedPill(icon: "eye", label: Text(L("VLM")), color: .purple)
        case .image:
            TintedPill(icon: "photo", label: Text(L("Image")), color: theme.accentColor)
        }
    }

}

// MARK: - Card Presentation Model

/// Theme-free display values for a model card. Built from an `MLXModel` for
/// the LLM tabs and directly for image models so both render through the same
/// `ModelRowView`. Colors that depend on the theme (compatibility, type pill)
/// stay as enums and are resolved inside the view.
struct ModelCardContent {
    let name: String
    let description: String
    let gradientColors: [Color]
    let isTopSuggestion: Bool
    let isDownloaded: Bool
    /// True when the bundle is on disk but not in MLX format, so the local
    /// engine can't load it. Greys the card and shows an explanatory badge.
    var isUnsupportedFormat: Bool = false
    let useCase: ModelUseCase?
    let compatibility: ModelCompatibility
    /// Formatted RAM the model needs at runtime (e.g. "~10.2 GB"), rendered
    /// inside the compatibility pill so the fit verdict reads in plain
    /// language instead of leaning on quant jargon.
    var memoryNeeded: String? = nil
    /// LLM / VLM / Image pill; `nil` to omit.
    let type: ModelCardType?
    let size: String?
    let params: String?
    let quant: String?
    /// Number of precision/quant builds this card represents. Catalog cards
    /// grouped by family carry the family's build count; ungrouped contexts
    /// (On Device, image models) leave it at 1, which hides the indicator.
    var variantCount: Int = 1
    /// Raw popularity / release strings; the footer applies its own wording.
    let downloadsText: String?
    let releaseText: String?
}

enum ModelCardType {
    case llm
    case vlm
    case image
}

extension ModelCardContent {
    /// LLM/VLM card content. `variantCount > 1` marks a family card (one
    /// card representing several precision/quant builds): the title becomes
    /// the family name so a build suffix like "qat MXFP4" never leads, and
    /// the quant column gives way to the version count.
    init(model: MLXModel, totalMemoryGB: Double, variantCount: Int = 1) {
        self.init(
            name: variantCount > 1
                ? ModelMetadataParser.familyDisplayName(from: model.id)
                : model.name,
            description: model.description,
            gradientColors: ModelCardGradient.colors(for: model),
            isTopSuggestion: model.isTopSuggestion,
            isDownloaded: model.isDownloaded,
            isUnsupportedFormat: model.isDownloaded && !model.isMLXFormat,
            useCase: model.useCase,
            compatibility: model.compatibility(totalMemoryGB: totalMemoryGB),
            memoryNeeded: model.formattedEstimatedMemory,
            type: model.useCase == .vision ? nil : (model.isVLM ? .vlm : .llm),
            size: model.formattedDownloadSize,
            params: model.parameterCount,
            quant: model.quantization,
            variantCount: variantCount,
            downloadsText: model.formattedDownloads,
            releaseText: model.formattedReleaseMonth
        )
    }
}

// MARK: - Stat Segment Component

/// One fixed column of the spec strip: a value over a small uppercase
/// label. Missing values render as a muted "—" so columns stay aligned
/// across cards for comparison.
private struct StatSegment: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(value ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(value == nil ? theme.tertiaryText : theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .textCase(.uppercase)
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tinted Pill Component

/// Colored icon + label capsule shared by the use-case, compatibility, and
/// LLM/VLM badges. Callers supply the `Text` so each keeps its own
/// localization (literal, `L(...)`, or module-bundle key).
private struct TintedPill: View {
    let icon: String
    let label: Text
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            label
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }
}

// MARK: - Card Gradient Palette

/// Color provider for the model card spotlight header. Curated families
/// get a hand-picked two-stop gradient. everything else gets a
/// deterministic hue derived from the repo id so unknown families stay
/// distinguishable at a glance without a manual mapping
enum ModelCardGradient {
    static func colors(for model: MLXModel) -> [Color] {
        colors(family: model.family, id: model.id)
    }

    /// Same palette selection without an `MLXModel`, for image-model cards.
    static func colors(family: String, id: String) -> [Color] {
        let key = family.lowercased()
        if let palette = curated[key] { return palette }
        return hashed(for: id)
    }

    /// Two-stop gradients tuned for white text. Stops sit roughly at
    /// Tailwind 500 and 700 of the same family saturated enough that
    /// white reads without a heavy shadow
    private static let curated: [String: [Color]] = [
        "qwen": [Color(hex: "0EA5E9"), Color(hex: "0E7490")],
        "gemma": [Color(hex: "6366F1"), Color(hex: "1D4ED8")],
        "llama": [Color(hex: "8B5CF6"), Color(hex: "A21CAF")],
        "phi": [Color(hex: "10B981"), Color(hex: "0F766E")],
        "mistral": [Color(hex: "F97316"), Color(hex: "DC2626")],
        "mixtral": [Color(hex: "F43F5E"), Color(hex: "C2410C")],
        "deepseek": [Color(hex: "2563EB"), Color(hex: "4338CA")],
        "granite": [Color(hex: "64748B"), Color(hex: "334155")],
        "liquid": [Color(hex: "EC4899"), Color(hex: "7C3AED")],
        "smollm": [Color(hex: "65A30D"), Color(hex: "15803D")],
        "hermes": [Color(hex: "F59E0B"), Color(hex: "C2410C")],
        "starcoder": [Color(hex: "0EA5E9"), Color(hex: "6D28D9")],
        "command-r": [Color(hex: "A855F7"), Color(hex: "BE185D")],
        "nemotron": [Color(hex: "22C55E"), Color(hex: "047857")],
        "yi": [Color(hex: "F59E0B"), Color(hex: "B91C1C")],
        "falcon": [Color(hex: "B45309"), Color(hex: "9A3412")],
        "internlm": [Color(hex: "0891B2"), Color(hex: "1D4ED8")],
        "stablelm": [Color(hex: "8B5CF6"), Color(hex: "1D4ED8")],
        "grok": [Color(hex: "334155"), Color(hex: "4338CA")],
    ]

    /// djb2 hash → two HSB hues separated by ~0.1 on the wheel, with a
    /// noticeable brightness drop between stops so the gradient reads
    /// as one. Saturation/brightness mirror the curated palette so the
    /// fallback feels like part of the same family
    private static func hashed(for id: String) -> [Color] {
        var hash: UInt64 = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let h1 = Double(hash % 360) / 360.0
        let h2 = (h1 + 0.1).truncatingRemainder(dividingBy: 1.0)
        return [
            Color(hue: h1, saturation: 0.70, brightness: 0.78),
            Color(hue: h2, saturation: 0.78, brightness: 0.55),
        ]
    }
}

// MARK: - Helper Functions

/// Extracts the repository name from a Hugging Face URL
///
/// Converts full URLs to readable repository names:
/// - Input: `https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit`
/// - Output: `mlx-community/Llama-3.2-1B-Instruct-4bit`
///
/// - Parameter urlString: Full Hugging Face URL
/// - Returns: Repository name in "organization/model" format, or the full URL if parsing fails
func repositoryName(from urlString: String) -> String {
    if let url = URL(string: urlString),
        url.host == "huggingface.co"
    {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if pathComponents.count >= 2 {
            return "\(pathComponents[0])/\(pathComponents[1])"
        }
    }
    // Fallback to showing the full URL if parsing fails
    return urlString
}
