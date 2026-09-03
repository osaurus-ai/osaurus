//
//  MTPSection.swift
//  osaurus
//
//  Speculative Decoding controls for the Server → Settings tab.
//  Native MTP launch is host-resolved per request via
//  `resolvedMTPDraftStrategy(...)`; values here persist and validate.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct MTPSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    /// What the engine ACTUALLY resolved for each loaded model, captured at
    /// that model's load. Not derived from `draft` — a second, independent
    /// derivation in the UI could disagree with the one the engine ran, and
    /// the user would have no way to tell which was real.
    @State private var loadedModels: [ModelRuntime.ModelCacheSummary] = []

    /// By-WEIGHT MTP capability for models still loading, so the detector
    /// shows during warmup instead of only after it resolves. Populated
    /// off-main from `MTPBundleInspector.inspect` (weights, not config —
    /// configs lie: JANG_1L has no `mtp` field; a 27B index omitted its 31
    /// mtp.* tensors). Scoped to the Flash-Next/27B families the MTP controls
    /// target.
    @State private var loadingMTP: [ModelRuntime.LoadingModelMTPStatus] = []
    /// Memo so a loading bundle's headers are read once, not every 2s poll.
    @State private var mtpInspectCache: [String: ModelRuntime.LoadingModelMTPStatus] = [:]

    /// Metadata for the currently selected drafter folder, re-read
    /// whenever the path changes. `nil` when nothing is selected or the
    /// folder is not a DFlash 2 drafter.
    private var drafterInfo: VMLXDFlash2DrafterInfo? {
        guard let path = draft.mtp.dflash2DrafterPath, !path.isEmpty else { return nil }
        return VMLXDFlash2DrafterInfo.read(at: URL(fileURLWithPath: path))
    }

    /// Where the matching drafter is published. Shown only until one is
    /// selected, so the first-run path is "download, then choose folder"
    /// rather than "go find this yourself".
    static let drafterDownloadURL = URL(
        string: "https://huggingface.co/incoai/Qwen3.8-27B-DFlash2")!

    private var drafterProblem: String? {
        guard let path = draft.mtp.dflash2DrafterPath, !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            return L("That folder no longer exists.")
        }
        if drafterInfo == nil {
            return L("Not a DFlash 2 drafter — no selector in its config.json.")
        }
        return nil
    }

    var body: some View {
        ServerSettingsCard(
            section: .speculative,
            status: .engineReady,
            blurb:
                "Draft tokens with a fast helper model and verify with the main model in a single step. Engaged per request when the model supports it."
        ) {
            SettingsField(
                label: "Mode",
                hint:
                    "Off disables the model's native MTP head. Auto uses it only when the model ships a verified head; Force-On requires it. A selected DFlash 2 drafter drafts regardless of Mode — remove it below to stop."
            ) {
                Picker("", selection: $draft.mtp.mode) {
                    ForEach(VMLXMTPServerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            OptionalIntField(
                label: "Draft Tokens Per Step",
                placeholder: "Blank = engine recommendation",
                help: "How many tokens the draft model proposes before the main model verifies.",
                value: $draft.mtp.draftTokenLimit
            )

            SettingsToggle(
                title: L("Keep Draft Cache Separate"),
                description: "Engine invariant. Disabling produces a validation error.",
                isOn: $draft.mtp.keepDraftCacheSeparate
            )

            SettingsToggle(
                title: L("Only Accepted Tokens Enter Base Cache"),
                description: "Engine invariant. Disabling produces a validation error.",
                isOn: $draft.mtp.acceptedTokensOnlyEnterBaseCache
            )

            SettingsField(
                label: "DFlash 2 Drafter",
                hint:
                    "A downloaded block-diffusion drafter drafts a whole block per step instead of one token. Applies to Qwen 3.8 only — the drafter is trained against that target's hidden states, so a mismatched bundle is ignored and every other model keeps its own decode path. When it does fit, it REPLACES the native MTP head."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(drafterInfo == nil ? L("Choose Folder…") : L("Change…")) {
                            chooseDrafterFolder()
                        }
                        .buttonStyle(.bordered)

                        if drafterInfo == nil {
                            Link(
                                L("Download drafter…"),
                                destination: Self.drafterDownloadURL
                            )
                            .font(.system(size: 11))
                        }

                        if draft.mtp.dflash2DrafterPath?.isEmpty == false {
                            Button(L("Remove")) {
                                draft.mtp.dflash2DrafterPath = nil
                                draft.mtp.dflash2BlockSize = nil
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let path = draft.mtp.dflash2DrafterPath, !path.isEmpty {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let problem = drafterProblem {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(problem).font(.system(size: 11))
                        }
                        .foregroundColor(theme.errorColor)
                    } else if let info = drafterInfo {
                        Text(info.summary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    } else {
                        Text(
                            L(
                                "None selected — speculation falls back to the model's own MTP head, per Mode above."
                            )
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            SettingsDivider()

            SettingsSubsection(label: "Resolved Per Loaded Model") {
                resolvedStateRows
            }
        }
        .task {
            while !Task.isCancelled {
                loadedModels = await ModelRuntime.shared.cachedModelSummaries()
                // Early, by-WEIGHT MTP detection for in-flight loads so the
                // detector appears during warmup. File-only inspection runs
                // off-main (a heavy load never stalls the UI) and is memoized
                // per bundle. Restricted to the Flash-Next/27B families.
                let loadingNames = await ModelRuntime.shared.loadingModelNames()
                let cache = mtpInspectCache
                let inspected: [ModelRuntime.LoadingModelMTPStatus] =
                    loadingNames.isEmpty
                    ? []
                    : await Task.detached {
                        loadingNames.compactMap { name in
                            cache[name] ?? ModelRuntime.inspectLoadingModelMTP(name: name)
                        }
                    }.value
                for status in inspected { mtpInspectCache[status.name] = status }
                // Resolved rows take over the moment the engine reports them;
                // only target-family loads surface early.
                let resolvedNames = Set(loadedModels.map(\.name))
                loadingMTP = inspected.filter {
                    $0.isTargetMTPFamily && !resolvedNames.contains($0.name)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - What the engine actually resolved

    /// Mode is a REQUEST, not a result. A bundle whose tuning artifact never
    /// asserted `output_equivalent` cannot run speculative decoding even on
    /// Force-On — correctly, since that assertion IS the output-equivalence
    /// proof — and a Draft-Tokens limit can only lower the artifact's depth,
    /// never raise it. Both are right, and both were previously invisible: the
    /// picker looked inert and the reason, already computed at load and
    /// already written to the log, reached nobody.
    private var resolvedStateRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Models still warming: by-WEIGHT detection shown NOW, so the
            // section is never blank for the whole multi-minute load. The
            // resolved row replaces this the moment the engine reports it.
            ForEach(loadingMTP, id: \.name) { model in
                resolvedRow(
                    label: model.name,
                    value: model.bundleHasMTP
                        ? (model.isBlocked
                            ? "MTP head detected · blocked by tuning"
                            : (model.measuredFamilyAutoDepth.map {
                                "MTP head detected · auto depth \($0)"
                            } ?? "MTP head detected"))
                        : "No MTP head",
                    detail: "Warming up — \(model.statusLine)"
                )
            }
            if loadedModels.isEmpty && loadingMTP.isEmpty {
                resolvedRow(
                    label: "Resolved state",
                    value: "No model loaded",
                    detail:
                        "Speculative decoding is resolved at model load. Load a model to see what it settled on."
                )
            } else if loadedModels.isEmpty {
                EmptyView()
            } else {
                ForEach(loadedModels, id: \.name) { model in
                    resolvedRow(
                        label: model.name,
                        value: Self.resolvedValue(
                            depth: model.nativeMTPDepth,
                            strategy: model.draftStrategyDescription,
                            dflash2BlockSize: model.dflash2BlockSize),
                        detail: model.nativeMTPReason ?? model.nativeMTPStatus
                            ?? "Captured at this model's last load."
                    )
                }
            }
        }
    }

    /// "MTP depth 2" when it is live, otherwise the drafter that replaced it,
    /// otherwise a plain "Off" — never blank. A missing line is
    /// indistinguishable from a broken readout.
    static func resolvedValue(
        depth: Int?,
        strategy: String?,
        dflash2BlockSize: Int? = nil
    ) -> String {
        if let depth, depth > 0 { return "MTP depth \(depth)" }
        if let strategy, strategy != "none", !strategy.isEmpty {
            // Name the width. "dflash2" alone cannot distinguish a run at the
            // checkpoint's trained width from one pinned by Draft Tokens Per
            // Step, which is the whole point of that control.
            if let block = dflash2BlockSize, block > 0 {
                return "\(strategy) block \(block)"
            }
            return strategy
        }
        return "Off"
    }

    private func resolvedRow(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// AppKit `NSOpenPanel` rather than SwiftUI `.fileImporter`, matching
    /// the rest of Settings — the SwiftUI importer misbehaves in this
    /// window's presentation context.
    private func chooseDrafterFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L("Select a downloaded DFlash 2 drafter folder")
        panel.prompt = L("Select")
        if let existing = draft.mtp.dflash2DrafterPath, !existing.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: existing).deletingLastPathComponent()
        }

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            // The path is stored even when the folder turns out not to be
            // a drafter, so the pane can explain what is wrong instead of
            // silently discarding what the user picked.
            draft.mtp.dflash2DrafterPath = url.path
            draft.mtp.dflash2BlockSize = nil
        }
    }
}
