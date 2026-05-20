//
//  TaskCoalescer.swift
//  osaurus
//
//  Generic single-flight cache for async resource creation. Concurrent
//  callers requesting the same key all observe the same in-flight `Task`
//  and therefore the same returned value. Used by
//  `MLXBatchAdapter.Registry` to avoid building a duplicate `BatchEngine`
//  on the same MLX `ModelContainer`, which would put two consumers on the
//  shared GPU command queue and surface as Metal completion-queue
//  abort (`MTLReleaseAssertionFailure`).
//

import Foundation

/// Single-flight cache: at most one creator per key is in flight at a
/// time, every concurrent caller observes the same resolved value.
///
/// Construction-order invariant inside `value(for:factory:)`:
///   1. Park the in-flight `Task` in `creating[key]` *before* awaiting it,
///      so any caller that lands while the actor is suspended in
///      `await task.value` finds the task and joins instead of starting
///      a second creation.
///   2. After the await, write `values[key] = value` *before* clearing
///      `creating[key]`. A caller that lands between these two writes
///      either observes the resolved value (cache hit) or the still-set
///      in-flight task (joins the same task) — never the empty state
///      that would trigger a second creation.
///
/// Removal discipline (the `remove(_:)` / `removeAll()` direction):
///
/// `remove(_:)` and `removeAll()` must atomically (a) take exclusive
/// ownership of the in-flight `Task` so concurrent removers cannot
/// double-drain the same value (which would cause the caller to
/// double-shutdown the underlying resource), AND (b) keep the task
/// observable to concurrent `value(for:)` callers so they can join the
/// drain instead of starting a duplicate factory while the actor is
/// suspended on `await creation.value`.
///
/// The two requirements are met by moving the task from `creating[key]`
/// (which `value(for:)`'s start-new-task path keys off) into
/// `draining[key]` (which `value(for:)`'s join path also keys off).
/// First remover wins the move; the second remover finds `creating[key]`
/// nil and falls through to `values.removeValue(forKey:)`, which is
/// also nil during the drain — so the second remover gets `nil`.
///
/// **Removal-race invariant**: between the post-await resume of
/// `value(for:)` and its `values[key] = …` write, a concurrent
/// `remove(_:)` / `removeAll()` may have transferred the task to
/// `draining`. The canonicality check (`creating[key] == ourTask`)
/// then fails (since the slot is empty), so `value(for:)` does not
/// commit a stale entry the user just asked to remove.
public actor TaskCoalescer<Value: Sendable> {
    private var values: [String: Value] = [:]
    private var creating: [String: Task<Value, Never>] = [:]
    private var draining: [String: Task<Value, Never>] = [:]

    public init() {}

    /// Resolve the value for `key`, creating it via `factory` on first
    /// access. Concurrent callers for the same `key` share a single
    /// `factory` invocation and observe the same returned `Value`.
    ///
    /// Lookup order:
    ///   1. `values[key]`   — resolved cache hit.
    ///   2. `creating[key]` — in-flight first-fetch; join it.
    ///   3. `draining[key]` — in-flight teardown. Callers landing here
    ///      **wait for the drain to complete and then start a fresh
    ///      factory**. They do NOT receive the drained value: the
    ///      caller of `remove(_:)` owns it and is about to release the
    ///      underlying resource (e.g. `engine.shutdown()`); handing
    ///      that same `Value` to a `value(for:)` caller would put a
    ///      consumer on a resource that is being torn down. Joining
    ///      the drain rather than starting a duplicate factory remains
    ///      the load-bearing invariant — two `BatchEngine`s on one
    ///      `ModelContainer` Metal-abort the shared GPU command queue.
    ///   4. otherwise — start a new factory.
    ///
    /// The drain-wait path is a `while` loop with a re-check after the
    /// await suspension: another `value(for:)` caller may have started
    /// a fresh task while we waited, in which case we fall through to
    /// the join path on the next iteration.
    public func value(
        for key: String,
        factory: @Sendable @escaping () async -> Value
    ) async -> Value {
        while true {
            if let existing = values[key] { return existing }
            if let inFlight = creating[key] {
                return await inFlight.value
            }
            if let drainingTask = draining[key] {
                _ = await drainingTask.value
                // Defensively clear `draining[key]` so racing
                // `value(for:)` callers don't tight-loop on an already-
                // resolved drainingTask before `remove(_:)` finishes its
                // own canonicality check. Idempotent: if `remove(_:)`
                // already cleared the slot, this is a no-op; if `remove`
                // hasn't run its post-await statements yet, its
                // canonicality (`draining[key] == creation`) will fail
                // and it will skip a redundant clear.
                if draining[key] == drainingTask {
                    draining[key] = nil
                }
                // Re-check on the next loop iteration. Another
                // `value(for:)` caller may have started a fresh task
                // (which we should join, not duplicate).
                continue
            }
            let ourTask = Task<Value, Never> { await factory() }
            creating[key] = ourTask
            let value = await ourTask.value
            if creating[key] == ourTask {
                values[key] = value
                creating[key] = nil
            }
            return value
        }
    }

    /// Remove and return the cached entry for `key`, draining any
    /// in-flight creation first. Callers use the returned value to
    /// release the resource it represents (e.g. `engine.shutdown()`).
    /// Returns `nil` when no entry exists.
    ///
    /// **Use the `dispose:` variant for resources that need explicit
    /// teardown.** The plain `remove(_:)` clears the tombstone the
    /// instant the creation task resolves; if the caller then runs an
    /// async teardown (e.g. `engine.shutdown()`), a racing `value(for:)`
    /// can build a fresh resource on the same backing object while the
    /// old one is mid-shutdown. `remove(_:dispose:)` keeps
    /// `draining[key]` set across the teardown so racing creators wait
    /// for the resource to be fully released.
    ///
    /// Concurrent removers: the first call removes `creating[key]`
    /// (atomic on the actor), tombstones it into `draining[key]`, and
    /// awaits. A second concurrent `remove(_:)` finds `creating[key]`
    /// nil and falls through to `values.removeValue(forKey:)`, which is
    /// also nil during the drain — so the second remover returns
    /// `nil`. Exclusive ownership transfer prevents double-shutdown.
    @discardableResult
    public func remove(_ key: String) async -> Value? {
        await remove(key, dispose: nil)
    }

    /// Remove and return the cached entry for `key`, draining any
    /// in-flight creation first, **and run an async `dispose` step
    /// inside the tombstone window**. Concurrent `value(for:)` callers
    /// for the same key wait for the dispose step to finish before they
    /// can build a fresh resource — preventing the
    /// build-while-shutting-down race that two-engines-on-one-container
    /// hits.
    ///
    /// Pass `nil` to `dispose` for resources that don't need an async
    /// teardown (purely-resolved-value-cache use cases).
    ///
    /// **Tombstone discipline**: both the in-flight and resolved-cache
    /// paths install a single `drainTask` into `draining[key]` that
    /// wraps `creation.value` (if any) AND the `dispose` step. The task
    /// resolves only after dispose completes, so a `value(for:)` racing
    /// us sees `draining[key]` set, awaits the drain, and is unblocked
    /// only after the resource has been fully released. The resolved-
    /// cache path is the auditor finding from PR #1037 — without the
    /// synthetic drainTask it would skip the tombstone and let racers
    /// build fresh while shutdown was still running.
    @discardableResult
    public func remove(
        _ key: String,
        dispose: (@Sendable (Value) async -> Void)?
    ) async -> Value? {
        let drainTask: Task<Value, Never>?
        if let creation = creating.removeValue(forKey: key) {
            // In-flight path. Wrap creation + dispose into a single
            // tombstone task so the drain window covers BOTH the
            // creation completion and the resource teardown.
            drainTask = Task<Value, Never> {
                let value = await creation.value
                if let dispose = dispose {
                    await dispose(value)
                }
                return value
            }
        } else if let resolved = values.removeValue(forKey: key) {
            // Resolved path. There is no creation task to await, but we
            // STILL need a tombstone to gate racers across `dispose`.
            // Without it, a `value(for:)` landing during dispose finds
            // `values[key]` empty (just removed), `creating[key]` empty,
            // and `draining[key]` empty, then starts a fresh factory
            // while the previous resource is still being torn down —
            // exactly the build-while-shutting-down race. Wrapping
            // dispose into a synthetic task that returns the resolved
            // value gives us the same `drainTask` shape as the in-flight
            // path so racers can await it uniformly.
            drainTask = Task<Value, Never> {
                if let dispose = dispose {
                    await dispose(resolved)
                }
                return resolved
            }
        } else {
            return nil
        }
        guard let drainTask else { return nil }

        draining[key] = drainTask
        let value = await drainTask.value
        // Canonicality: clear only if our task is still the registered
        // drainer (a concurrent `removeAll(dispose:)` could have moved
        // it; the dict-eq check costs nothing and locks against drift).
        if draining[key] == drainTask {
            draining[key] = nil
        }
        return value
    }

    /// Drain every entry — both already-resolved and in-flight — and
    /// return them all. Use the returned entries to release the
    /// underlying resources. Same removal-race discipline as
    /// `remove(_:)`: concurrent `value(for:)` callers join the
    /// `draining[key]` tombstone while we await.
    @discardableResult
    public func removeAll() async -> [(key: String, value: Value)] {
        await removeAll(dispose: nil)
    }

    /// `removeAll()` variant that runs `dispose(key, value)` inside the
    /// tombstone window for each entry — both in-flight creations and
    /// pre-resolved values. Mirrors `remove(_:dispose:)`'s drainTask
    /// discipline so the build-while-shutting-down race is closed for
    /// every entry the caller is tearing down, not just the in-flight
    /// ones.
    @discardableResult
    public func removeAll(
        dispose: (@Sendable (String, Value) async -> Void)?
    ) async -> [(key: String, value: Value)] {
        let pendingCreations = creating
        creating.removeAll()
        let preExistingValues = values
        values.removeAll()

        // Build one drainTask per entry that wraps creation+dispose
        // (in-flight) or just dispose (resolved). Install all of them
        // BEFORE the first await so a `value(for:)` racing into any
        // affected key finds the tombstone on the first lookup.
        var drainTasks: [(key: String, task: Task<Value, Never>)] = []
        for (key, creation) in pendingCreations {
            let task = Task<Value, Never> {
                let value = await creation.value
                if let dispose = dispose {
                    await dispose(key, value)
                }
                return value
            }
            draining[key] = task
            drainTasks.append((key, task))
        }
        for (key, value) in preExistingValues {
            let task = Task<Value, Never> {
                if let dispose = dispose {
                    await dispose(key, value)
                }
                return value
            }
            draining[key] = task
            drainTasks.append((key, task))
        }

        var resolved: [(key: String, value: Value)] = []
        for (key, task) in drainTasks {
            let value = await task.value
            resolved.append((key, value))
            if draining[key] == task {
                draining[key] = nil
            }
        }
        return resolved
    }

    /// Diagnostic accessor: caller-side test instrument for asserting
    /// that the coalescer holds the expected number of resolved /
    /// in-flight / draining entries. Not used on the production path.
    public func snapshot() -> (resolved: Int, inFlight: Int, draining: Int) {
        (values.count, creating.count, draining.count)
    }

    /// Returns the currently-resolved values. Read-only diagnostic
    /// helper for the Server → Settings panel; safe to enumerate
    /// because the underlying actor serializes against mutations.
    public func resolvedValues() -> [Value] {
        Array(values.values)
    }
}
