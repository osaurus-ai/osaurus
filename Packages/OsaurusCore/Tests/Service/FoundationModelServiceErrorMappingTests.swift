//
//  FoundationModelServiceErrorMappingTests.swift
//  OsaurusCoreTests
//
//  Pins the typed-error surface `FoundationModelService` exposes to the
//  routing layer: which `LanguageModelSession.GenerationError` cases map to
//  which `FoundationGenerationFailure`, which of those are worth a retry,
//  and that the availability probe carries the framework's reason instead
//  of a bare boolean.
//

import Foundation
import Testing

@testable import OsaurusCore

#if canImport(FoundationModels)
    import FoundationModels
#endif

struct FoundationModelServiceErrorMappingTests {

    @Test("only rate limiting and concurrency are transient")
    func transience() {
        let transient: [FoundationGenerationFailure] = [.rateLimited, .concurrentRequests]
        let permanent: [FoundationGenerationFailure] = [
            .exceededContextWindowSize, .assetsUnavailable, .guardrailViolation, .unsupportedGuide,
            .unsupportedLanguageOrLocale, .decodingFailure, .refusal, .unknown,
        ]
        for failure in transient {
            #expect(failure.isTransient, "\(failure) should be retryable")
            #expect(FoundationModelServiceError.generation(failure, detail: "").isTransient)
        }
        for failure in permanent {
            #expect(!failure.isTransient, "\(failure) should not be retried")
            #expect(!FoundationModelServiceError.generation(failure, detail: "").isTransient)
        }
        // An unavailable model never becomes available within a retry backoff.
        for reason: FoundationUnavailableReason in [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .osTooOld, .frameworkMissing,
            .unknown,
        ] {
            #expect(!FoundationModelServiceError.notAvailable(reason).isTransient)
        }
    }

    @Test("availability probe agrees with the boolean and names a reason when unavailable")
    func availabilityProbe() {
        let availability = FoundationModelService.defaultModelAvailability()
        #expect(availability.isAvailable == FoundationModelService.isDefaultModelAvailable())
        switch availability {
        case .available:
            #expect(availability.unavailableReason == nil)
        case .unavailable(let reason):
            #expect(!reason.userDescription.isEmpty)
            #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    // On a 26+ SDK/OS the only reasons are the framework's own.
                    #expect(
                        [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unknown]
                            .contains(reason))
                } else {
                    #expect(reason == .osTooOld)
                }
            #else
                #expect(reason == .frameworkMissing)
            #endif
        }
    }

    @Test("every unavailability reason has a distinct user-facing description")
    func reasonDescriptionsAreDistinct() {
        let reasons: [FoundationUnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .osTooOld, .frameworkMissing,
            .unknown,
        ]
        let descriptions = Set(reasons.map(\.userDescription))
        #expect(descriptions.count == reasons.count)
        #expect(
            FoundationUnavailableReason.appleIntelligenceNotEnabled.userDescription.contains("System Settings"))
    }

    @Test("typed errors pass through mapping; cancellation and unknown errors are untouched")
    func passthrough() {
        let typed = FoundationModelServiceError.generation(.refusal, detail: "x")
        #expect(FoundationModelService.mapFrameworkError(typed) as? FoundationModelServiceError == typed)
        #expect(FoundationModelService.mapFrameworkError(CancellationError()) is CancellationError)
        struct Other: Error {}
        #expect(FoundationModelService.mapFrameworkError(Other()) is Other)
    }

    #if canImport(FoundationModels)
        @Test("framework GenerationError cases map one-to-one")
        func frameworkMapping() throws {
            guard #available(macOS 26.0, *) else { return }
            let ctx = LanguageModelSession.GenerationError.Context(debugDescription: "detail")
            let cases: [(LanguageModelSession.GenerationError, FoundationGenerationFailure)] = [
                (.exceededContextWindowSize(ctx), .exceededContextWindowSize),
                (.assetsUnavailable(ctx), .assetsUnavailable),
                (.guardrailViolation(ctx), .guardrailViolation),
                (.unsupportedGuide(ctx), .unsupportedGuide),
                (.unsupportedLanguageOrLocale(ctx), .unsupportedLanguageOrLocale),
                (.decodingFailure(ctx), .decodingFailure),
                (.rateLimited(ctx), .rateLimited),
                (.concurrentRequests(ctx), .concurrentRequests),
                (.refusal(.init(transcriptEntries: []), ctx), .refusal),
            ]
            for (framework, expected) in cases {
                let mapped = FoundationModelService.map(framework)
                #expect(mapped == .generation(expected, detail: "detail"))
                // The generic entry point must reach the same result.
                let viaGeneric = try #require(
                    FoundationModelService.mapFrameworkError(framework) as? FoundationModelServiceError)
                #expect(viaGeneric == mapped)
                #expect(mapped.errorDescription?.contains("detail") == true)
            }
        }
    #endif
}
