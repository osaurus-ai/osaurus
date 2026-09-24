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
    }

    static let interval: TimeInterval = 6 * 60 * 60
    var attempts: [String: Attempt] = [:]

    func isDue(_ repository: String, at now: Date) -> Bool {
        guard let attempt = attempts[repository.lowercased()] else { return true }
        return now >= attempt.nextCheck
    }

    mutating func record(_ repository: String, at now: Date, succeeded: Bool) {
        let key = repository.lowercased()
        let failures = succeeded ? 0 : min((attempts[key]?.failures ?? 0) + 1, 6)
        let delay = succeeded ? Self.interval : min(Self.interval, 900 * pow(2, Double(failures - 1)))
        attempts[key] = Attempt(nextCheck: now.addingTimeInterval(delay), failures: failures)
    }
}

extension ModelManager {
    /// Local file changes still update badges when polling is disabled. Reuse
    /// the last remote observation without initiating a background request.
    func refreshCachedManifestLocalState() async {
        for model in await Self.discoverLocalModelsOffMain() {
            guard manifestChecks[model.id] != nil else { continue }
            let local = await Task.detached(priority: .utility) { ModelManifest.read(at: model.localDirectory) }.value
            guard let previous = manifestChecks[model.id] else { continue }
            manifestChecks[model.id] = ModelManifestCheck(
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
        guard automaticallyChecksModelUpdates, !Task.isCancelled else { return }
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
                guard !Task.isCancelled, self.automaticallyChecksModelUpdates else { return }
                let started = Date()
                guard schedule.isDue(model.id, at: started) else { continue }
                guard !self.manifestChecksInFlight.contains(model.id) else { continue }
                // Reuse manual/list check coalescing and its short TTL too.
                await self.checkModelManifest(model)
                guard !Task.isCancelled, self.automaticallyChecksModelUpdates else { return }
                guard let result = self.manifestChecks[model.id] else { continue }
                schedule.record(model.id, at: result.checkedAt, succeeded: result.error == nil && result.remote != nil)
                if let data = try? JSONEncoder().encode(schedule) {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
        }
    }
}
