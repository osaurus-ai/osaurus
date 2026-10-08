//
//  DetachedPhoneRuns.swift
//  osaurus
//
//  Runs the owner's paired phone starts keep going when its connection drops
//  (docs/MOBILE_PROTOCOL.md §6.4). iOS suspends an app moments after it
//  leaves the screen, and a run cancelled with its socket threw the reply
//  away. A run the phone names with `osaurus_run_id` records every SSE frame
//  it writes, so the phone can come back to `GET /runs/{id}/events?after=N`,
//  replay what it missed and follow the rest live. Stopping it is explicit
//  (`POST /runs/{id}/stop`), no longer the socket closing.
//

import Foundation

/// One phone run: the SSE frames it has written, and whoever is following it.
final class DetachedPhoneRun: @unchecked Sendable {
    /// Where a follower's frames go. Called under the run's lock, in frame
    /// order, so it must only hand the work to its own event loop.
    struct Follower: Sendable {
        let frames: @Sendable ([String]) -> Void
        let end: @Sendable () -> Void
    }

    enum FollowResult: Equatable {
        case following(UUID)
        /// The frames asked for are no longer held (replay over budget, or
        /// an index past the end); the client reloads the chat instead.
        case gone
    }

    /// Replay is capped per run. Past it the frames are dropped and a rejoin
    /// is refused, but the run itself carries on and still saves its chat.
    static let byteBudget = 16 * 1024 * 1024

    let id: String

    private let lock = NSLock()
    private var frames: [String] = []
    private var bytes = 0
    private var overflowed = false
    private var followers: [UUID: Follower] = [:]
    private var stopHandler: (@Sendable () -> Void)?
    private var stopRequested = false
    private var finished: Date?
    /// The newest transient frame (an image job's preview), for a follower
    /// who joins mid-way. Never in `frames`, so never counted.
    private var latestTransient: String?

    init(id: String) {
        self.id = id
    }

    var finishedAt: Date? { lock.withLock { finished } }
    var frameCount: Int { lock.withLock { frames.count } }

    /// One whole SSE frame (`data: …\n\n`) the run just wrote.
    func record(_ frame: String) {
        lock.withLock {
            guard finished == nil else { return }
            if !overflowed {
                bytes += frame.utf8.count
                if bytes > Self.byteBudget {
                    overflowed = true
                    frames = []
                } else {
                    frames.append(frame)
                }
            }
            for follower in followers.values { follower.frames([frame]) }
        }
    }

    /// A frame followers get live, of which replay keeps only the newest:
    /// an image job's previews, each a whole PNG, which would spend the
    /// replay budget within one generation. Not counted in `frameCount`,
    /// so a client counts only the frames it would get again on replay.
    func recordTransient(_ frame: String) {
        lock.withLock {
            guard finished == nil else { return }
            latestTransient = frame
            for follower in followers.values { follower.frames([frame]) }
        }
    }

    /// The run is over, however it ended. Idempotent.
    func finish() {
        lock.withLock {
            guard finished == nil else { return }
            finished = Date()
            stopHandler = nil
            for follower in followers.values { follower.end() }
            followers = [:]
        }
    }

    /// Replays the frames after the first `after`, then follows the run live
    /// until it finishes (at once, when it already has).
    func follow(after: Int, _ follower: Follower) -> FollowResult {
        lock.withLock {
            guard !overflowed, after >= 0, after <= frames.count else { return .gone }
            if after < frames.count { follower.frames(Array(frames[after...])) }
            let token = UUID()
            if finished != nil {
                follower.end()
            } else {
                // Where a still-running image job has got to.
                if let latestTransient { follower.frames([latestTransient]) }
                followers[token] = follower
            }
            return .following(token)
        }
    }

    func unfollow(_ token: UUID) {
        lock.withLock { _ = followers.removeValue(forKey: token) }
    }

    /// How the run is stopped. A stop that arrived first runs it at once.
    func onStop(_ handler: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            guard finished == nil else { return false }
            stopHandler = handler
            return stopRequested
        }
        if runNow { handler() }
    }

    /// Stops the run. False when it had already finished.
    @discardableResult
    func stop() -> Bool {
        let (running, handler) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard finished == nil else { return (false, nil) }
            stopRequested = true
            return (true, stopHandler)
        }
        handler?()
        return running
    }
}

/// The phone runs this Mac is holding, live or recently finished.
final class DetachedPhoneRuns: @unchecked Sendable {
    static let shared = DetachedPhoneRuns()
    /// Image jobs the phone names (`osaurus_job_id`, §12.5), kept apart so
    /// a run id and a job id can never meet.
    static let images = DetachedPhoneRuns()

    /// How long a finished run can still be replayed: long enough for the
    /// user to come back to the app after the reply is done.
    static let retention: TimeInterval = 30 * 60
    /// Finished runs kept at most; the oldest go first.
    static let maxFinished = 32

    private let lock = NSLock()
    private var runs: [String: DetachedPhoneRun] = [:]

    /// A phone's run id: its own UUID, or anything short and plain.
    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Registers a run under `id`. When a live run already has that id the
    /// phone sent the same request again (on its other route, having heard
    /// nothing back), so it gets that run to follow instead of a second one.
    /// `followFinished`: a run that has already finished, but is still held,
    /// is followed too (it replays and ends). Image jobs ask for it: the same
    /// id after its job ended is the phone retrying a request whose answer
    /// it never heard, and running a cloud job again would bill again.
    func begin(
        id: String,
        followFinished: Bool = false,
        now: Date = Date()
    ) -> (run: DetachedPhoneRun, isNew: Bool) {
        lock.withLock {
            prune(now: now)
            if let existing = runs[id], existing.finishedAt == nil || followFinished {
                return (existing, false)
            }
            let run = DetachedPhoneRun(id: id)
            runs[id] = run
            return (run, true)
        }
    }

    func run(id: String, now: Date = Date()) -> DetachedPhoneRun? {
        lock.withLock {
            prune(now: now)
            return runs[id]
        }
    }

    /// Live runs, for tests and the log.
    var liveCount: Int {
        lock.withLock { runs.values.filter { $0.finishedAt == nil }.count }
    }

    private func prune(now: Date) {
        runs = runs.filter { _, run in
            guard let finished = run.finishedAt else { return true }
            return now.timeIntervalSince(finished) < Self.retention
        }
        let finished = runs.values.compactMap { run in run.finishedAt.map { (run.id, $0) } }
        guard finished.count > Self.maxFinished else { return }
        for (id, _) in finished.sorted(by: { $0.1 < $1.1 }).prefix(finished.count - Self.maxFinished) {
            runs.removeValue(forKey: id)
        }
    }
}
