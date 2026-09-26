import Foundation

/// Shares one active sweep across timer and view triggers. Cancellation drains
/// that sweep before another one can begin.
@MainActor
final class ModelUpdateSweep {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let next = Task {
            defer { self.task = nil }
            await operation()
        }
        task = next
        await next.value
    }

    func cancel() { task?.cancel() }
}

/// Persist due times so repeated launches, view appearances and wakeups do not
/// turn a publisher outage into an unbounded retry loop.
struct ModelUpdatePollingSchedule: Codable {
    struct Attempt: Codable {
        var nextCheck: Date
        var failures: Int
        var observation: Observation?
    }

    /// Remote observations survive the due-time throttle. Local files are always
    /// reread on restoration; this cache never certifies installed file contents.
    struct Observation: Codable {
        let revision: String?
        let manifest: Data?
        let error: String?
        let checkedAt: Date

        init(_ check: ModelManifestCheck) {
            revision = check.remote?.revision
            if let remote = check.remote?.manifest {
                manifest = try? JSONSerialization.data(withJSONObject: [
                    "required_osaurus_version": remote.requiredOsaurusVersion ?? "",
                    "model_version": remote.modelVersion ?? "",
                ])
            } else { manifest = nil }
            error = check.error
            checkedAt = check.checkedAt
        }

        func restoring(local: ModelManifest.Local) -> ModelManifestCheck? {
            let remote: HuggingFaceService.ManifestSnapshot?
            if let revision {
                guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else { return nil }
                let decoded: ModelManifest?
                if let manifest {
                    guard let parsed = try? ModelManifest.decode(manifest) else { return nil }
                    decoded = parsed
                } else { decoded = nil }
                remote = .init(revision: revision, manifest: decoded)
            } else { remote = nil }
            return ModelManifestCheck(local: local, remote: remote, error: error, checkedAt: checkedAt)
        }
    }

    static let interval: TimeInterval = 6 * 60 * 60
    var attempts: [String: Attempt] = [:]

    func isDue(_ repository: String, at now: Date) -> Bool {
        guard let attempt = attempts[repository.lowercased()] else { return true }
        return now >= attempt.nextCheck
    }

    mutating func record(_ repository: String, at now: Date, succeeded: Bool, observation: Observation? = nil) {
        let key = repository.lowercased()
        let failures = succeeded ? 0 : min((attempts[key]?.failures ?? 0) + 1, 6)
        let delay = succeeded ? Self.interval : min(Self.interval, 900 * pow(2, Double(failures - 1)))
        attempts[key] = Attempt(nextCheck: now.addingTimeInterval(delay), failures: failures, observation: observation)
    }
}

extension ModelManager {
    /// Local file changes still update badges when polling is disabled. Reuse
    /// the last remote observation without initiating a background request.
    func refreshCachedManifestLocalState() async {
        for model in await Self.discoverLocalModelsOffMain() {
            guard manifestChecks[model.id.lowercased()] != nil else { continue }
            let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
            guard let previous = manifestChecks[model.id.lowercased()] else { continue }
            manifestChecks[model.id.lowercased()] = ModelManifestCheck(
                local: local,
                remote: previous.remote,
                error: previous.error,
                checkedAt: previous.checkedAt
            )
        }
    }

    /// Only the shared manager owns a timer. Other manager instances, manual
    /// detail checks and SwiftUI redraws cannot create extra polling loops.
    func restartModelUpdatePolling() {
        guard ownsModelUpdatePolling else { return }
        modelUpdatePollingTask?.cancel()
        modelUpdatePollingTask = nil
        guard automaticallyChecksModelUpdates else {
            automaticModelUpdateSweep.cancel()
            return
        }
        guard !RuntimeEnvironment.isUnderTests else { return }
        modelUpdatePollingTask = Task { [weak self] in
            // Keep metadata traffic out of the initial app launch work.
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAutomaticModelUpdates()
                // One sweep after a wake; never replay missed timer ticks.
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
            }
        }
    }

    /// Metadata only. The existing explicit Repair/Update action owns all file
    /// verification and replacement; this path never calls the downloader.
    func refreshAutomaticModelUpdates() async {
        guard ownsModelUpdatePolling else { return }
        guard !Task.isCancelled else { return }
        await automaticModelUpdateSweep.run { [weak self] in
            guard let self else { return }
            let key = "ModelUpdatePollingSchedule"
            var schedule =
                UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode(ModelUpdatePollingSchedule.self, from: $0) }
                ?? ModelUpdatePollingSchedule()
            let installed = await Self.discoverLocalModelsOffMain()
            let registered = Set(self.suggestedModels.map { $0.id.lowercased() })
            let official = installed.filter { Self.isRegisteredOfficialUpdateRepository($0.id, registered: registered) }
            let currentIDs = Set(official.map { $0.id.lowercased() })
            schedule.attempts = schedule.attempts.filter { currentIDs.contains($0.key) }
            for model in official {
                guard !Task.isCancelled else { return }
                let repositoryKey = model.id.lowercased()
                if self.manifestChecks[repositoryKey] == nil,
                    let observation = schedule.attempts[repositoryKey]?.observation {
                    let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
                    guard !Task.isCancelled else { return }
                    // A manual check may finish while the local read is suspended.
                    // Never replace that newer observation with persisted state.
                    if self.manifestChecks[repositoryKey] == nil {
                        self.manifestChecks[repositoryKey] = observation.restoring(local: local)
                    }
                }
                guard self.automaticallyChecksModelUpdates else { continue }
                let started = Date()
                // Old schedules lacked observations. Check once to restore the
                // missing status rather than hiding a badge for six hours.
                guard self.manifestChecks[repositoryKey] == nil || schedule.isDue(model.id, at: started) else { continue }
                guard !self.manifestChecksInFlight.contains(model.id.lowercased()) else { continue }
                // Reuse manual/list check coalescing and its short TTL too.
                await self.checkModelManifest(model)
                guard !Task.isCancelled, self.automaticallyChecksModelUpdates else { return }
                guard let result = self.manifestChecks[model.id.lowercased()] else { continue }
                schedule.record(
                    model.id, at: result.checkedAt,
                    succeeded: result.error == nil && result.remote != nil,
                    observation: .init(result)
                )
                if let data = try? JSONEncoder().encode(schedule) {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
        }
    }
}
