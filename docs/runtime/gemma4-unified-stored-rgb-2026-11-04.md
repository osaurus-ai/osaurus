# Unified Gemma stored RGB consumer — 2026-11-04

Status: consume the actual merged runtime pixel-contract correction PR724. This is a scoped source correction; Gemma OCR and low-RAM rows still fail and full family qualification remains partial. No release tagging or publishing.

Runtime merge `fe797ed49a0dbd28a0bf239af04430be35baf83f` is pinned in four resolver locations and two contract expectations. Its full tree equals PR724 final head8d93e60e; implementation source/tests equal the native-qualified06017 executable source. Only the runtime documentation differs. The consumer branch is based on Osaurus main67a840ed, which already consumes normalization PR723 through merged consumer3311.

The unified processor composites transparency onto white before resize and renders stored RGB without ICC gamut conversion, matching the pinned reference. Ordinary Gemma processor behavior, bundle generation defaults, model weights, cache algorithms and template/tool-choice behavior are unchanged. Production prepare() red cases reproduce wide-gamut error and three half-transparent failures; corrected selection passes14XCTest and27SwiftTesting tests/four suites including nine real encoded-PNG color/alpha cases and repeated media salts.

SOURCE EVIDENCE: runtime Libraries/MLXVLM/Models/Gemma4.swift unified-only branch, Gemma4UnifiedPixelContractTests.swift, and docs/GEMMA4_UNIFIED_STORED_RGB_CORRECTNESS_2026_11_04.md. Four Package.resolved/Package.swift pin surfaces and two consumer test expectations name the actual merge SHA.

LIVE EVIDENCE: GEMMA-RGB-CANDIDATE-NATIVE-QUALIFICATION-RECEIPT.json in /Users/eric/vmlx-private-evidence/osaurus-cache-wiring-20261103/ binds65artifacts from fresh isolated Release Osaurus d7d8538e9a96eff2d67955814d382b949cd81d6b with runtime06017. Exact binary SHA25624c68fbcba5c55ec444bce4e047e0b243bc32c73d1f9c5aba40467c2d2bf553a. Actual-merge-pin fresh build and affected native re-check remain pending at this source checkpoint.

Real OsaurusAI/gemma-4-12B-it-qat-JANG_4M, bundle temperature1/top-p.95/top-k64/min-p0; agent explicitThinkingOff, absent max uses existing app16384 fallback. Nine manual usercases/fifteen measured inferences all finish naturally. Actual calculator437 then fresh-process874 and three actual terminal operations exit0/emptyerr with previous-stdout digest grounding pass. Terminal discovery is explicitly capabilities-guided; baseline automatic-discovery and todo-format failures remain open. These manual cases do not replace scored AgentLoop harness qualification.

Ten actual typed disk restored boundaries each contain8rawKV+40rotating with exact offsets. Native PrefixOn/pagedGPUOff/SSDOn, effectiveKVLayers0 and zero pagedblocks. Same-media fresh-process restore3035/3212 plus3212/3267 continuation passed; changed media cold-prefilled. No TurboQuant-KV or compiled-kernel claim. A capabilities continuation coldmiss6871 is retained: raw history/tool schema prefix is equal, but required→auto choice changes a bundle system-prefix instruction; production token replay is pending.

Image score remains4/9fields FAIL, equal to matched baseline fieldscore. Sampled physical peaks12.37/12.63/13.27GB exceed10.14GBweights: RAMFAIL. Owned loading retained per user direction; no low-RAM claim. Runtime decode37.17–39.96tok/s, per-request export metrics include prefill separately; no raw speed benchmark. All candidate producers/collectors normallyclosed0. Initial missing detailed trace, wrong-app binding correction, late UI captures and old timing clarification remain retained.

Actual native old-version cache upgrade control, other QAT JANG4/MXFP4, full resize parity, cancellation, eviction/quota and scored evaluations remain partial. No source/BF16 bundles or audio are loaded for this checkpoint.
