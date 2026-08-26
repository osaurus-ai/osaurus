//
//  MTPResolvedStateReadoutTests.swift
//  OsaurusCoreTests
//
//  The MTP Mode picker is an INPUT to resolution, never a description of it.
//  A bundle whose tuning artifact never asserted `output_equivalent` cannot
//  run speculative decoding even on Force-On, and a Draft-Tokens limit can
//  only LOWER the artifact's depth. Both behaviours are correct; both were
//  invisible, so the picker read as inert on exactly the models where it
//  could not apply.
//

import Testing

@testable import OsaurusCore

@Suite("MTP resolved-state readout")
struct MTPResolvedStateReadoutTests {

    @Test func namesTheDepthWhenSpeculativeDecodingIsLive() {
        #expect(MTPSection.resolvedValue(depth: 2, strategy: "nativeMTP") == "MTP depth 2")
    }

    /// Depth 0 is not "a shallow MTP" — it is no MTP. Printing "MTP depth 0"
    /// would claim a drafter that is not running.
    @Test func depthZeroIsOffNotDepthZero() {
        #expect(MTPSection.resolvedValue(depth: 0, strategy: nil) == "Off")
    }

    /// A selected DFlash 2 drafter replaces the native head, so the readout
    /// must name the drafter rather than falling through to "Off".
    @Test func namesTheDrafterThatReplacedTheNativeHead() {
        #expect(MTPSection.resolvedValue(depth: nil, strategy: "dflash2") == "dflash2")
    }

    /// The engine's own "no drafter" spelling must not be echoed back as if it
    /// were a drafter name.
    @Test func theWordNoneIsNotADrafterName() {
        #expect(MTPSection.resolvedValue(depth: nil, strategy: "none") == "Off")
        #expect(MTPSection.resolvedValue(depth: nil, strategy: "") == "Off")
    }

    /// Never blank. A missing value is indistinguishable from a broken
    /// readout, which is how this gap survived in the first place.
    @Test func alwaysSaysSomething() {
        #expect(!MTPSection.resolvedValue(depth: nil, strategy: nil).isEmpty)
    }
}
