// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// The runtime is strictly single-model: loading B evicts resident A and cancels
/// an in-flight load of A. `ModelLoadIntent` decides who is allowed to do that.
///
/// The whole guarantee rests on one property that is easy to break by accident and
/// impossible to see in a passing behavioural test: **the refusal must happen in
/// the same actor segment that observed the conflict.** `ModelRuntime` is an actor,
/// so it is reentrant across every `await`. A guard that suspends — even once,
/// even "briefly" — lets another task register a load or finish one in the gap,
/// and the eviction it was supposed to prevent happens anyway.
///
/// That is precisely the bug these tests exist to stop from coming back: the
/// previous fix probed `hasLoadInFlight()` / `hasResidentModelOther(than:)` from
/// *outside* the actor and then loaded on a later hop. Check-then-act. It read as
/// correct and shipped.
@Suite("Model residency intent")
struct ResidencyIntentTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static var modelRuntimeSource: String {
        get throws { try source("Services/ModelRuntime.swift") }
    }

    private static func functionBody(startingWith signature: String) throws -> String {
        let src = try modelRuntimeSource
        let start = try #require(src.range(of: signature))
        let end = try #require(
            src.range(of: "\n    private func ", range: start.upperBound ..< src.endIndex)
        )
        return String(src[start.lowerBound ..< end.lowerBound])
    }

    /// The body of `loadContainer`, where every strict-policy eviction lives.
    private static func loadContainerBody() throws -> String {
        try functionBody(startingWith: "private func loadContainer(")
    }

    // MARK: - The atomicity invariant

    @Test("The refusal is synchronous, so it cannot be interleaved")
    func refusalIsSynchronous() throws {
        let src = try Self.modelRuntimeSource
        let signature = try #require(
            src.range(of: "private func refuseBackgroundLoadIfItWouldDisturb(")
        )
        // Everything up to the opening brace of the body.
        let header = String(src[signature.lowerBound ..< src.endIndex].prefix(400))
        let bodyStart = try #require(header.range(of: ") throws {"))
        let declaration = String(header[header.startIndex ..< bodyStart.upperBound])

        // If this ever becomes `async`, the guard can suspend between observing the
        // conflicting state and throwing — and the actor will happily run another
        // load in that window. The refusal would still "work" in every test and
        // still lose the user's model in production.
        #expect(
            !declaration.contains("async"),
            """
            refuseBackgroundLoadIfItWouldDisturb must stay synchronous. An actor \
            only guarantees mutual exclusion within a segment that contains no \
            `await`; making this async reopens the check-then-act race it exists \
            to close.
            """
        )
    }

    @Test("Every strict-policy eviction is guarded, in both loops")
    func everyEvictionIsGuarded() throws {
        let body = try Self.loadContainerBody()
        let resolver = try Self.functionBody(startingWith: "private func resolveConflictingLoad(")

        // `loadContainer` runs its residency loop twice: once before
        // `acquireColdLoadSlot()` and once after. The second pass is not
        // redundant — acquiring the slot suspends, the actor is reentrant across
        // it, so state observed before the wait proves nothing after it. Both
        // passes evict, so both passes must guard.
        let evictions = body.components(separatedBy: "await strictEvict(").count - 1
        let resolverCalls = body.components(separatedBy: "resolveConflictingLoad(").count - 1
        let cancels = resolver.components(separatedBy: "await cancelAndDrainLoadingTasks(").count - 1
        let resolverGuards =
            resolver.components(separatedBy: "try refuseBackgroundLoadIfItWouldDisturb(").count - 1
        let evictionGuards =
            body.components(separatedBy: "try refuseBackgroundLoadIfItWouldDisturb(").count - 1

        #expect(evictions == 2, "expected the resident-eviction branch in both residency loops")
        #expect(resolverCalls == 2, "both residency loops must use the shared conflict resolver")
        #expect(cancels == 1, "the shared resolver must own exactly one in-flight-cancel branch")
        #expect(resolverGuards == 1, "the shared in-flight-cancel branch must have one refusal")
        #expect(evictionGuards == 2, "both resident-eviction branches must retain their refusal")
    }

    @Test("The guard precedes the eviction it protects, with no await in between")
    func guardPrecedesEvictionWithoutSuspending() throws {
        let body = try Self.loadContainerBody()
        let resolver = try Self.functionBody(startingWith: "private func resolveConflictingLoad(")

        // For each destructive call, walk back to the nearest guard and assert
        // nothing suspends in the gap. An `await` between them would hand the actor
        // to another task after we decided it was safe to evict.
        func assertGuard(in source: String, before destructive: String) throws {
            var cursor = source.startIndex
            while let call = source.range(of: destructive, range: cursor ..< source.endIndex) {
                let preceding = String(source[source.startIndex ..< call.lowerBound])
                let lastGuard = try #require(
                    preceding.range(of: "try refuseBackgroundLoadIfItWouldDisturb(", options: .backwards),
                    "\(destructive) is not preceded by a residency guard"
                )
                let between = String(preceding[lastGuard.upperBound ..< preceding.endIndex])
                #expect(
                    !between.contains("await "),
                    """
                    An `await` sits between the residency guard and \(destructive). \
                    The actor can reschedule there, so the state the guard approved \
                    is not the state being evicted.
                    """
                )
                cursor = call.upperBound
            }
        }

        try assertGuard(in: body, before: "await strictEvict(")
        try assertGuard(in: resolver, before: "await cancelAndDrainLoadingTasks(")
    }

    @Test("Flexible (manualMultiModel) residency is guarded too")
    func flexibleBudgetEvictionIsGuarded() throws {
        let src = try Self.modelRuntimeSource
        let start = try #require(src.range(of: "private func unloadForFlexibleResidentBudget("))
        let end = try #require(
            src.range(of: "\n    private func ", range: start.upperBound ..< src.endIndex)
        )
        let body = String(src[start.lowerBound ..< end.lowerBound])

        // Without this the contract "background never disturbs a resident model"
        // would silently hold only under the default eviction policy — anyone on
        // manualMultiModel would keep the original bug.
        #expect(body.contains("try refuseBackgroundLoadIfItWouldDisturb("))
        #expect(body.contains("intent: ModelLoadIntent"))
    }

    // MARK: - Defaults: the safe direction

    @Test("Loads are interactive unless a caller opts into background")
    func loadIntentDefaultsToInteractive() throws {
        let params = GenerationParameters(temperature: 0.0, maxTokens: 16)
        // Defaulting to `.background` would be the dangerous direction: a real user
        // request that forgot to set the flag would silently refuse to load.
        #expect(params.loadIntent == .interactive)

        // Decoding an ordinary API request must not be able to turn the flag on:
        // it is local-only. A remote client that could set it would be able to make
        // its own requests refuse to load — or, worse, if the sense were ever
        // inverted, evict on demand.
        let wire = #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#
        let request = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: Data(wire.utf8)
        )
        #expect(request.backgroundModelLoad == false)
        #expect(request.preserveExistingResidencyOwner == false)
    }

    @Test("Background housekeeping actually reaches the runtime as background")
    func backgroundRequestCarriesTheIntent() {
        let params = GenerationParameters(
            temperature: 0.1,
            maxTokens: 64,
            loadIntent: .background
        )
        #expect(params.loadIntent == .background)
    }

    @Test("Handoff restore waits for conflicting cold loads instead of cancelling them")
    func handoffRestoreHasDedicatedNonCancellingPath() throws {
        let source = try Self.modelRuntimeSource
        #expect(
            source.contains("intent != .handoffRestore"),
            "the shared conflict resolver must exclude handoff restoration from cancellation"
        )
        #expect(source.contains("awaitConflictingLoadWithoutCancellation("))
        #expect(
            source.components(separatedBy: "resolveConflictingLoad(").count - 1 == 3,
            "one declaration plus both pre-slot and post-slot calls must use the shared resolver"
        )
    }

    // MARK: - The intent must survive the trip, and must expire

    @Test("Copying a request keeps its background flag")
    func copyHelpersPreserveBackgroundIntent() throws {
        let src = try Self.source("Models/API/OpenAIAPI.swift")

        // `withModel` and `withContext` rebuild the request field by field. Both
        // already carry the other local-only flags. Omitting this one silently
        // PROMOTES a background request to interactive — and interactive requests
        // are the ones allowed to evict a model someone is using. A dropped flag
        // here undoes the entire guard, quietly, with no failing test anywhere.
        let copies = src.components(separatedBy: "copy.backgroundModelLoad = backgroundModelLoad")
            .count - 1
        let ownerCopies = src.components(
            separatedBy:
                "copy.preserveExistingResidencyOwner = preserveExistingResidencyOwner"
        ).count - 1
        let helpers = src.components(separatedBy: "copy.warmupPrefill = warmupPrefill").count - 1
        #expect(helpers == 2, "expected withModel + withContext to copy local-only flags")
        #expect(
            copies == helpers,
            """
            \(helpers) request-copy helpers but only \(copies) copy \
            `backgroundModelLoad`. A helper that drops it turns background \
            housekeeping back into an eviction-entitled interactive request.
            """
        )
        #expect(
            ownerCopies == helpers,
            "every request-copy helper must preserve the nested residency-owner policy"
        )
    }

    @Test("nested requests preserve an existing non-chat residency owner")
    func nestedRequestPreservesExistingResidencyOwner() {
        #expect(ModelRuntime.isChatOwnedResidencySource(nil))
        #expect(ModelRuntime.isChatOwnedResidencySource(.chatUI))
        #expect(!ModelRuntime.isChatOwnedResidencySource(.httpAPI))
        #expect(!ModelRuntime.isChatOwnedResidencySource(.plugin))
        #expect(!ModelRuntime.isChatOwnedResidencySource(.p2p))
        #expect(!ModelRuntime.isChatOwnedResidencySource(.scheduled))

        #expect(
            ModelRuntime.resolvedResidencySource(
                existing: .httpAPI,
                incoming: .chatUI,
                preserveExisting: true
            ) == .httpAPI
        )
        #expect(
            ModelRuntime.resolvedResidencySource(
                existing: nil,
                incoming: .chatUI,
                preserveExisting: true
            ) == .chatUI
        )
        #expect(
            ModelRuntime.resolvedResidencySource(
                existing: .httpAPI,
                incoming: .chatUI,
                preserveExisting: false
            ) == .chatUI
        )
    }

    @Test("subagent loads preserve ownership and reclaim only the invoking source")
    func subagentLoadsUseProtectedRuntimeIntent() throws {
        let runner = try Self.source(
            "Services/AgentDelegation/AgentSubagentRunner.swift"
        )
        #expect(runner.contains("request.backgroundModelLoad = true"))
        #expect(runner.contains("request.preserveExistingResidencyOwner = true"))

        let handoff = try Self.source(
            "Services/AgentDelegation/ChatResidencyHandoff.swift"
        )
        #expect(handoff.contains("ChatExecutionContext.currentSessionSource?.inferenceSource"))
        #expect(handoff.contains("ownedBy: currentInferenceSource"))
        #expect(handoff.contains("isChatOwnedResident("))

        let residency = try Self.source("Subagent/SubagentResidency.swift")
        #expect(residency.contains("ChatExecutionContext.currentSessionSource?.inferenceSource"))
        #expect(residency.contains("ownedBy: inferenceSource"))
        #expect(residency.contains("protectedResidentModels"))
    }

    @Test("The user's warm-up privilege is one-shot, not permanent")
    func userIntentGrantIsConsumed() throws {
        let src = try Self.source("Services/Chat/ChatWarmupController.swift")

        // `userIntentWarmupModel` records "the user just picked this by hand", which
        // entitles the follow-up warm-up to displace a resident model. It used to be
        // set and never cleared — so "the user picked A once" silently became "any
        // warm-up of A, forever, may evict", and a re-warm minutes later, triggered
        // by nothing the user did, could still unload an API client's model. The
        // grant has to expire with the intent that created it.
        #expect(
            src.contains("private func consumeUserIntent(for model: String) -> Bool"),
            "the user-intent grant must be consumed, not merely compared against"
        )
        #expect(
            src.contains("userIntentWarmupModel = nil"),
            "consuming the grant must clear it"
        )

        // And it must be resolved once and threaded, not re-derived at each use —
        // two independent comparisons against a mutable field can disagree.
        #expect(src.contains("let userIntent = consumeUserIntent(for: payload.model)"))
        #expect(src.contains("request.backgroundModelLoad = !userIntent"))
        #expect(
            !src.contains("payload.model != userIntentWarmupModel"),
            "no site may re-derive user intent by comparing the raw field"
        )
    }

    // MARK: - The refusal is legible

    @Test("A refusal says which model it protected and why")
    func refusalDescribesTheConflict() {
        let evict = ModelRuntime.ResidencyRefusedError(
            requestedModel: "tiny-helper",
            conflict: .wouldEvictResident("hy3-94gb")
        )
        let description = try! #require(evict.errorDescription)
        #expect(description.contains("tiny-helper"))
        #expect(description.contains("hy3-94gb"))

        let cancel = ModelRuntime.ResidencyRefusedError(
            requestedModel: "tiny-helper",
            conflict: .wouldCancelLoadInFlight("hy3-94gb")
        )
        #expect(cancel != evict)
        #expect(try! #require(cancel.errorDescription).contains("in-flight"))
    }
}
