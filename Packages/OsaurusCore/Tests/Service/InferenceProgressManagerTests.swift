//
//  InferenceProgressManagerTests.swift
//  osaurusTests
//
//  Tests for InferenceProgressManager — the observable singleton that
//  broadcasts prefill progress to the typing indicator UI.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Tests

@MainActor
struct InferenceProgressManagerTests {

    // Each test creates an isolated InferenceProgressManager via _testMake() so
    // tests don't share state with the global .shared singleton.

    // MARK: prefillWillStart

    @Test func prefillWillStart_setsPrefillTokenCount() {
        let state = InferenceProgressManager._testMake()
        state.prefillWillStart(tokenCount: 42)
        #expect(state.prefillTokenCount == 42)
    }

    @Test func prefillWillStart_setsPrefillStartedAt() {
        let state = InferenceProgressManager._testMake()
        let before = Date()
        state.prefillWillStart(tokenCount: 10)
        let after = Date()
        guard let startedAt = state.prefillStartedAt else {
            Issue.record("prefillStartedAt should be non-nil after prefillWillStart")
            return
        }
        #expect(startedAt >= before)
        #expect(startedAt <= after)
    }

    @Test func prefillWillStart_withZeroCount_showsIndeterminate() {
        let state = InferenceProgressManager._testMake()
        state.prefillWillStart(tokenCount: 0)
        #expect(state.prefillTokenCount == 0)
        #expect(state.prefillStartedAt != nil)
    }

    // MARK: prefillWillStart (second call — count update, preserve startedAt)

    @Test func prefillWillStart_secondCall_updatesCountButPreservesStartedAt() {
        let state = InferenceProgressManager._testMake()
        state.prefillWillStart(tokenCount: 0)
        let firstStartedAt = state.prefillStartedAt

        // Call again with the real count (simulating post-prepareAndGenerate update).
        state.prefillWillStart(tokenCount: 1234)

        #expect(state.prefillTokenCount == 1234)
        // startedAt must not have been reset on the second call.
        #expect(state.prefillStartedAt == firstStartedAt)
    }

    // MARK: prefillDidFinish

    @Test func prefillDidFinish_clearsPrefillTokenCount() {
        let state = InferenceProgressManager._testMake()
        state.prefillWillStart(tokenCount: 99)
        state.prefillDidFinish()
        #expect(state.prefillTokenCount == nil)
    }

    @Test func prefillDidFinish_clearsPrefillStartedAt() {
        let state = InferenceProgressManager._testMake()
        state.prefillWillStart(tokenCount: 99)
        state.prefillDidFinish()
        #expect(state.prefillStartedAt == nil)
    }

    @Test func prefillDidFinish_isIdempotent() {
        let state = InferenceProgressManager._testMake()
        // Called without a prior prefillWillStart — must not crash.
        state.prefillDidFinish()
        #expect(state.prefillTokenCount == nil)
        #expect(state.prefillStartedAt == nil)
    }

    // MARK: round-trip

    @Test func roundTrip_startThenFinishThenStartAgain() {
        let state = InferenceProgressManager._testMake()

        state.prefillWillStart(tokenCount: 100)
        #expect(state.prefillTokenCount == 100)

        state.prefillDidFinish()
        #expect(state.prefillTokenCount == nil)

        // Second round — startedAt should be reset on a fresh start.
        state.prefillWillStart(tokenCount: 200)
        #expect(state.prefillTokenCount == 200)
        #expect(state.prefillStartedAt != nil)
    }

    // MARK: modelLoad refcount (regression — stuck-loading-forever bug)
    //
    // Prior to the refcount fix, `isLoadingModel` was a bare `Bool`.
    // Two concurrent loads racing their start/finish sequences could
    // leave the flag stuck — either stuck `true` (UI stuck at "loading")
    // or stuck `false` while a load was still in flight. These tests
    // lock in the refcount semantics.

    @Test func modelLoad_singleCycle_incrementsThenDecrements() async {
        let state = InferenceProgressManager._testMake()
        #expect(state.loadInFlightCount == 0)
        #expect(state.isLoadingModel == false)

        state.modelLoadWillStartAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 1)
        #expect(state.isLoadingModel == true)

        state.modelLoadDidFinishAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 0)
        #expect(state.isLoadingModel == false)
    }

    @Test func modelLoad_concurrentLoads_requireMatchingFinishes() async {
        let state = InferenceProgressManager._testMake()

        // Window A and Window B both start loads.
        state.modelLoadWillStartAsync()
        state.modelLoadWillStartAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 2)
        #expect(state.isLoadingModel == true)

        // Window A finishes — UI should still show loading because B is mid-load.
        state.modelLoadDidFinishAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 1)
        #expect(state.isLoadingModel == true)

        // Window B finishes — now the UI can clear.
        state.modelLoadDidFinishAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 0)
        #expect(state.isLoadingModel == false)
    }

    @Test func modelLoad_doubleFinishIsFloored_atZero() async {
        let state = InferenceProgressManager._testMake()
        state.modelLoadWillStartAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Simulate a buggy caller that fires didFinish twice.
        state.modelLoadDidFinishAsync()
        state.modelLoadDidFinishAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 0)
        #expect(state.isLoadingModel == false)

        // A subsequent new load must not be poisoned by the earlier
        // double-finish — the flag must still flip back to true.
        state.modelLoadWillStartAsync()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(state.loadInFlightCount == 1)
        #expect(state.isLoadingModel == true)
    }
}
