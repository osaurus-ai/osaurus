//
//  ExternalModelsSettingsView.swift
//  osaurus
//
//  Settings controls for discovering and running models that already live
//  on this Mac via other tools: the Hugging Face Hub cache, LM Studio, and
//  user-selected model folders. Toggling a source on/off triggers a
//  background rescan; discovered models appear in the catalog and run in
//  place (never copied or modified).
//

import SwiftUI

struct ExternalModelsSettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(ExternalModelLocator.importHFCacheDefaultsKey)
    private var importHFCache: Bool = true

    @AppStorage(ExternalModelLocator.importLMStudioDefaultsKey)
    private var importLMStudio: Bool = true

    @AppStorage(ExternalModelLocator.customHFCachePathDefaultsKey)
    private var customHFCachePath: String = ""

    @State private var hfCount: Int = 0
    @State private var lmStudioCount: Int = 0
    @State private var customFolderCount: Int = 0
    @State private var scanReport: ExternalModelLocator.ScanReport?
    @State private var isScanning: Bool = false
    @State private var needsRescanAfterCurrent: Bool = false
    @State private var pathRescanTask: Task<Void, Never>?
    @State private var showHFCachePicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsToggle(
                title: "Hugging Face cache and model folder",
                description:
                    "Use MLX models from ~/.cache/huggingface, HF_HOME / HF_HUB_CACHE, or a custom folder.",
                badge:
                    importHFCache && hfCount + customFolderCount > 0
                    ? "\(hfCount + customFolderCount)" : nil,
                isOn: $importHFCache
            )

            if importHFCache {
                hfCachePathControl
            }

            SettingsToggle(
                title: "LM Studio",
                description: "Use safetensors models from your LM Studio library.",
                badge: importLMStudio && lmStudioCount > 0 ? "\(lmStudioCount)" : nil,
                isOn: $importLMStudio
            )

            HStack(spacing: theme.space.s8) {
                if isScanning {
                    SettingsSpinner(size: .mini)
                    Text("Scanning…", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                } else {
                    let count = hfCount + lmStudioCount + customFolderCount
                    Text(
                        count == 1 ? L("1 external model found") : L("\(count) external models found")
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                }

                Spacer()

                SettingsButton(.secondary, "Rescan", icon: "arrow.clockwise", isLoading: isScanning, size: .compact) {
                    rescan()
                }
                .disabled(isScanning)
            }

            if let scanReport, !scanReport.skipped.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .glyphSize(.micro, weight: .semibold)
                            .foregroundColor(theme.status.warning.foreground)
                        let count = scanReport.skipped.count
                        Text(
                            count == 1
                                ? L("1 external candidate skipped")
                                : L("\(count) external candidates skipped")
                        )
                        .textStyle(.footnote, weight: 500)
                        .foregroundColor(theme.text.secondary)
                    }

                    ForEach(Array(scanReport.skipped.prefix(3).enumerated()), id: \.offset) { _, item in
                        Text(skippedSummary(item))
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, theme.space.s2)
            }
        }
        .onAppear { refreshCounts() }
        .onChange(of: importHFCache) { _, _ in rescan() }
        .onChange(of: importLMStudio) { _, _ in rescan() }
        .onChange(of: customHFCachePath) { _, _ in schedulePathRescan() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            refreshCounts()
        }
        .fileImporter(
            isPresented: $showHFCachePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                customHFCachePath = url.path
            }
        }
    }

    private var hfCachePathControl: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text("Cache or model folder path", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)

            HStack(spacing: theme.space.s8) {
                SettingsTextField(
                    placeholder: defaultHFCacheDisplayPath,
                    text: $customHFCachePath,
                    monospaced: true,
                    onSubmit: rescan
                )

                SettingsIconButton(
                    "folder.badge.gearshape",
                    help: "Choose Hugging Face cache or model folder",
                    size: .compact
                ) {
                    showHFCachePicker = true
                }

                if !customHFCachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsIconButton(
                        "arrow.counterclockwise",
                        help: "Use default Hugging Face cache locations",
                        size: .compact
                    ) {
                        customHFCachePath = ""
                    }
                }
            }

            Text(
                "Empty scans ~/models, HF_HUB_CACHE, HF_HOME/hub, and ~/.cache/huggingface/hub.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, theme.space.s8)
    }

    private func refreshCounts() {
        Task.detached(priority: .utility) {
            let models = ExternalModelLocator.models()
            let report = ExternalModelLocator.lastScanReport()
            let hf = models.filter {
                $0.externalSource == ExternalModelLocator.Source.huggingFaceCache.rawValue
            }.count
            let lmStudio = models.filter {
                $0.externalSource == ExternalModelLocator.Source.lmStudio.rawValue
            }.count
            let custom = models.filter {
                $0.externalSource == ExternalModelLocator.Source.customModelFolder.rawValue
            }.count
            await MainActor.run {
                self.scanReport = report
                self.hfCount = hf
                self.lmStudioCount = lmStudio
                self.customFolderCount = custom
            }
        }
    }

    private func rescan() {
        pathRescanTask?.cancel()
        guard !isScanning else {
            needsRescanAfterCurrent = true
            return
        }

        isScanning = true
        Task.detached(priority: .utility) {
            ExternalModelLocator.rescan()
            await MainActor.run {
                self.isScanning = false
                self.refreshCounts()
                if self.needsRescanAfterCurrent {
                    self.needsRescanAfterCurrent = false
                    self.rescan()
                }
            }
        }
    }

    private func schedulePathRescan() {
        pathRescanTask?.cancel()
        pathRescanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            rescan()
        }
    }

    private func skippedSummary(_ item: ExternalModelLocator.Skipped) -> String {
        let name = item.repoId ?? URL(fileURLWithPath: item.path).lastPathComponent
        return "\(name): \(item.reason.title)"
    }

    private var defaultHFCacheDisplayPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
