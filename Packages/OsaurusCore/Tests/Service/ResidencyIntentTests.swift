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

    /// The body of `loadContainer`, where every strict-policy eviction lives.
    private static func loadContainerBody() throws -> String {
        let src = try modelRuntimeSource
        let start = try #require(src.range(of: "private func loadContainer("))
        // `loadContainer` is followed by the next `private func` at the same depth.
        let end = try #require(
            src.range(of: "\n    private func ", range: start.upperBound ..< src.endIndex)
        )
        return String(src[start.lowerBound ..< end.lowerBound])
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

        // `loadContainer` runs its residency loop twice: once before
        // `acquireColdLoadSlot()` and once after. The second pass is not
        // redundant — acquiring the slot suspends, the actor is reentrant across
        // it, so state observed before the wait proves nothing after it. Both
        // passes evict, so both passes must guard.
        let evictions = body.components(separatedBy: "await strictEvict(").count - 1
        let cancels = body.components(separatedBy: "await cancelAndDrainLoadingTasks(").count - 1
        let guards =
            body.components(separatedBy: "try refuseBackgroundLoadIfItWouldDisturb(").count - 1

        #expect(evictions == 2, "expected the resident-eviction branch in both residency loops")
        #expect(cancels == 2, "expected the in-flight-cancel branch in both residency loops")
        #expect(
            guards >= evictions + cancels,
            """
            Found \(evictions) evictions + \(cancels) in-flight cancels but only \
            \(guards) guards in loadContainer. Every destructive branch needs its \
            own refusal, in the same actor segment that observed the conflict.
            """
        )
    }

    @Test("The guard precedes the eviction it protects, with no await in between")
    func guardPrecedesEvictionWithoutSuspending() throws {
        let body = try Self.loadContainerBody()

        // For each destructive call, walk back to the nearest guard and assert
        // nothing suspends in the gap. An `await` between them would hand the actor
        // to another task after we decided it was safe to evict.
        for destructive in ["await strictEvict(", "await cancelAndDrainLoadingTasks("] {
            var cursor = body.startIndex
            while let call = body.range(of: destructive, range: cursor ..< body.endIndex) {
                let preceding = String(body[body.startIndex ..< call.lowerBound])
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
