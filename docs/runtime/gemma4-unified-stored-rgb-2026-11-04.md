# Unified Gemma stored RGB consumer candidate — 2026-11-04

Status: local native qualification candidate. Runtime PR724 remains a draft; this pin is not merge-ready. No release tags or publishing.

Pin `06017b9f64dcf064eef35191689a3f47494fbf12` in four resolver locations and two test expectations. The unified processor now composites transparency onto white before resizing and renders stored RGB without ICC gamut conversion, matching the pinned Transformers conversion chain. Ordinary Gemma preprocessing and generation settings retain their behavior.

Production prepare() regression on norm main4a76 passes sRGB but fails DisplayP3 error0.6705315/Rec2020error1.0248828. First unmanaged-only correction passes opaque images but fails all three half-transparent cases error0.49996158. Full correction passes14XCTest and27SwiftTesting tests/4suites including9color/transparency cases and repeated media-salt stability. No source/BF16 model is loaded by tests; full model/native image proof remains required.

Existing actual norm consumer26b4 passes115hosttests, freshRelease/nativefourrequests: image3/6FAIL, actualcalculator437PASS, diskrestores2484/2618 and2618/2673PASS, sampledphysical12,402,270,368bytesRAMFAIL versus10,135,442,948weights. That remains the matched baseline; new RGB quality is unproven. New independent agent/profiles were frozen byteequal before inference, with unchanged real ICC-profiled PNGs, ThinkingOff explicit and all samplers inherited. Never replace or strip these fixtures to hide a failure.

SOURCE EVIDENCE: runtime Gemma4.swift unified-only RGB branch, Gemma4UnifiedPixelContractTests.swift and its storedRGB correctness document. Existing pixelbytes participate in computeMediaSalt, so changed prepared tensors isolate cache state.

LIVE EVIDENCE: /Users/eric/vmlx-private-evidence/osaurus-cache-wiring-20261103/GEMMA-RGB-MATCHED-FROZEN-PROFILES.json, GEMMA-NORM-MERGED-CONSUMER-NATIVE-RECEIPT.json and pixel red/green receipts. Updated candidate app/images/tool/growing/fresh-process media cache/rates/physical-footprint proof pending. Other QAT/MXFP4, cancel/eviction/scored evaluation and original adaptive coldmiss remain partial. Retain owned loading per user choice; no low-RAM or full-family claim.
