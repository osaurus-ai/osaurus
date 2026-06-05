//
//  ExternalModelsSettingsView.swift
//  osaurus
//
//  Settings controls for discovering and running models that already live
//  on this Mac via other tools — the Hugging Face Hub cache and LM Studio.
//  Toggling a source on/off triggers a background rescan; discovered models
//  appear in the catalog and run in place (never copied or modified).
//

import SwiftUI

struct ExternalModelsSettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(ExternalModelLocator.importHFCacheDefaultsKey)
    private var importHFCache: Bool = true

    @AppStorage(ExternalModelLocator.importLMStudioDefaultsKey)
    private var importLMStudio: Bool = true

    @State private var hfCount: Int = 0
    @State private var lmStudioCount: Int = 0
    @State private var isScanning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Discover and run models already on this Mac from other tools. Osaurus references these files in place and never copies, modifies, or deletes them.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            SettingsToggle(
                title: L("Hugging Face cache"),
                description:
                    "Use MLX models from ~/.cache/huggingface (and HF_HOME / HF_HUB_CACHE).",
                badge: importHFCache && hfCount > 0 ? "\(hfCount)" : nil,
                isOn: $importHFCache
            )

            SettingsToggle(
                title: L("LM Studio"),
                description: "Use safetensors models from your LM Studio library.",
                badge: importLMStudio && lmStudioCount > 0 ? "\(lmStudioCount)" : nil,
                isOn: $importLMStudio
            )

            HStack(spacing: 8) {
                if isScanning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Scanning…", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("\(hfCount + lmStudioCount) external models found", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                Button(action: { rescan() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Rescan", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isScanning)
            }
        }
        .onAppear { refreshCounts() }
        .onChange(of: importHFCache) { _, _ in rescan() }
        .onChange(of: importLMStudio) { _, _ in rescan() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            refreshCounts()
        }
    }

    private func refreshCounts() {
        let models = ExternalModelLocator.models()
        hfCount =
            models.filter {
                $0.externalSource == ExternalModelLocator.Source.huggingFaceCache.rawValue
            }.count
        lmStudioCount =
            models.filter {
                $0.externalSource == ExternalModelLocator.Source.lmStudio.rawValue
            }.count
    }

    private func rescan() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            ExternalModelLocator.rescan()
            await MainActor.run {
                self.isScanning = false
                self.refreshCounts()
            }
        }
    }
}
