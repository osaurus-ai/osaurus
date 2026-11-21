//
//  ImageCatalogSource.swift
//  osaurus
//
//  Image models: installed mflux bundles plus the OsaurusAI image catalog.
//  Catalog builds fold into one row per model until one is on this Mac; each
//  installed bundle keeps its own row, since requests name its exact folder.
//  Installed bundles open the generate / edit / upscale panel.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ImageCatalogSource: LocalModelCatalogSource {
    private let downloads = ImageModelDownloadService.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var didActivate = false

    /// Installed bundle paired with its source repo, captured once per scan
    /// so building rows does no filesystem reads.
    private struct Installed {
        let info: ImageModelInfo
        let repoId: String?
    }

    private var installed: [Installed] = []
    private var didScanInstalled = false
    /// Download sizes for catalog rows, resolved lazily off the HF tree API.
    private var sizes: [String: Int64] = [:]
    private var sizeTask: Task<Void, Never>?

    init() {
        super.init(kind: .image)
    }

    override var supportsImport: Bool { true }
    override var landingAnchorId: String? { "imageGeneration.upscale" }
    override var refreshHelp: String? { "Refresh image models from Hugging Face" }
    override var isRefreshing: Bool { downloads.isLoadingCatalog }
    override func refresh() {
        Task { await downloads.refreshCatalog() }
    }

    override func activate() {
        guard !didActivate else { return }
        didActivate = true
        isLoading = true
        downloads.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .localModelsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.scanInstalled() } }
            .store(in: &subscriptions)
        Task {
            async let scan: Void = scanInstalled()
            async let catalog: Void = downloads.refreshCatalog()
            _ = await (scan, catalog)
            rebuild()
        }
    }

    private func scanInstalled() async {
        let models = (try? await ImageGenerationService.shared.availableModels()) ?? []
        let ids = models.map(\.id)
        let marked = await Task.detached(priority: .userInitiated) {
            ids.reduce(into: [String: String]()) { result, id in
                result[id] = ImageModelDownloadService.markedSourceRepoId(for: id)
            }
        }.value
        installed = models.map {
            Installed(info: $0, repoId: downloads.sourceRepoId(for: $0.id, marked: marked[$0.id]))
        }
        didScanInstalled = true
        rebuild()
    }

    private func rebuild() {
        let installedIds = Set(installed.map(\.info.id))
        let catalog = downloads.fetchedCatalog
        let families = makeFamilies(catalog: catalog)
        var rows = installed.map { item(for: $0, family: families.byKey[Self.familyKey($0.info.id)]) }
        for family in families.ordered {
            let downloadable = family.entries.filter { !installedIds.contains($0.id) }
            let active = downloadable.filter { status($0.id, installed: false).isActive }
            rows += active.map { item(for: $0, family: family, isFamilyRow: false) }
            guard family.installed.isEmpty, active.isEmpty else { continue }
            // A failed download stays visible on the row; otherwise the
            // build that suits this Mac stands for the model.
            let failed = downloadable.first { status($0.id, installed: false).isFailed }
            guard let representative = failed ?? downloadable.first(where: { $0.id == family.recommendedId })
                ?? downloadable.first
            else { continue }
            rows.append(item(for: representative, family: family, isFamilyRow: true))
        }
        items = rows
        // Installed bundles come from a disk scan; until it lands, the
        // curated rows alone would read as the whole list.
        isLoading = !didScanInstalled || (items.isEmpty && downloads.isLoadingCatalog)
        resolveSizes(for: catalog.filter { !installedIds.contains($0.id) })
    }

    /// One rebuild once every size is in: a cache hit returns without
    /// suspending, so a rebuild per repo ran back to back on the main thread.
    private func resolveSizes(for entries: [ImageModelDownload]) {
        let missing = entries.filter { sizes[$0.repoId] == nil }
        guard !missing.isEmpty, sizeTask == nil else { return }
        sizeTask = Task { [weak self] in
            var resolved: [String: Int64] = [:]
            for entry in missing {
                guard let self, !Task.isCancelled else { return }
                let bytes = await self.downloads.estimateDownloadSize(repoId: entry.repoId) ?? 0
                resolved[entry.repoId] = max(bytes, 0)
            }
            guard let self else { return }
            self.sizes.merge(resolved) { _, new in new }
            self.sizeTask = nil
            self.rebuild()
        }
    }

    // MARK: Families

    /// Every build of one model: catalog downloads (across mirrors) and
    /// bundles already on this Mac.
    private struct Family {
        let key: String
        let name: String
        let entries: [ImageModelDownload]
        let installed: [Installed]
        /// Best first.
        let versions: [ImageModelCatalogNaming.Version]
        let recommendedId: String?

        func framing(for id: String) -> String? {
            guard let index = versions.firstIndex(where: { $0.id == id }) else { return nil }
            return ModelVersionFraming.label(index: index, count: versions.count)
        }
    }

    private static func familyKey(_ id: String) -> String {
        ImageModelCatalogNaming.parse(id).familyKey
    }

    /// Families in catalog order, then installed-only ones.
    private func makeFamilies(catalog: [ImageModelDownload]) -> (ordered: [Family], byKey: [String: Family]) {
        var order: [String] = []
        var entriesByKey: [String: [ImageModelDownload]] = [:]
        for entry in catalog {
            let key = Self.familyKey(entry.repoId)
            if entriesByKey[key] == nil { order.append(key) }
            entriesByKey[key, default: []].append(entry)
        }
        var installedByKey: [String: [Installed]] = [:]
        for model in installed {
            let key = Self.familyKey(model.info.id)
            if entriesByKey[key] == nil, installedByKey[key] == nil { order.append(key) }
            installedByKey[key, default: []].append(model)
        }
        let memoryGB = SystemMonitorService.shared.totalMemoryGB
        var byKey: [String: Family] = [:]
        let ordered = order.map { key -> Family in
            let entries = entriesByKey[key] ?? []
            let installed = installedByKey[key] ?? []
            var versions: [ImageModelCatalogNaming.Version] = installed.map {
                .init(
                    id: $0.info.id,
                    bits: $0.info.quantizationBits ?? ImageModelCatalogNaming.parse($0.info.id).bits,
                    sizeBytes: $0.info.totalBytes > 0 ? Int64($0.info.totalBytes) : nil
                )
            }
            let installedIds = Set(installed.map(\.info.id))
            for entry in entries where !versions.contains(where: { $0.id == entry.id }) {
                let version = ImageModelCatalogNaming.Version(
                    id: entry.id,
                    bits: ImageModelCatalogNaming.parse(entry.repoId).bits,
                    sizeBytes: sizes[entry.repoId].flatMap { $0 > 0 ? $0 : nil }
                )
                // Mirrors of one build list once: the copy on this Mac, else OsaurusAI's.
                if let bits = version.bits, let index = versions.firstIndex(where: { $0.bits == bits }) {
                    if !installedIds.contains(versions[index].id), entry.repoId.hasPrefix("OsaurusAI/") {
                        versions[index] = version
                    }
                    continue
                }
                versions.append(version)
            }
            let family = Family(
                key: key,
                name: ImageModelCatalogNaming.parse(entries.first?.repoId ?? installed.first?.info.id ?? key).displayName,
                entries: entries,
                installed: installed,
                versions: ImageModelCatalogNaming.bestFirst(versions),
                recommendedId: ImageModelCatalogNaming.recommendedId(versions, physicalMemoryGB: memoryGB)
            )
            byKey[key] = family
            return family
        }
        return (ordered, byKey)
    }

    /// The panel's version list; each build not on this Mac downloads from it.
    private func versionList(_ family: Family?, currentId: String) -> [LocalModelCatalogItem.Version] {
        guard let family, family.versions.count > 1 else { return [] }
        let installedIds = Set(family.installed.map(\.info.id))
        let downloads = downloads
        return family.versions.map { version in
            let entry = family.entries.first { $0.id == version.id }
            let isInstalled = installedIds.contains(version.id)
            let status = status(version.id, installed: isInstalled)
            var row = LocalModelCatalogItem.Version(
                id: version.id,
                framing: family.framing(for: version.id),
                label: Self.versionLabel(id: version.id, bits: version.bits),
                technicalName: entry?.repoId ?? version.id,
                sizeText: version.sizeBytes.map(LocalModelCatalogFormat.bytes),
                isRecommended: version.id == family.recommendedId,
                status: status,
                isCurrent: version.id == currentId
            )
            if let entry, status == .available || status.isFailed {
                row.action = .init(
                    title: status == .available ? "Download" : "Retry",
                    icon: "arrow.down.circle",
                    role: .primary
                ) { downloads.download(entry) }
            }
            return row
        }
    }

    // MARK: Rows

    private func status(_ id: String, installed: Bool) -> LocalModelCatalogItem.Status {
        switch downloads.states[id] ?? .notStarted {
        case .downloading(let progress), .paused(let progress):
            return .inProgress(progress: progress, detail: downloads.metrics[id]?.formattedLine, isPaused: false)
        case .failed(let error):
            return installed ? .installed : .failed(error)
        case .completed, .notStarted:
            return installed ? .installed : .available
        }
    }

    private func item(for model: Installed, family: Family?) -> LocalModelCatalogItem {
        let info = model.info
        let fullLicense = ImageModelRequestPolicy.licenseLabel(canonical: info.canonicalName)
        let capability = Self.capabilityLabel(info)
        let version = Self.versionText(
            framing: family?.framing(for: info.id),
            label: Self.versionLabel(id: info.id, bits: info.quantizationBits)
        )
        let size = info.totalBytes > 0 ? Int64(info.totalBytes) : nil
        let name = family?.name ?? ImageModelCatalogNaming.parse(info.id).displayName

        var item = LocalModelCatalogItem(
            id: info.id,
            name: name,
            subtitle: [capability, version].compactMap { $0 }.joined(separator: " · "),
            description: info.ready ? "" : info.blockedReasons.joined(separator: "\n"),
            icon: info.capabilities.upscale ? "arrow.up.left.and.arrow.down.right" : "photo",
            sizeText: size.map(LocalModelCatalogFormat.bytes),
            sizeBytes: size,
            status: status(info.id, installed: true),
            huggingFaceRepo: model.repoId,
            facts: Self.facts(
                capability: capability, version: version, license: fullLicense, size: size,
                source: model.repoId ?? info.id),
            searchHaystack: LocalModelCatalogFormat.haystack(
                [name, info.displayName, info.id, model.repoId, fullLicense, capability, version, "mflux"])
        )
        item.versions = versionList(family, currentId: info.id)
        if !info.ready {
            item.badges.append(.init(text: L("Not ready"), tone: .warning, help: info.blockedReasons.first))
        }
        if let chip = ImageModelRequestPolicy.shortLicenseLabel(canonical: info.canonicalName) {
            item.badges.append(.init(text: chip, tone: .neutral, help: fullLicense))
        }

        let downloads = downloads
        let isEdit = !info.capabilities.textToImage && info.capabilities.imageEdit
        if info.ready, info.capabilities.textToImage || info.capabilities.imageEdit || info.capabilities.upscale {
            item.primaryAction = .init(
                title: info.capabilities.upscale ? "Upscale" : (isEdit ? "Edit" : "Generate"),
                icon: isEdit ? "wand.and.stars" : "sparkles"
            ) { [weak self] in self?.openPanel(info, isEdit: isEdit) }
            if info.capabilities.textToImage, info.capabilities.imageEdit {
                item.menuActions.append(.init(title: "Edit", icon: "wand.and.stars") { [weak self] in
                    self?.openPanel(info, isEdit: true)
                })
            }
        }
        if let repo = model.repoId {
            let redownload = LocalModelCatalogItem.Action(title: "Re-download", icon: "arrow.clockwise") {
                downloads.download(repoId: repo, displayName: info.displayName)
            }
            if info.ready { item.menuActions.append(redownload) } else { item.primaryAction = redownload }
        }
        item.menuActions.append(.init(
            title: "Delete Model", icon: "trash", role: .destructive,
            confirmation: L("This removes \(name) from this Mac. You can download it again later.")
        ) { downloads.delete(info.id) })
        item.onCancel = { downloads.cancel(info.id) }
        return item
    }

    /// A download: the model's row while nothing of it is on this Mac
    /// (`isFamilyRow`), or one build's row while it downloads.
    private func item(for entry: ImageModelDownload, family: Family, isFamilyRow: Bool) -> LocalModelCatalogItem {
        let canonical = ImageModelRequestPolicy.catalogCanonical(entry.id)
        let fullLicense = ImageModelRequestPolicy.licenseLabel(canonical: canonical)
        let capability = Self.capabilityLabel(
            ImageModelRequestPolicy.capabilities(kind: entry.isEditOnly ? "imageEdit" : "imageGen", canonical: canonical))
        let label = Self.versionLabel(id: entry.repoId, bits: nil)
        let version = Self.versionText(framing: family.framing(for: entry.id), label: label)
        let size = sizes[entry.repoId].flatMap { $0 > 0 ? $0 : nil }
        let status = status(entry.id, installed: false)
        let count = family.versions.count
        let rowDetail = isFamilyRow && count > 1 ? L("\(count) versions") : version

        var item = LocalModelCatalogItem(
            id: entry.id,
            name: family.name,
            subtitle: [capability, rowDetail].compactMap { $0 }.joined(separator: " · "),
            icon: "photo",
            sizeText: size.map(LocalModelCatalogFormat.bytes),
            sizeBytes: size,
            status: status,
            huggingFaceRepo: entry.repoId,
            facts: Self.facts(capability: capability, version: version, license: fullLicense, size: size, source: entry.repoId),
            searchHaystack: LocalModelCatalogFormat.haystack(
                [family.name, capability, fullLicense, "mflux"] + family.entries.map(\.repoId))
        )
        item.versions = versionList(family, currentId: entry.id)
        if let chip = ImageModelRequestPolicy.shortLicenseLabel(canonical: canonical) {
            item.badges.append(.init(text: chip, tone: .neutral, help: fullLicense))
        }
        let downloads = downloads
        item.primaryAction = .init(
            title: status == .available ? "Download" : "Retry",
            icon: "arrow.down.circle",
            role: .primary
        ) { downloads.download(entry) }
        item.onCancel = { downloads.cancel(entry.id) }
        return item
    }

    private func openPanel(_ info: ImageModelInfo, isEdit: Bool) {
        sheetRequest = SheetRequest(id: info.id) {
            AnyView(
                ImageGenerationPanelView(
                    modelId: info.id,
                    displayName: info.displayName,
                    isEdit: isEdit,
                    modelInfo: info
                )
            )
        }
    }

    // MARK: Labels

    private static func facts(
        capability: String?,
        version: String?,
        license: String?,
        size: Int64?,
        source: String?
    ) -> [LocalModelCatalogItem.Fact] {
        var facts: [LocalModelCatalogItem.Fact] = []
        if let capability { facts.append(.init(label: "Type", value: capability)) }
        if let version { facts.append(.init(label: "Version", value: version)) }
        if let size { facts.append(.init(label: "Size", value: LocalModelCatalogFormat.bytes(size))) }
        if let license { facts.append(.init(label: "License", value: license)) }
        if let source { facts.append(.init(label: "Source", value: source)) }
        return facts
    }

    private static func capabilityLabel(_ info: ImageModelInfo) -> String? {
        if info.kind == "videoGen" { return L("Create videos") }
        return capabilityLabel(info.capabilities)
    }

    private static func capabilityLabel(_ capabilities: ImageModelCapabilities) -> String? {
        if capabilities.upscale { return L("Upscale images") }
        switch (capabilities.textToImage, capabilities.imageEdit) {
        case (true, true): return L("Create and edit images")
        case (true, false): return L("Create images")
        case (false, true): return L("Edit images")
        case (false, false): return nil
        }
    }

    /// Explicit bit width when known, else parsed from the repo or bundle name.
    private static func versionLabel(id: String, bits: Int?) -> String? {
        bits.map { "\($0)-bit" } ?? ImageModelCatalogNaming.parse(id).versionLabel
    }

    /// "Best quality (8-bit)"; whichever half is known when only one is.
    private static func versionText(framing: String?, label: String?) -> String? {
        switch (framing, label) {
        case let (framing?, label?): return "\(framing) (\(label))"
        default: return framing ?? label
        }
    }
}
