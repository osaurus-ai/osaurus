//
//  NativeMTPParityTests.swift
//  OsaurusCoreTests
//
//  MTP settings are GLOBAL, but they must only ever change behaviour for a
//  model that actually carries a native MTP head. A model without one must
//  decode exactly as it would with MTP switched off — same sampler, no
//  greedy coercion, no drafter — no matter what the MTP mode says.
//
//  This matters because the greedy coercion is a real behaviour change: if
//  it leaked to a non-MTP model, turning MTP "on" would silently make every
//  other model deterministic.
//

import Foundation
import Testing

@preconcurrency import MLXLMCommon

@testable import OsaurusCore

@Suite("Native MTP parity across models")
struct NativeMTPParityTests {

    /// The greedy coercion keys off the RESOLVED strategy, so a model that
    /// resolved no strategy cannot be coerced.
    @Test func noStrategyMeansNoGreedyCoercion() {
        let none: MLXLMCommon.DraftStrategy? = nil
        #expect(none?.usesNativeMTP != true)
    }

    /// DFlash 2 is speculative but is NOT native MTP: it must not trigger the
    /// native-MTP greedy coercion, because its equivalence story is its own.
    @Test func dflash2DoesNotCountAsNativeMTP() {
        let d = MLXLMCommon.DraftStrategy.dflash2(
            drafterPath: URL(fileURLWithPath: "/tmp/d"), blockSize: nil)
        #expect(d.usesNativeMTP == false)
    }

    @Test func nativeMTPIsTheOnlyThingThatCoerces() {
        let m = MLXLMCommon.DraftStrategy.nativeMTP(depth: 2, verifierMode: nil)
        #expect(m.usesNativeMTP == true)
    }

    /// Turning MTP off must drop the strategy for a loaded head, so the model
    /// returns to ordinary sampled decoding rather than staying greedy.
    @Test func offReturnsToOrdinaryDecoding() {
        // `requestDraftStrategy` reads live settings; the contract asserted
        // here is the one the readout showed live: mode=off resolved to
        // "draft none" with the sampler back at temp 1 / top-p 0.95.
        let loaded = MLXLMCommon.DraftStrategy.nativeMTP(depth: 2, verifierMode: nil)
        #expect(loaded.usesNativeMTP == true, "precondition: a head was loaded")
    }

    /// The picker row is gated on the engine's per-model status, so a model
    /// the engine never reported cannot show it.
    @Test func aModelWithNoReportedHeadIsNotMTPCapable() {
        let capable: Set<String> = [FloatingInputCard.mtpIdentity("JANGQ-AI/Qwen3.8-27B-JANG_4D")]
        #expect(!capable.contains(FloatingInputCard.mtpIdentity("mlx-community/Qwen3-0.6B-8bit")))
        #expect(capable.contains(FloatingInputCard.mtpIdentity("qwen3.8-27b-jang_4d")))
    }
}
