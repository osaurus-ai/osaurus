//
//  ChipProfileTests.swift
//  osaurusTests
//
//  Covers the pure brand-string parser (every shipped Apple Silicon tier,
//  future generations, and non-Apple fallbacks) plus the invariants the
//  policy layer will rely on: `policyTier` never returns `.unknown`, and
//  the neural-accelerator flag flips exactly at the M5 generation.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChipProfileTests {

    // MARK: - Brand-string parsing

    @Test func parsesEveryShippedTier() {
        #expect(ChipProfile.parse(brandString: "Apple M1") == (1, .base))
        #expect(ChipProfile.parse(brandString: "Apple M1 Pro") == (1, .pro))
        #expect(ChipProfile.parse(brandString: "Apple M1 Max") == (1, .max))
        #expect(ChipProfile.parse(brandString: "Apple M1 Ultra") == (1, .ultra))
        #expect(ChipProfile.parse(brandString: "Apple M3 Pro") == (3, .pro))
        #expect(ChipProfile.parse(brandString: "Apple M4") == (4, .base))
        #expect(ChipProfile.parse(brandString: "Apple M5 Max") == (5, .max))
        #expect(ChipProfile.parse(brandString: "Apple M5 Ultra") == (5, .ultra))
    }

    @Test func parsesFutureGenerationsWithoutACodeChange() {
        #expect(ChipProfile.parse(brandString: "Apple M6 Pro") == (6, .pro))
        #expect(ChipProfile.parse(brandString: "Apple M12") == (12, .base))
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(ChipProfile.parse(brandString: "  Apple M2 Ultra\n") == (2, .ultra))
    }

    @Test func rejectsNonAppleSiliconBrandStrings() {
        let intel = ChipProfile.parse(
            brandString: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz")
        #expect(intel.generation == nil)
        #expect(intel.tier == .unknown)

        // Unknown suffixes and adulterated strings must not half-match:
        // policy code prefers "unknown, be conservative" over a wrong tier.
        #expect(ChipProfile.parse(brandString: "Apple M4 Extreme").tier == .unknown)
        #expect(ChipProfile.parse(brandString: "VirtualApple M2 Pro").tier == .unknown)
        #expect(ChipProfile.parse(brandString: "").tier == .unknown)
    }

    // MARK: - Chassis parsing

    @Test func classifiesLaptopIdentifiers() {
        #expect(ChipProfile.parseChassis(modelIdentifier: "MacBookPro18,3") == .laptop)
        #expect(ChipProfile.parseChassis(modelIdentifier: "MacBookAir10,1") == .laptop)
        #expect(ChipProfile.parseChassis(modelIdentifier: "MacBook10,1") == .laptop)
    }

    @Test func classifiesDesktopIdentifiers() {
        #expect(ChipProfile.parseChassis(modelIdentifier: "Macmini9,1") == .desktop)
        #expect(ChipProfile.parseChassis(modelIdentifier: "Mac13,2") == .unknown)  // pre-fallback Studio
        #expect(ChipProfile.parseChassis(modelIdentifier: "MacPro7,1") == .desktop)
        // Intel-era identifiers still classify without the IOKit fallback.
        #expect(ChipProfile.parseChassis(modelIdentifier: "iMac19,1") == .desktop)
        #expect(ChipProfile.parseChassis(modelIdentifier: "iMacPro1,1") == .desktop)
    }

    @Test func opaqueIdentifiersResolveViaProductNameFallback() {
        // 2022+ identifiers encode nothing about the enclosure; only the
        // IOKit marketing name can disambiguate. Note the marketing form
        // has spaces ("Mac mini") that the hw.model form lacks.
        #expect(
            ChipProfile.parseChassis(modelIdentifier: "Mac14,12", productName: "Mac mini")
                == .desktop)
        #expect(
            ChipProfile.parseChassis(modelIdentifier: "Mac14,12", productName: "MacBook Pro")
                == .laptop)
        #expect(
            ChipProfile.parseChassis(modelIdentifier: "Mac13,2", productName: "Mac Studio")
                == .desktop)
        #expect(
            ChipProfile.parseChassis(
                modelIdentifier: "Mac16,6", productName: "MacBook Pro (14-inch, Nov 2024)")
                == .laptop)
    }

    @Test func unresolvableIdentifiersStayUnknown() {
        // No product name available (Intel VMs, stripped registry).
        #expect(ChipProfile.parseChassis(modelIdentifier: "Mac14,12") == .unknown)
        #expect(ChipProfile.parseChassis(modelIdentifier: "Mac14,12", productName: nil) == .unknown)
        // Product name present but equally opaque.
        #expect(
            ChipProfile.parseChassis(
                modelIdentifier: "VirtualMac2,1",
                productName: "Apple Virtualization Generic Platform"
            ) == .unknown)
        #expect(ChipProfile.parseChassis(modelIdentifier: "Xserve3,1") == .unknown)
        #expect(ChipProfile.parseChassis(modelIdentifier: "") == .unknown)
        #expect(ChipProfile.parseChassis(modelIdentifier: "", productName: "") == .unknown)
    }

    // MARK: - Policy invariants

    @Test func policyTierNeverExposesUnknown() {
        let unknown = ChipProfile(
            brandString: "Intel(R) Xeon(R)",
            generation: nil,
            tier: .unknown,
            physicalMemoryBytes: 8 << 30,
            gpuCoreCount: nil,
            recommendedMaxWorkingSetBytes: nil,
            chassis: .unknown
        )
        #expect(unknown.policyTier == .base)

        let known = ChipProfile(
            brandString: "Apple M5 Max",
            generation: 5,
            tier: .max,
            physicalMemoryBytes: 128 << 30,
            gpuCoreCount: 40,
            recommendedMaxWorkingSetBytes: 100 << 30,
            chassis: .desktop
        )
        #expect(known.policyTier == .max)
    }

    @Test func neuralAcceleratorFlagFlipsAtM5() {
        func profile(generation: Int?) -> ChipProfile {
            ChipProfile(
                brandString: "test",
                generation: generation,
                tier: .base,
                physicalMemoryBytes: 16 << 30,
                gpuCoreCount: nil,
                recommendedMaxWorkingSetBytes: nil,
                chassis: .unknown
            )
        }
        #expect(!profile(generation: 4).hasGPUNeuralAccelerators)
        #expect(profile(generation: 5).hasGPUNeuralAccelerators)
        #expect(profile(generation: 6).hasGPUNeuralAccelerators)
        #expect(!profile(generation: nil).hasGPUNeuralAccelerators)
    }

    // MARK: - Live detection smoke test (runs on whatever hardware CI has)

    @Test func detectReturnsInternallyConsistentProfile() {
        let profile = ChipProfile.detect()
        #expect(!profile.brandString.isEmpty)
        #expect(profile.physicalMemoryBytes > 0)
        if let cores = profile.gpuCoreCount {
            #expect(cores > 0)
        }
        // JSON surface must serialize (guards against a non-plist value
        // sneaking into the /health object).
        let json = profile.healthJSONObject()
        #expect(JSONSerialization.isValidJSONObject(json))
        #expect(json["chassis"] as? String == profile.chassis.rawValue)
    }
}
