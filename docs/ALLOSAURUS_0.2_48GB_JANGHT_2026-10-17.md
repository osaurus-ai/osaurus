# Allosaurus 0.2 on 48 GB Macs (qwen4_exp JANGHT): Osaurus integration notes

Branch `feat/allosaurus-48gb-janght` = `main` @ `e614fc0ac` (0.25.23) + `fix/allosaurus-wire-budget-pin-oct15`
(#3107, which carries #3097: Keep Model in Memory / residency setting, prefill progress). The runtime work lives in
vmlx-swift branch `feat/allosaurus-48gb-janght` (`docs/ALLOSAURUS-0.2-JANGHT-48GB.md` there).

Status (2026-10-17): vmlx-swift pinned to `feat/allosaurus-48gb-janght` (PR osaurus-ai/vmlx-swift#613); its checklist
items 1-6 pass on the real bundle; the GUI proof below ran on a 128 GiB Mac (PR #3125). Open: a 48 GiB hardware run.

## What changes here

1. Re-pin vmlx-swift in all six places (done for each runtime commit on this branch): `Packages/OsaurusCore/Package.swift`, `Packages/OsaurusCore/Package.resolved`,
   `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`,
   `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and the revision-pinning tests
   (`Tests/Service/ImageGenerationBridgeContractTests.swift`, `Tests/Service/RuntimePolicySourceTests.swift`).
2. Optional curated entry in `Managers/Model/ModelManager.swift` (`curatedSuggestedModels`, `modelType: "qwen4_exp"`);
   public OsaurusAI repos also appear through the org listing.
3. Nothing in Osaurus should special-case this bundle by name: the n-gram table is already excluded from RAM
   estimates (`ModelSSDResidency.ngramModelTypes = ["qwen4_exp"]`), native MTP and SSD cache come from the runtime.

## Memory on a 48 GiB Mac

- GPU-resident weights ≈27.1 GiB; the ≈53 GiB n-gram table stays on SSD and is never wired.
- Admission estimate (weights − table) × 1.25 ≈ 33.9 GiB. **Safe Auto** (default, 0.70 × RAM = 33.6 GiB) loads with an
  advisory. **Strict** (0.60 × RAM = 28.8 GiB) refuses with error 507: an existing user-chosen mode; surface it in the
  model card / guide rather than adding any new refusal.
- Keep Model in Memory (from #3097) is the setting that requests GPU residency; the wire budget is bounded by the live
  `vm.global_user_wire_limit` (79 % = 37.92 GiB on 48 GiB, ≈7 GiB already wired by the OS).

## Native MTP and sampling

- MTP Adaptive is the default for this bundle (Server settings → MTP: Off / Default / On-Adaptive). Reference
  acceptance on the same bundle in vMLX Python at the shipped sampling defaults: 75.9 % of drafts (d1 85 %).
- Sampling defaults ship in the bundle (`generation_config.json` + `jang_config.chat.sampling_defaults`, temperature
  below 1.0, top_k 20, top_p 0.95). Do not coerce them.

## SSD prompt cache (agentic / terminal tool loops)

- Server settings → Cache: block-disk cache on. The runtime stores the tool-call prefix before the continuation, and
  QSA KV + indexer lane and GDN recurrent state are serialized natively.
- Proof needed on this bundle: a terminal tool-call loop where the turn after each tool result restores from SSD
  (partial hit) with MTP on, with the same answer as a cold run.

## Proof (live visual harness only)

Through the running dev app's GUI (never curl/HTTP/CLI against Osaurus): download/load the bundle, multi-turn chat,
a terminal tool-call loop with the SSD cache on, MTP Adaptive vs Off, Keep Model in Memory on a 48 GiB Mac (wired
bytes and `vm.add_wire_count_over_global_limit`, decode speed stable over a long session).

Done on a 128 GiB Mac (PR #3125): load, multi-turn chat with tool calls, SSD cache restore after tool results, MTP
Auto vs Off (tool turns +23-43 %, reasoning-heavy replies -2..-3 %). Not yet done: the 48 GiB hardware session.

## Upload contract (OsaurusAI)

`osaurus.json` at the bundle root with `required_osaurus_version` = the first release containing the re-pin (named by
the release owner) and `model_version`; read it back from the Hub after the push.
