//
//  TaskCoalescerTests.swift
//  osaurusTests
//
//  Direct coverage for the single-flight cache used by
//  `MLXBatchAdapter.Registry`. Verifies the construction-order
//  invariant (concurrent first-fetches share a single creator) and
//  the teardown discipline (in-flight creations are drained on
//  remove, not leaked).
//
//  Tests use a deliberately delayed factory so multiple concurrent
//  callers reliably observe the same in-flight `Task`. The factory's
//  invocation count and the value identity are the assertions.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("TaskCoalescer single-flight discipline")
struct TaskCoalescerTests {

    /// Sentinel value type. A mutable counter on a class lets the test
    /// observe both the number of factory invocations and the identity
    /// of each produced value (every factory run creates a new
    /// instance, so reference equality across coalesced callers is the
    /// cleanest signal that they share a single creation).
    final class Sentinel: @unchecked Sendable {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    /// Each creation increments `creates` so the test can assert the
    /// factory ran exactly once across N coalesced callers. Sleep is
    /// intentional: it widens the actor-suspension window so the
    /// harness reliably exercises the coalescing path even on a single
    /// CPU.
    actor SlowFactory {
        var creates = 0
        let sleepNanoseconds: UInt64
        init(sleepMs: UInt64 = 100) {
            self.sleepNanoseconds = sleepMs * 1_000_000
        }
        func make() async -> Sentinel {
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            creates += 1
            return Sentinel(creates)
        }
    }

