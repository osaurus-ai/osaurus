import Foundation

struct ModelManifestCheck: Sendable {
    let local: ModelManifest.Local
    let remote: HuggingFaceService.ManifestSnapshot?
    let error: String?
    let checkedAt: Date

    var updateAvailable: Bool {
        guard let installed = local.manifest, let available = remote?.manifest else { return false }
        return available.isNewer(than: installed)
    }
}

extension ModelManager {
    /// Detail views and catalog refresh share one result per repository. No network
    /// request is made from SwiftUI body evaluation or from runtime admission.
    func checkModelManifest(_ model: MLXModel, force: Bool = false) async {
        guard !manifestChecksInFlight.contains(model.id) else {
            if force { pendingManifestChecks[model.id] = model }
            return
        }
        if !force, let previous = manifestChecks[model.id], Date().timeIntervalSince(previous.checkedAt) < 300 {
            return
        }
        manifestChecksInFlight.insert(model.id)
        defer {
            manifestChecksInFlight.remove(model.id)
            // Download completion must not lose its refresh to an older check.
            if let pending = pendingManifestChecks.removeValue(forKey: model.id) {
                Task { await checkModelManifest(pending, force: true) }
            }
        }
        let remote: HuggingFaceService.ManifestSnapshot?
        let errorMessage: String?
        do {
            remote = try await HuggingFaceService.shared.fetchModelManifest(repoId: model.id)
            errorMessage = nil
        } catch is CancellationError { return } catch {
            remote = nil
            errorMessage = error.localizedDescription
        }
        let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
        manifestChecks[model.id] = ModelManifestCheck(
            local: local,
            remote: remote,
            error: errorMessage,
            checkedAt: Date()
        )
    }

    func refreshModelUpdates(force: Bool = false) async {
        let installed = await Self.discoverLocalModelsOffMain()
        // Serial and bounded to local, publisher-versioned bundles, rather than
        // issuing a request for every model in the remote catalog.
        for model in installed {
            guard !Task.isCancelled else { return }
            let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
            guard local != .absent else { continue }
            await checkModelManifest(model, force: force)
        }
    }
}
