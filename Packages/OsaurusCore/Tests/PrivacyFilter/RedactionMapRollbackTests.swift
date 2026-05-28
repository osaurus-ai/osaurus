//
//  RedactionMapRollbackTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Regression for the cancel-then-resubmit flow. Detection interns
//  every match into the per-session `RedactionMap` BEFORE the
//  review sheet runs (placeholders are part of the data shown to
//  the user). If the user then taps Cancel, the pipeline must
//  undo those side effects — both the intern entries AND the
//  per-category counter bumps — or the next send sees them in the
//  carry-over set and skips the review dialog, and the user sees
//  index numbers climb (`[PHONE_1]` → `[PHONE_2]` → `[PHONE_3]`)
//  across repeated Cancels of the same value.
//
//  These tests pin the contract on both rollback primitives:
//    * `removeOriginals` drops entries but keeps counters
//      (the "shipped, then Forget redactions" path).
//    * `rollbackToSnapshot` drops entries AND rewinds counters
//      (the cancel-before-send path).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RedactionMap rollback")
struct RedactionMapRollbackTests {

    // MARK: - removeOriginals (counters survive)

    /// `removeOriginals` drops forward + reverse entries but leaves
    /// counters at their current value. Re-interning the same
    /// original mints a NEW index. This is the "append-only
    /// redaction log" primitive used by `Forget redactions`.
    @Test func remove_dropsForwardAndReverse_butDoesNotRewindCounters() async {
        let map = RedactionMap(conversationID: UUID())
        let first = await map.intern("949-238-0232", as: .phone)
        #expect(await map.resolve(token: first.token) == "949-238-0232")

        await map.removeOriginals(["949-238-0232"])
        #expect(await map.resolve(token: first.token) == nil)

        let second = await map.intern("949-238-0232", as: .phone)
        #expect(second.index == first.index + 1, "removeOriginals must not rewind counters")
        #expect(await map.resolve(token: second.token) == "949-238-0232")
    }

    /// Value-precise — pruning one original must not touch others.
    @Test func remove_isValuePrecise() async {
        let map = RedactionMap(conversationID: UUID())
        let phone = await map.intern("949-238-0232", as: .phone)
        let email = await map.intern("alice@example.com", as: .email)

        await map.removeOriginals(["949-238-0232"])

        #expect(await map.resolve(token: phone.token) == nil)
        #expect(await map.resolve(token: email.token) == "alice@example.com")
        let snap = await map.snapshot()
        #expect(snap.count == 1)
        #expect(snap.first?.1 == "alice@example.com")
    }

    /// Empty + unknown sets are no-ops. Defensive guards for the
    /// canceled-path call site, which can hand in either case.
    @Test func remove_emptyAndUnknown_areNoOps() async {
        let map = RedactionMap(conversationID: UUID())
        let phone = await map.intern("949-238-0232", as: .phone)

        await map.removeOriginals([])
        await map.removeOriginals(["not-in-map"])

        #expect(await map.resolve(token: phone.token) == "949-238-0232")
    }

    // MARK: - rollbackToSnapshot (counters rewind)

    /// Three Cancels of the same phone must reuse `[PHONE_1]` every
    /// time, not climb to `[PHONE_2]` / `[PHONE_3]`.
    @Test func rollbackToSnapshot_rewindsCountersAcrossRepeatedCancels() async {
        let map = RedactionMap(conversationID: UUID())
        let preCounters = await map.counterSnapshot

        for _ in 0 ..< 3 {
            let p = await map.intern("949-238-0232", as: .phone)
            #expect(p.index == 1, "counter must rewind on every Cancel")
            await map.rollbackToSnapshot(
                removingOriginals: ["949-238-0232"],
                counters: preCounters
            )
        }
    }

    /// Rollback never wipes counters from prior approved turns. A
    /// canceled phone detection on turn 1 must not let turn 2's new
    /// email take `[EMAIL_1]` — the prior-turn email already
    /// shipped with that index.
    @Test func rollbackToSnapshot_preservesPreviouslyApprovedIndices() async {
        let map = RedactionMap(conversationID: UUID())

        let priorEmail = await map.intern("alice@example.com", as: .email)
        #expect(priorEmail.index == 1)
        let preCounters = await map.counterSnapshot

        _ = await map.intern("alice@example.com", as: .email)
        _ = await map.intern("949-238-0232", as: .phone)

        await map.rollbackToSnapshot(
            removingOriginals: ["949-238-0232"],
            counters: preCounters
        )

        #expect(await map.resolve(token: priorEmail.token) == "alice@example.com")
        let newEmail = await map.intern("bob@example.com", as: .email)
        #expect(newEmail.index == 2, "previously-approved category counter must persist")
    }

    /// Pipeline-shaped scenario: a previously-approved person plus
    /// a new phone on the current turn. Cancel branch computes the
    /// fresh-originals diff and rolls back; the map must return to
    /// its pre-detection shape AND the next intern reuses the same
    /// index.
    @Test func cancelThenResubmit_snapshotMatchesPreState() async {
        let map = RedactionMap(conversationID: UUID())

        _ = await map.intern("Alice", as: .person)
        let preOriginals = Set((await map.snapshot()).map(\.1))
        let preCounters = await map.counterSnapshot

        _ = await map.intern("Alice", as: .person)
        let phone = await map.intern("949-238-0232", as: .phone)
        #expect(phone.index == 1)

        let postOriginals = Set((await map.snapshot()).map(\.1))
        let freshOriginals = postOriginals.subtracting(preOriginals)
        #expect(freshOriginals == ["949-238-0232"])

        await map.rollbackToSnapshot(
            removingOriginals: freshOriginals,
            counters: preCounters
        )

        let afterRollback = Set((await map.snapshot()).map(\.1))
        #expect(afterRollback == preOriginals)

        let resubmittedPhone = await map.intern("949-238-0232", as: .phone)
        #expect(resubmittedPhone.index == 1, "resubmit must reuse [PHONE_1]")
    }
}
