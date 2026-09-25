import Foundation

struct ModelManifestCheck: Sendable {
    enum Status: Equatable, Sendable {
        case unavailable, invalidLocal, unversionedPublisher, verificationRequired
        case current, updateAvailable, installedNewer
    }

    let local: ModelManifest.Local
    let remote: HuggingFaceService.ManifestSnapshot?
    let error: String?
    let checkedAt: Date

    var status: Status {
        guard error == nil else { return .unavailable }
        if case .invalid = local { return .invalidLocal }
        guard let remote else { return .unavailable }
        guard let available = remote.manifest else { return .unversionedPublisher }
        guard let installed = local.manifest,
            installed.modelVersion != nil, available.modelVersion != nil
        else { return .verificationRequired }
        if available.isNewer(than: installed) { return .updateAvailable }
        if installed.isNewer(than: available) { return .installedNewer }
        return .current
    }

    var updateAvailable: Bool { status == .updateAvailable }
    var verificationRequired: Bool { status == .verificationRequired }
}

extension ModelManager {
    // Identifies the remote publisher repository, not the provenance or integrity
    // of local bytes. Legacy folders have no download receipt; explicit Verify
    // remains the file-integrity operation even when publisher revisions match.
    nonisolated static func isRegisteredOfficialUpdateRepository(_ id: String, registered: Set<String>) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].lowercased() == "osaurusai"
            && !parts[1].isEmpty && registered.contains(id.lowercased())
    }

    /// Detail views and catalog refresh share one result per repository. No network
    /// request is made from SwiftUI body evaluation or from runtime admission.
    func checkModelManifest(_ model: MLXModel, force: Bool = false) async {
        guard !manifestChecksInFlight.contains(model.id.lowercased()) else {
            if force { pendingManifestChecks[model.id.lowercased()] = model }
            return
        }
        if !force, let previous = manifestChecks[model.id.lowercased()], Date().timeIntervalSince(previous.checkedAt) < 300 {
            return
        }
        manifestChecksInFlight.insert(model.id.lowercased())
        defer {
            manifestChecksInFlight.remove(model.id.lowercased())
            // Download completion must not lose its refresh to an older check.
            if let pending = pendingManifestChecks.removeValue(forKey: model.id.lowercased()) {
                Task { await checkModelManifest(pending, force: true) }
            }
        }
        let remote: HuggingFaceService.ManifestSnapshot?
        let errorMessage: String?
        do {
            remote = try await HuggingFaceService.shared.fetchModelManifest(
                repoId: model.id, previous: manifestChecks[model.id.lowercased()]?.remote
            )
            errorMessage = nil
        } catch is CancellationError { return } catch {
            guard !Task.isCancelled else { return }
            remote = nil
            errorMessage = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
        guard !Task.isCancelled else { return }
        manifestChecks[model.id.lowercased()] = ModelManifestCheck(
            local: local,
            remote: remote,
            error: errorMessage,
            checkedAt: Date()
        )
    }

    func refreshModelUpdates(force: Bool = false) async {
        let installed = await Self.discoverLocalModelsOffMain()
        // The curated/Hub catalog identifies official repositories. A directory
        // name or a synthesized download URL alone does not establish origin.
        let registered = Set(suggestedModels.map { $0.id.lowercased() })
        // Serial and bounded to installed bundles. Include legacy official
        // bundles so a newly published sidecar is not invisible to their users.
        for model in installed {
            guard !Task.isCancelled else { return }
            let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
            guard local != .absent || Self.isRegisteredOfficialUpdateRepository(model.id, registered: registered)
            else { continue }
            await checkModelManifest(model, force: force)
        }
    }
}
