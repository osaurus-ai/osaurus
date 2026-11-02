//
//  SpeculativeLoadFacts.swift
//  osaurus
//
//  Whether a Speculative Decoding change needs a resident model's weights reloaded.
//

import Foundation
import MLXLMCommon

/// What a Speculative Decoding setting makes one bundle's LOAD contain. `ServerController.mtpLoadInputsChanged`
/// says a settings change MAY alter a load (it does not know the bundle); these facts, resolved per resident model
/// from the same launch plan a load uses, decide whether it does.
///
/// Measured cost of an unneeded reload (MiniMax-M3.1-Flash-JANGHT1.9, 95 GB, M5 Max GUI runs 2026-10-29): 13.6-14.4 s
/// per reload, and every switch of the row paid one (Off (AR) <-> On (Adaptive), and the untouched default -> an
/// explicit On, which loads the same drafter).
struct SpeculativeLoadFacts: Sendable, Equatable {
    /// The native MTP head is in the graph (`LoadConfiguration.nativeMTP`): a real load input.
    var nativeMTPInGraph: Bool
    var nativeMTPManualDepth: Int?
    /// The loaded strategy's identity; nil = plain decoding.
    var strategy: Strategy?

    struct Strategy: Sendable, Equatable {
        /// `DraftStrategy.kindName`.
        var kind: String
        /// The drafter / adapter directory, standardized (DSpark, DFlash 2, Uno).
        var drafterPath: String?
        /// A load-time width (DFlash 2 / Uno block size). Native MTP depth is resolved per request and is not part
        /// of the load.
        var blockSize: Int?
        /// A strategy carrying a live object (an external draft model) never compares equal.
        var opaque = false
    }

    init(nativeMTPInGraph: Bool, nativeMTPManualDepth: Int?, strategy: Strategy?) {
        self.nativeMTPInGraph = nativeMTPInGraph
        self.nativeMTPManualDepth = nativeMTPManualDepth
        self.strategy = strategy
    }

    init(loadConfiguration: LoadConfiguration, draftStrategy: MLXLMCommon.DraftStrategy?) {
        self.init(
            nativeMTPInGraph: loadConfiguration.nativeMTP,
            nativeMTPManualDepth: loadConfiguration.nativeMTPManualDepth,
            strategy: Self.identity(draftStrategy))
    }

    static func identity(_ strategy: MLXLMCommon.DraftStrategy?) -> Strategy? {
        guard let strategy else { return nil }
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        switch strategy {
        case .none:
            return nil
        case .nativeMTP:
            return Strategy(kind: strategy.kindName)
        case .dspark(let drafter):
            return Strategy(kind: strategy.kindName, drafterPath: path(drafter))
        case .dflash2(let drafter, let blockSize):
            return Strategy(kind: strategy.kindName, drafterPath: path(drafter), blockSize: blockSize)
        case .uno(let adapter, let blockSize):
            return Strategy(kind: strategy.kindName, drafterPath: path(adapter), blockSize: blockSize)
        case .dflash(let drafter, let blockSize):
            return Strategy(kind: strategy.kindName, drafterPath: path(drafter), blockSize: blockSize)
        case .ddtree(let drafter, _, let blockSize):
            return Strategy(kind: strategy.kindName, drafterPath: path(drafter), blockSize: blockSize, opaque: true)
        case .autoregressive:
            return Strategy(kind: strategy.kindName, opaque: true)
        }
    }

    /// True when a resident model loaded with `loaded` already has everything `next` selects, so the setting
    /// change must NOT unload it:
    /// * the graph is the same (native MTP head in or out, manual depth), and
    /// * the strategy is the same (native MTP depth is per request), or the change only adds or drops a
    ///   lazily attached DSpark drafter. vmlx attaches a bundle's `dspark/` drafter to the loaded target on the
    ///   first request that names it (`TokenIterator.attachDSparkIfRequested`) and runs it only for requests that
    ///   name it; a request without a strategy decodes plain AR on the same weights. Off (AR) <-> On (Adaptive) on
    ///   a DSpark bundle therefore changes only what each request names (`ModelRuntime.requestDraftStrategy`
    ///   returns nil for Off).
    /// Everything else (a DFlash 2 / Uno drafter appearing or changing, a different DSpark drafter, the native head
    /// entering or leaving the graph) still reloads, as before.
    static let dsparkKind = "dspark"

    static func keepsResidentWeights(loaded: SpeculativeLoadFacts, next: SpeculativeLoadFacts) -> Bool {
        guard loaded.nativeMTPInGraph == next.nativeMTPInGraph,
            loaded.nativeMTPManualDepth == next.nativeMTPManualDepth
        else { return false }
        if loaded.strategy?.opaque == true || next.strategy?.opaque == true { return false }
        if loaded.strategy == next.strategy { return true }
        switch (loaded.strategy, next.strategy) {
        case (nil, .some(let added)):
            return added.kind == dsparkKind
        case (.some(let dropped), nil):
            return dropped.kind == dsparkKind
        default:
            return false
        }
    }

    /// What a resident model serves speculatively: its loaded strategy, the admission evidence requests are
    /// re-resolved against, and the facts of its load.
    struct Resident: Sendable {
        var strategy: MLXLMCommon.DraftStrategy?
        var admission: NativeMTPAdmission
        var facts: SpeculativeLoadFacts
    }

    /// The resident state after a change `keepsResidentWeights` kept: a selection that names a strategy adopts it
    /// with its admission evidence, exactly as a load under it would; Off (no strategy) keeps the attachable
    /// drafter, because requests under Off carry no strategy anyway (`ModelRuntime.requestDraftStrategy`,
    /// `NativeMTPAdmission.requestStrategy`), and switching back On then needs nothing new.
    static func residentAfterKeptChange(resident: Resident, next: Resident) -> Resident {
        next.strategy == nil ? resident : next
    }
}
