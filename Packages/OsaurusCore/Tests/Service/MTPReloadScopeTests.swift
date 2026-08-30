//
//  MTPReloadScopeTests.swift
//  OsaurusCoreTests
//
//  `loadedModelRuntimeInputsRequireRefresh` compared the whole `mtp` struct,
//  so ANY change to it evicted every resident model. Live: setting Draft
//  Tokens Per Step to 1 and pressing Save took the readout from "MTP depth 2"
//  to "No model loaded" — a full 27B reload for a per-request integer.
//
//  The head's presence IS a load-time fact (mode off vs on, a DFlash 2
//  drafter is different weights). The depth is not.
//

import Testing

@preconcurrency import MLXLMCommon

@testable import OsaurusCore

@Suite("MTP reload scope")
struct MTPReloadScopeTests {

    private func settings(
        mode: VMLXMTPServerMode = .auto,
        limit: Int? = nil,
        drafter: String? = nil
    ) -> VMLXServerMTPSettings {
        VMLXServerMTPSettings(
            mode: mode, draftTokenLimit: limit, dflash2DrafterPath: drafter)
    }

    /// The case that cost a reload for nothing.
    @Test func depthAloneDoesNotForceAReload() {
        #expect(
            !ServerController.mtpLoadInputsChanged(
                previous: settings(limit: nil), next: settings(limit: 1)))
        #expect(
            !ServerController.mtpLoadInputsChanged(
                previous: settings(limit: 1), next: settings(limit: 3)))
    }

    /// Auto and Force-On select between weights that are already loaded.
    @Test func autoToForceOnDoesNotForceAReload() {
        #expect(
            !ServerController.mtpLoadInputsChanged(
                previous: settings(mode: .auto), next: settings(mode: .forceOn)))
    }

    /// Off vs on decides whether the head is in the graph at all.
    @Test func togglingOffOrOnDoesForceAReload() {
        #expect(
            ServerController.mtpLoadInputsChanged(
                previous: settings(mode: .auto), next: settings(mode: .off)))
        #expect(
            ServerController.mtpLoadInputsChanged(
                previous: settings(mode: .off), next: settings(mode: .auto)))
    }

    /// A drafter is a different set of weights.
    @Test func changingTheDrafterForcesAReload() {
        #expect(
            ServerController.mtpLoadInputsChanged(
                previous: settings(), next: settings(drafter: "/tmp/d")))
    }

}