    @Test("Concurrent first-fetches for the same key produce one creation")
    func concurrentFirstFetches_coalesce() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory()
        async let a = coalescer.value(for: "k") { await factory.make() }
        async let b = coalescer.value(for: "k") { await factory.make() }
        async let c = coalescer.value(for: "k") { await factory.make() }
        async let d = coalescer.value(for: "k") { await factory.make() }
        async let e = coalescer.value(for: "k") { await factory.make() }
        let (va, vb, vc, vd, ve) = await (a, b, c, d, e)
        let creates = await factory.creates
        #expect(
            creates == 1,
            "factory ran \(creates) times; coalescer must invoke at most once for concurrent first-fetches"
        )
        #expect(va === vb && vb === vc && vc === vd && vd === ve)
    }

    @Test("Different keys do not coalesce with each other")
    func differentKeys_doNotCoalesce() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory()
        async let a = coalescer.value(for: "k1") { await factory.make() }
        async let b = coalescer.value(for: "k2") { await factory.make() }
        async let c = coalescer.value(for: "k3") { await factory.make() }
        let (va, vb, vc) = await (a, b, c)
        let creates = await factory.creates
        #expect(creates == 3, "expected 3 distinct creates, got \(creates)")
        #expect(va !== vb && vb !== vc && va !== vc)
    }

    @Test("Subsequent calls after first creation hit the cache, no re-create")
    func cacheHitPath() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 10)
        let v1 = await coalescer.value(for: "k") { await factory.make() }
        let v2 = await coalescer.value(for: "k") { await factory.make() }
        let v3 = await coalescer.value(for: "k") { await factory.make() }
        let creates = await factory.creates
        #expect(creates == 1)
        #expect(v1 === v2 && v2 === v3)
    }

    @Test("remove() drains an in-flight creation and returns the resolved value")
    func remove_drainsInFlight() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 80)
        // Kick off the creation.
        async let creating = coalescer.value(for: "k") { await factory.make() }
        // Wait long enough for the actor to park the task in `creating`,
        // but not so long that the factory finishes and writes `values`.
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Race the in-flight creation. The remove call must await the
        // task and return the resolved value rather than nil.
        async let removed = coalescer.remove("k")
        let (creatingValue, removedValue) = await (creating, removed)
        #expect(removedValue != nil, "remove() lost the in-flight creation")
        #expect(removedValue === creatingValue)
        let creates = await factory.creates
        #expect(creates == 1)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0 && snap.draining == 0)
    }

    @Test("remove() returns nil for an unknown key")
    func remove_returnsNilForUnknownKey() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let removed = await coalescer.remove("never-stored")
        #expect(removed == nil)
    }

    @Test("remove() pulls a resolved entry and clears it")
    func remove_clearsResolved() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 5)
        let stored = await coalescer.value(for: "k") { await factory.make() }
        let removed = await coalescer.remove("k")
        #expect(removed === stored)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0 && snap.draining == 0)
        // Subsequent lookups must trigger a fresh creation.
        let freshFactory = SlowFactory(sleepMs: 5)
        let next = await coalescer.value(for: "k") { await freshFactory.make() }
        let freshCreates = await freshFactory.creates
        #expect(freshCreates == 1)
        #expect(next !== stored)
    }

    @Test("removeAll() drains in-flight + resolved together")
    func removeAll_drainsBoth() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let resolvedFactory = SlowFactory(sleepMs: 5)
        let inFlightFactory = SlowFactory(sleepMs: 80)
        // Resolve one entry to populate `values`.
        let resolved = await coalescer.value(for: "resolved") {
            await resolvedFactory.make()
        }
        // Kick off an in-flight creation that won't finish before we
        // call removeAll().
        async let pending = coalescer.value(for: "in-flight") {
            await inFlightFactory.make()
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let drained = await coalescer.removeAll()
        let pendingValue = await pending
        #expect(drained.count == 2)
        let byKey = Dictionary(uniqueKeysWithValues: drained.map { ($0.key, $0.value) })
        #expect(byKey["resolved"] === resolved)
        #expect(byKey["in-flight"] === pendingValue)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0 && snap.draining == 0)
    }

    /// Regression: previously `remove(_:)` cleared `creating[key]` BEFORE
    /// `await creation.value`, so a concurrent `value(for:)` that landed
    /// during the actor-suspension window saw both `values[key]` and
    /// `creating[key]` empty and started a duplicate factory.
    ///
    /// New invariant after the 2026-05-07 audit: no two factories run
    /// **simultaneously** for the same key. A `value(for:)` racing a
    /// `remove(_:)` waits for the drain to complete and *then* starts a
    /// fresh factory — it does NOT receive the drained value, because the
    /// caller of `remove(_:)` owns that value and is about to release the
    /// underlying resource (e.g. `engine.shutdown()`). Handing the
    /// drained value to a `value(for:)` caller would put a consumer on a
    /// resource that is being torn down.
    @Test("value() racing remove() waits for drain, then starts a fresh factory — never receives the draining value")
    func value_during_remove_waitsForDrainThenStartsFresh() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 200)
        // Kick off the original creation.
        async let creating = coalescer.value(for: "k") { await factory.make() }
        // Park the task in `creating[key]` before the next step.
        try? await Task.sleep(nanoseconds: 20_000_000)
        // Begin teardown — this is the call that previously cleared
        // `creating[key]` and opened the race window.
        async let removed = coalescer.remove("k")
        // Let the actor process `remove()`'s synchronous prefix (peek +
        // tombstone) so the racing `value(for:)` below lands during the
        // drain's await suspension.
        try? await Task.sleep(nanoseconds: 20_000_000)
        // The racer: pre-fix, this would start a SECOND factory because
        // both `values[key]` and `creating[key]` are empty at this
        // moment. Post-fix, it joins `draining[key]` to wait for the
        // drain, then starts a fresh factory after.
        async let racing = coalescer.value(for: "k") { await factory.make() }
        let (creatingValue, removedValue, racingValue) = await (creating, removed, racing)
        let creates = await factory.creates
        #expect(
            creates == 2,
            "factory ran \(creates) times; expected exactly 2 — once for the original starter, once for the racer's fresh post-drain creation. (Pre-fix would be 1 for racer-joins-drain or unbounded for racer-starts-during-drain.)"
        )
        #expect(
            removedValue != nil,
            "remove() must drain the in-flight task"
        )
        #expect(
            creatingValue === removedValue,
            "remove()'s drained value must be the same task's resolved value (the original starter and the remover share the first task)"
        )
        #expect(
            racingValue !== creatingValue,
            "the racing value() caller must NOT receive the draining value — that value belongs to the remover and the underlying resource is about to be released"
        )
        let snap = await coalescer.snapshot()
        #expect(
            snap.resolved == 1 && snap.inFlight == 0 && snap.draining == 0,
            "after racing creation completes, the fresh value sits in `values` (1 resolved, 0 inFlight, 0 draining); the drained value was returned to remove()'s caller and is not in any map"
        )
    }

    /// After `remove(_:)` fully completes (drain finished, tombstone
    /// cleared), the next `value(for:)` for that key must start a fresh
    /// factory — not observe a stale tombstone or values entry.
    @Test("value() after remove() completes starts a fresh creation")
    func value_afterRemove_startsFresh() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 30)
        let stored = await coalescer.value(for: "k") { await factory.make() }
        let removed = await coalescer.remove("k")
        #expect(removed === stored)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0 && snap.draining == 0)
        // Fresh fetch must rebuild — not observe tombstone leftovers.
        let freshFactory = SlowFactory(sleepMs: 5)
        let fresh = await coalescer.value(for: "k") { await freshFactory.make() }
        let freshCreates = await freshFactory.creates
        #expect(freshCreates == 1)
        #expect(fresh !== stored)
    }

    /// Concurrent `remove(_:)` calls on the same in-flight key must not
    /// double-drain: exactly ONE remover should receive the resolved
    /// value (the one that wins `creating.removeValue`); the second
    /// remover finds the slot already moved to `draining` and returns
    /// `nil`. Locks the no-double-shutdown invariant.
    @Test("Concurrent remove() calls do not double-drain (exclusive ownership transfer)")
    func concurrentRemoves_doNotDoubleDrain() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 80)
        async let creating = coalescer.value(for: "k") { await factory.make() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let r1 = coalescer.remove("k")
        async let r2 = coalescer.remove("k")
        let (creatingValue, removed1, removed2) = await (creating, r1, r2)
        let creates = await factory.creates
        #expect(creates == 1, "factory must still run exactly once")
        let drained: [Sentinel] = [removed1, removed2].compactMap { $0 }
        #expect(
            drained.count == 1,
            "exactly one remove() must own the drained value; concurrent removers must not both return non-nil (would cause double-shutdown of the underlying resource)"
        )
        #expect(drained.first === creatingValue)
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0 && snap.draining == 0)
    }

    /// Same race surface as `value_during_remove_waitsForDrainThenStartsFresh`
    /// but for `removeAll()`: a `value(for:)` for a key whose in-flight
    /// task is being drained by a concurrent `removeAll()` must wait for
    /// the drain and then start a fresh factory — never receive the
    /// drained value (which is being torn down by the `removeAll` caller).
    @Test("value() racing removeAll() waits for drain, then starts a fresh factory")
    func value_duringRemoveAll_waitsForDrainThenStartsFresh() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 200)
        async let creating = coalescer.value(for: "k") { await factory.make() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let drained = coalescer.removeAll()
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let racing = coalescer.value(for: "k") { await factory.make() }
        let (creatingValue, drainedEntries, racingValue) = await (creating, drained, racing)
        let creates = await factory.creates
        #expect(
            creates == 2,
            "factory ran \(creates) times; expected exactly 2 — original + post-drain fresh creation. removeAll()'s caller owns the drained value; racing value() callers must rebuild."
        )
        #expect(drainedEntries.count == 1)
        let drainedValue = drainedEntries.first?.value
        #expect(drainedValue === creatingValue, "removeAll drained the original starter's task")
        #expect(racingValue !== creatingValue, "racing value() caller got a fresh value, not the drained one")
        let snap = await coalescer.snapshot()
        #expect(
            snap.resolved == 1 && snap.inFlight == 0 && snap.draining == 0,
            "post-drain fresh value sits in `values`; drained value was returned to removeAll()'s caller"
        )
    }

    /// Regression for the host-side race that landed in PR #1037 review:
    /// `MLXBatchAdapter.shutdownEngine` calls `coalescer.remove(...)` and
    /// then `await engine.shutdown()`. With the plain `remove(_:)` the
    /// tombstone clears the moment the creation task resolves, so a
    /// `value(for:)` racing the shutdown could build a fresh `BatchEngine`
    /// on the same `ModelContainer` while the old one is mid-shutdown
    /// (the exact two-engines-on-one-container Metal abort the registry
    /// exists to prevent). The `dispose:` variant runs the teardown
    /// INSIDE the tombstone window so racers wait for the resource to
    /// be fully released.
    @Test("remove(_:dispose:) keeps tombstone alive across async dispose; racing value() waits for dispose to finish")
    func remove_disposeKeepsTombstoneAcrossTeardown() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 50)

        // Establish a resolved entry first.
        let initial = await coalescer.value(for: "k") { await factory.make() }
        #expect(await factory.creates == 1)

        // Slow disposer that simulates an async `engine.shutdown()`. We
        // use the start of the dispose to broadcast to the racer that
        // teardown has begun, and verify the racer's fresh-factory call
        // does NOT complete until AFTER the dispose finishes.
        let disposeStart = AtomicTimestamp()
        let disposeEnd = AtomicTimestamp()
        async let removed: Sentinel? = coalescer.remove("k") { _ in
            await disposeStart.set()
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms shutdown
            await disposeEnd.set()
        }

        // Wait until the dispose has actually started before racing.
        await disposeStart.waitForSet()

        let raceFactory = SlowFactory(sleepMs: 5)
        let racingStart = Date.timeIntervalSinceReferenceDate
        let racingValue = await coalescer.value(for: "k") {
            await raceFactory.make()
        }
        let racingEnd = Date.timeIntervalSinceReferenceDate

        let removedValue = await removed
        let disposeFinishedAt = await disposeEnd.value
        #expect(
            disposeFinishedAt != nil,
            "dispose must finish before racing value() returns — otherwise the tombstone window doesn't protect the shutdown"
        )
        if let disposeFinishedAt {
            #expect(
                racingEnd >= disposeFinishedAt,
                "racing value() must NOT return before dispose finishes (race window leaked)"
            )
            #expect(
                racingStart < disposeFinishedAt,
                "test setup invariant: racing value() must START before dispose ends, otherwise we're not exercising the race"
            )
        }

        let raceCreates = await raceFactory.creates
        #expect(
            raceCreates == 1,
            "racing value() must build exactly one fresh resource AFTER dispose completes"
        )
        #expect(removedValue === initial, "remove() returned the original resolved value")
        #expect(racingValue !== initial, "racing value() got a fresh post-dispose creation")

        let snap = await coalescer.snapshot()
        #expect(
            snap.resolved == 1 && snap.inFlight == 0 && snap.draining == 0,
            "fresh post-dispose value sits in values; tombstone fully cleared"
        )
    }

    /// Locks the resolved-value path of `remove(_:dispose:)`: when the
    /// entry is already in `values` (no in-flight creation), the dispose
    /// step still runs but no tombstone is needed because there's no
    /// creation race window to gate.
    @Test("remove(_:dispose:) on a resolved entry runs dispose without tombstoning")
    func remove_disposeOnResolvedEntry_runsDispose() async {
        let coalescer = TaskCoalescer<Sentinel>()
        let factory = SlowFactory(sleepMs: 5)
        let stored = await coalescer.value(for: "k") { await factory.make() }

        let captured = SentinelHolder()
        let removed = await coalescer.remove("k") { value in
            await captured.set(value)
        }
        #expect(removed === stored)
        let disposeRanWith = await captured.value
        #expect(disposeRanWith === stored, "dispose must receive the resolved value")
        let snap = await coalescer.snapshot()
        #expect(snap.resolved == 0 && snap.inFlight == 0 && snap.draining == 0)
    }
}

/// Sendable-safe holder so the dispose closure (which is `@Sendable`) can
/// publish the value it received back to the test thread without crossing
/// the Sendable boundary.
private actor SentinelHolder {
    var value: TaskCoalescerTests.Sentinel?
    func set(_ v: TaskCoalescerTests.Sentinel) { value = v }
}

/// Test-only timestamp helper for `remove_disposeKeepsTombstoneAcrossTeardown`.
/// Used to coordinate "dispose has started" / "dispose has finished" between
/// the test producer (the disposer closure) and the consumer (the assertion
/// thread). Stores a `Date.timeIntervalSinceReferenceDate` in a Sendable-safe
/// way and exposes a tiny wait API instead of a continuation handshake — the
/// drift this introduces is bounded by the sleeps in the test and is
/// negligible compared to the 100 ms dispose window we exercise.
private actor AtomicTimestamp {
    private(set) var value: TimeInterval?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        value = Date.timeIntervalSinceReferenceDate
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    func waitForSet() async {
        if value != nil { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }
}
