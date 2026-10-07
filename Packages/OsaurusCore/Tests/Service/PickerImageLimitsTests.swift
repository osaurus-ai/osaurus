//
//  PickerImageLimitsTests.swift
//  OsaurusCoreTests
//
//  `/models/picker` builds an image model's limits from its picker item;
//  they must match what `/images/models` reports for the same model.
//

import Testing

@testable import OsaurusCore

struct PickerImageLimitsTests {
    @Test func pickerFieldsGiveTheSameLimitsAsTheModelInfo() {
        for canonical in ["qwen-image-2.1", "qwen-image"] {
            let caps = ImageModelRequestPolicy.capabilities(kind: "imageGen", canonical: canonical)
            let info = ImageModelInfo(id: "m", canonicalName: canonical, displayName: "m",
                kind: "imageGen", ready: true, quantizationBits: nil, defaultSteps: 20, defaultGuidance: 3.5,
                capabilities: caps, blockedReasons: [], totalBytes: 0)
            let fromInfo = ImageHTTPParameterBuilder.limits(for: info)
            let fromItem = ImageHTTPParameterBuilder.limits(canonicalName: canonical, capabilities: caps)
            #expect(fromInfo.supported_sizes == fromItem.supported_sizes)
            #expect(fromInfo.min_steps == fromItem.min_steps && fromInfo.max_steps == fromItem.max_steps)
            #expect(fromInfo.max_pixels == fromItem.max_pixels && fromInfo.size_multiple == fromItem.size_multiple)
        }
    }
}
