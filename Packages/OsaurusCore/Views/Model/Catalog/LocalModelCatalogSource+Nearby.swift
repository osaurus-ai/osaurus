//
//  LocalModelCatalogSource+Nearby.swift
//  osaurus
//
//  What every kind's catalog shows about Macs on this network: which rows a
//  nearby Mac shares (an "On <Mac>" badge, a Source fact, and Download from
//  that Mac), rows for shared models the catalog doesn't list, and Share on
//  This Network / Stop Sharing on installed rows.
//

import Combine
import SwiftUI

extension LocalModelCatalogSource {
    /// Calls `rebuild` when nearby hosts or sharing choices change. Call
    /// from `activate`.
    func observeNearby(_ rebuild: @escaping () -> Void) {
        nearbySubscription = ModelShareService.shared.objectWillChange
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { _ in rebuild() }
    }

    /// `rows` with nearby offers merged in.
    ///
    /// - Parameters:
    ///   - localIds: the share ids (`ShareableModel.localId`) a row stands
    ///     for, first the one sharing would publish; empty for rows that
    ///     can't be shared or matched.
    ///   - repoId: the row's Hugging Face repo, which also matches an offer.
    ///   - addsUnlisted: add a row for each shared model no row matches.
    ///   - download: starts a download from the offer's Mac; the row is nil
    ///     for an added row.
    ///   - decorate: sets an added row's progress from the kind's manager.
    func mergingNearby(
        _ rows: [LocalModelCatalogItem],
        localIds: (LocalModelCatalogItem) -> [String],
        repoId: (LocalModelCatalogItem) -> String? = { $0.huggingFaceRepo },
        addsUnlisted: Bool = true,
        download: @escaping (NearbyOffer, LocalModelCatalogItem?) -> Void,
        decorate: (inout LocalModelCatalogItem, NearbyOffer) -> Void = { _, _ in }
    ) -> [LocalModelCatalogItem] {
        let service = ModelShareService.shared
        let shareKind = ModelShareKind(kind)
        let offers = service.offers(kind: shareKind)
        var claimed = Set<String>()

        var merged = rows.map { original -> LocalModelCatalogItem in
            var row = original
            let ids = localIds(row)
            guard let primaryId = ids.first else { return row }

            if row.status == .installed {
                let shareId = ShareableModel.id(kind: shareKind, localId: primaryId)
                if service.isShared(shareId) {
                    row.badges.append(
                        .init(
                            text: L("Shared"),
                            tone: .accent,
                            icon: "dot.radiowaves.left.and.right",
                            help: L("Macs on this network can copy this model.")
                        )
                    )
                    row.menuActions.append(
                        .init(title: "Stop Sharing", icon: "xmark.circle") { service.setShared(shareId, false) }
                    )
                } else {
                    row.menuActions.append(
                        .init(title: "Share on This Network", icon: "dot.radiowaves.left.and.right") {
                            service.setShared(shareId, true)
                        }
                    )
                }
                if let host = service.uncheckedCopies[primaryId.lowercased()] {
                    row.badges.append(
                        .init(
                            text: L("Not Checked"),
                            tone: .warning,
                            icon: "exclamationmark.shield",
                            help: L(
                                "Copied from \(host) while Hugging Face couldn't be reached, so its files were checked only against that Mac's list. Repair checks them against Hugging Face."
                            )
                        )
                    )
                }
            }

            let rowRepo = repoId(row)
            let matching = offers.filter { offer in
                ids.contains { offer.matches(kind: shareKind, localId: $0, repoId: rowRepo) }
            }
            guard !matching.isEmpty else { return row }
            claimed.formUnion(matching.map(\.id))
            let hosts = Self.hostNames(matching)
            row.nearbyHosts = hosts
            row.facts.append(.init(label: "Source", value: hosts.joined(separator: ", ")))
            guard !row.status.isOnThisMac else { return row }
            row.badges.append(Self.nearbyBadge(hosts))
            let offer = matching[0]
            let target = original
            row.primaryAction = .init(
                title: row.status == .available ? "Download" : "Retry",
                icon: "arrow.down.circle",
                role: .primary
            ) { download(offer, target) }
            return row
        }

        guard addsUnlisted else { return merged }
        var groups: [String: [NearbyOffer]] = [:]
        var order: [String] = []
        for offer in offers where !claimed.contains(offer.id) {
            let key = offer.localId.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(offer)
        }
        for key in order {
            guard let group = groups[key], let offer = group.first else { continue }
            let hosts = Self.hostNames(group)
            var row = LocalModelCatalogItem(
                id: "nearby:\(offer.model.id)",
                name: offer.model.name,
                subtitle: offer.model.repoId ?? kind.title,
                description: L("Shared by \(hosts.joined(separator: ", ")) on this network."),
                icon: kind.icon,
                badges: [Self.nearbyBadge(hosts)],
                sizeText: LocalModelCatalogFormat.bytes(offer.totalBytes),
                sizeBytes: offer.totalBytes,
                status: .available,
                huggingFaceRepo: offer.model.repoId,
                facts: [
                    .init(label: "Source", value: hosts.joined(separator: ", ")),
                    .init(label: "Files", value: "\(offer.model.files.count)"),
                ],
                searchHaystack: LocalModelCatalogFormat.haystack([
                    offer.model.name, offer.model.repoId, offer.localId, hosts.joined(separator: " "),
                ]),
                nearbyHosts: hosts
            )
            row.primaryAction = .init(title: "Download", icon: "arrow.down.circle", role: .primary) {
                download(offer, nil)
            }
            decorate(&row, offer)
            merged.append(row)
        }
        return merged
    }

    private static func hostNames(_ offers: [NearbyOffer]) -> [String] {
        var seen = Set<String>()
        return offers.map(\.hostName).filter { seen.insert($0).inserted }
    }

    private static func nearbyBadge(_ hosts: [String]) -> LocalModelCatalogItem.Badge {
        .init(
            text: L("On \(hosts[0])"),
            tone: .accent,
            icon: "desktopcomputer",
            help: L("Downloads copy this model from \(hosts.joined(separator: ", ")) on this network.")
        )
    }
}

extension LocalModelCatalogItem.Status {
    /// A download state from `ModelDownloadService`, for rows the source
    /// builds itself; nil when nothing is in flight.
    static func nearbyProgress(_ state: DownloadState?) -> Self? {
        switch state {
        case .downloading(let progress): return .inProgress(progress: progress, detail: nil, isPaused: false)
        case .paused(let progress): return .inProgress(progress: progress, detail: nil, isPaused: true)
        case .failed(let error): return .failed(error)
        default: return nil
        }
    }
}
