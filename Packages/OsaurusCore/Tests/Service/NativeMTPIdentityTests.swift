//
//  NativeMTPIdentityTests.swift
//  OsaurusCoreTests
//
//  The model-picker's id and the runtime's model name are different strings
//  for the same model: the picker holds `JANGQ-AI/Qwen3.8-27B-JANG_4D`, the
//  runtime reports `qwen3.8-27b-jang_4d`. A direct `Set.contains` between
//  them matched nothing, so the Speculative Depth row was hidden on every
//  model — including ones with an obvious native MTP head. Nothing failed;
//  the control simply never rendered.
//

import Testing

@testable import OsaurusCore

@Suite("Native MTP model identity")
struct NativeMTPIdentityTests {

    /// The exact pair that failed live.
    @Test func pickerIdAndRuntimeNameNormaliseToTheSameThing() {
        #expect(
            FloatingInputCard.mtpIdentity("JANGQ-AI/Qwen3.8-27B-JANG_4D")
                == FloatingInputCard.mtpIdentity("qwen3.8-27b-jang_4d"))
    }

    @Test func namespaceIsStripped() {
        #expect(FloatingInputCard.mtpIdentity("JANGQ-AI/Qwen3.8-27B-JANG_4D")
            == "qwen3.8-27b-jang_4d")
    }

    @Test func aBareNameSurvivesUnchanged() {
        #expect(FloatingInputCard.mtpIdentity("qwen3.8-27b-jang_4d")
            == "qwen3.8-27b-jang_4d")
    }

    /// Different quantizations of the same family must NOT collapse together,
    /// or enabling MTP on one would light the row on all of them.
    @Test func siblingQuantizationsStayDistinct() {
        let d4 = FloatingInputCard.mtpIdentity("JANGQ-AI/Qwen3.8-27B-JANG_4D")
        let d2 = FloatingInputCard.mtpIdentity("JANGQ-AI/Qwen3.8-27B-JANG_2D")
        #expect(d4 != d2)
    }
}
