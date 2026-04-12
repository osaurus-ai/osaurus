//
//  ModelRuntimeAdaptiveKVTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelRuntimeAdaptiveKVTests {

    @Test
    func metalAllocationFailureBytes_parsesRequestedAndAllowedSizes() {
        let description =
            "MLX Error: [metal::malloc] Attempting to allocate 95901702400 bytes which is greater than the maximum allowed buffer size of 86586540032 bytes."

        let parsed = ModelRuntime.metalAllocationFailureBytes(from: description)

        #expect(parsed?.requestedBytes == 95_901_702_400)
        #expect(parsed?.allowedBytes == 86_586_540_032)
    }

    @Test
    func adaptiveMaxKVForMetalAllocationFailure_scalesDownUsingReportedBufferLimit() {
        let description =
            "MLX Error: [metal::malloc] Attempting to allocate 95901702400 bytes which is greater than the maximum allowed buffer size of 86586540032 bytes."

        let reduced = ModelRuntime.adaptiveMaxKVForMetalAllocationFailure(
            currentMaxKV: 65_536,
            errorDescription: description
        )

        #expect(reduced == 53_248)
    }

    @Test
    func adaptiveMaxKVForMetalAllocationFailure_halvesWhenBytesCannotBeParsed() {
        let description = "MLX Error: [metal::malloc] maximum allowed buffer size exceeded"

        let reduced = ModelRuntime.adaptiveMaxKVForMetalAllocationFailure(
            currentMaxKV: 65_536,
            errorDescription: description
        )

        #expect(reduced == 32_768)
    }

    @Test
    func adaptiveMaxKVForMetalAllocationFailure_ignoresNonMetalErrors() {
        let reduced = ModelRuntime.adaptiveMaxKVForMetalAllocationFailure(
            currentMaxKV: 65_536,
            errorDescription: "Tokenizer produced no tokens for the given input"
        )

        #expect(reduced == nil)
    }

    @Test
    func adaptivePrefillStepForMetalAllocationFailure_halvesUntilFloor() {
        let description =
            "MLX Error: [metal::malloc] Attempting to allocate 95901702400 bytes which is greater than the maximum allowed buffer size of 86586540032 bytes."

        let reduced = ModelRuntime.adaptivePrefillStepForMetalAllocationFailure(
            currentPrefillStep: 4096,
            errorDescription: description
        )

        #expect(reduced == 2048)
    }

    @Test
    func adaptivePrefillStepForMetalAllocationFailure_stopsAtFloor() {
        let description =
            "MLX Error: [metal::malloc] Attempting to allocate 95901702400 bytes which is greater than the maximum allowed buffer size of 86586540032 bytes."

        let reduced = ModelRuntime.adaptivePrefillStepForMetalAllocationFailure(
            currentPrefillStep: 256,
            errorDescription: description
        )

        #expect(reduced == nil)
    }

    @Test
    func metalAllocationRetryShouldPreferPrefillStep_whenRequestedBytesDoNotShrink() {
        let shouldPrefer = ModelRuntime.metalAllocationRetryShouldPreferPrefillStep(
            previousRequestedBytes: 95_881_883_904,
            currentRequestedBytes: 95_881_883_904
        )

        #expect(shouldPrefer)
    }

    @Test
    func metalAllocationRetryShouldPreferPrefillStep_falseWhenRequestShrinksMeaningfully() {
        let shouldPrefer = ModelRuntime.metalAllocationRetryShouldPreferPrefillStep(
            previousRequestedBytes: 95_881_883_904,
            currentRequestedBytes: 82_000_000_000
        )

        #expect(!shouldPrefer)
    }
}
