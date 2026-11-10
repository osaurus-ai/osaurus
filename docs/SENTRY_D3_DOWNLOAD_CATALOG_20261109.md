# D3 downloader catalog and import investigation

Current status: the catalog/import/download scope is qualified on product
source7ce2e8444ae55cd93d151e324b0a48a23fcb3ac0. Final documentation-head CI
and merge review remain. The initial investigation and candidate history below
are retained; the final qualification supersedes their pending-proof status.

The real private Release app rejects public OsaurusAI/d3-JANGH2,
d3-flash-JANGH2 and d3-turbo-JANGH2 imports before transfer with
“That OsaurusAI model isn't in the registry.” Under the same app/profile,
Raptor-0.6-4B-JANG_6M imports successfully to its existing card without
starting a download. The managed download directory remains empty.

D3 is non-generative. Its published pipeline is zero-shot-classification,
and its task tag is decision-model. The org Catalog discovery admits only
chat pipelines. Direct import subsequently requires public OsaurusAI repos
to be present in that Catalog. Together these checks exclude the supported
decision bundles before the downloader runs. No transfer, CDN, shard-size,
cache or runtime defect is inferred from this reproduction.

Twenty-six downloader/model/UI files match byte-for-byte between shipping
0.25.33 (66c3dde0b322e45c439a1aa6c628a8caea6d1705), verified main
794836cfbf128c10b6620e43c7fac232f3880d27 and native code3c1e3655.
The baseline app uses consumed vMLX1bcd74ad. All nine current public D3
repos return readable pinned metadata and require Osaurus0.25.26.

The current candidate recognizes the declared decision task and its existing
JANG/decision config/readout artifacts in Hub metadata. Such models can enter
the downloader Catalog; direct import then uses its existing registry rule.
Their decision
task survives size/download metadata enrichment and serialization; existing
chat selectors continue to exclude them. No model-name allowlist or chat
pipeline reclassification is introduced. Installed decision admission still
validates the actual bundle. Other utility panels and public chat registry
policy retain their existing checks.

Required proof remains fresh Release UI discovery/import, an actual complete
pinned download with pause/resume and nested-file integrity, count and chat
selector checks across relaunch, focused affected suites and ordinary CI.
No runtime, cache, generation defaults, dependency pins, release scripts,
workflows, tags or appcast changes are included.

SOURCE EVIDENCE: private hf-d3-download-20261109/SOURCE-BASELINE-PARITY1.json
and candidate source patch retain exact inputs.

LIVE EVIDENCE: native-baseline1/BASELINE-QUALIFICATION1.json, captures00–05,
actual PID43175 launch/environment/exit receipts and resource logs retain
three failing decision imports and the successful chat control. Automatic
external discovery initially read three existing HF-cache bundles; originals
were not changed. Private managed model/image roots stayed empty.


## Candidate2 scope review

The separate direct-import exception in candidate066a4cd4d is unnecessary
for this reproduced failure once org Catalog discovery includes supported
decision bundles. Candidate2 removes that exception and restores the entire
HuggingFaceService byte-for-byte to main. The existing public OsaurusAI
registry rule stays intact. Only org Catalog task eligibility and preservation
of the decision marker change. The metadata fixture now exercises actual org
response decoding and card construction, including its unchanged backbone
type and chat exclusion.

Candidate1 baseline/native apps, full component results, process-observation
attempts, exact source and both compiled DerivedData snapshots are retained.
Its178/182 components had0failures and4existing opt-in network skips; its
fresh Release resolved base D3 import and showed D3 task badges. No weight
transfer or model generation occurred in candidate1. These are historical
receipts, not candidate2 proof. Candidate2 requires fresh build/tests/UI.

## Final candidate2 qualification

The fresh isolated Release app was built from7ce2e8444ae55cd93d151e324b0a48a23fcb3ac0
with clean consumed vMLX1bcd74ad182103a3b83941f61e57ee0bac23b330. Its executable
SHA256 is fc41175e00e8372a2e03baefec37147713a34d2134db919c7b759c5ee31acc7e.
The private copy has the actual source version0.25.33, matching production
packaging's canonical appcast version; the original Xcode1.0 build is retained.
All four real app PIDs have the five intended private-root/keychain-disabled
flags verified, with no inherited runtime overrides. All exited normally.

Plain `d3` Catalog search shows three families with three published versions
each, marked D3. D3, D3 Flash and D3 Turbo JANGH2 direct imports now resolve
under the unchanged public registry rule. The actual Download button for
OsaurusAI/d3-flash-JANGH2 completed revision
99a8107284bd5d1b70da1dd4958963f3158e8d52. Actual Pause and Play controls were
exercised. The independent paused snapshot retains16 completed32MiB chunks
(536870912bytes); every retained range matches its final shard range.

The completed independent snapshot has15files,5306089405bytes. Every file
matches the pinned publisher LFS SHA256 or Git blob SHA1, including both
weight shards and nested decision config/readout. The larger shard exceeds
4GiB. No network-bytes-saved or throughput benchmark claim follows from these
checks. Resume briefly displays a restarted progress value during preflight;
the literal final “Repair complete. Restored3file(s)” is retained. No monotonic
progress or separate repair defect is claimed.

The header, sidebar and On Device inventory move from3 to4 installed models
and show20.47GB after this download, then survive a real quit/relaunch. The
three installed D3 bundles stay out of both the chat and custom-agent model
selectors. These selector counts legitimately differ from the installed count:
Foundation is selectable without a download, while D3 is non-generative.
Adding the explicit Raptor control fixture later intentionally raises the
private installed count to5; it is not a duplicate D3 observation.

The16 affected full suites pass178/182 declarations with0failures and4existing
opt-in live-network skips. All6new decision-task tests pass. Actual XCTest
PID85124 has all5 isolation flags verified through the mapped test bundle.
Suites cover decision catalog/routing, model resolution/suggestions, MLXModel,
picker chat/cache/tabs, HF parsing/compatibility/download paths/deep links,
retry/storage, chunked transfer and family grouping. The four skipped rows
are the existing network probe/checksum/pause/interruption cases; the real
app download/pause/resume above is separate evidence. All10 ordinary CI checks
passed on7ce2. A documentation-only final commit requires its own normal CI;
product, test, config and dependency equality binds these retained runtime
and component receipts rather than discarding and rerunning them.

### Adjacent chat control and retained failures

An actual saved private agent selects canonical model ID
OsaurusAI/Raptor-0.6-4B-JANG_6M. It has an empty system prompt and zero generation
overrides; its bundle owns temperature1.0, top-p0.95, top-k-1 and max_tokens1048576.
Show Response Metrics was enabled through the real UI and survives relaunch.
Reopening the editor shows those model defaults and all Inherit modes. The
two successful requests have `generation:{}`. The first answer is12; its real
follow-up adds3 and answers15. Both close reasoning, finish with stop, unlock
input and remove Stop without looping, length truncation or protocol leakage.
Native decode rates are112.7 and111.6tok/s; the follow-up reports2112cached
tokens. Separate Activity end-to-end rates are9.03197 and46.04052tok/s.
Three Foundation background generations and their rates are retained separately.

The initial external-target per-file symlink fixture fails twice before
inference with an unreadable osaurus.json. Those attempts have no token/s
because generation never starts. ModelManifest.read explicitly supports
symlinks; an initial symlink-rejection explanation was withdrawn after source
inspection. The OS log does not establish a file-read errno or TCC cause.
Byte-identical private internal backing, still reached through per-file
symlinks at the same model path, works after relaunch. That changes target
location and clears app caches, so it does not identify the external I/O cause.
Both failed profiles and the original external-target mirror are retained.
All13 original external model files retain their bytes, hashes and mtimes.

The successful Raptor control FAILS the low-RAM gate: sampled physical
footprint reaches5686154328bytes versus3662928280weight bytes. No allocator,
sampler, runtime or cache workaround is included. These are two successful
ordinary chat turns, not model-family or low-RAM qualification. D3 inference,
physical M2/M3 behavior, broader cache/settings/delegation and unknown in-flight
user download symptoms remain unproven by this downloader-only change.

SOURCE EVIDENCE: ModelManager.swift:1566,1942,1982 and MLXModel.swift:54,667;
DecisionModelDownloadCatalogTests.swift. Private CANDIDATE2-SCOPE-BOUNDARY1.json
shows the entire HuggingFaceService and direct-import implementation unchanged.

LIVE EVIDENCE: private hf-d3-download-20261109/native-candidate2/NATIVE-QUALIFICATION1.json;
captures00–25; completed-download1/INTEGRITY-RECEIPT1.json;
paused-download1/MANIFEST.json; FINAL-INFERENCE-RATE-LEDGER1.json;
PROCESS-EXIT1..4.json; original/failure/closed-profile snapshots and resource
JSONL logs. COMPONENT-QUALIFICATION2.json and components2/Tests.xcresult retain
the exact178/182 scope. ci-watch-candidate2-1/RESULT.json retains all10 green
checks. All artifacts live under
/Users/eric/vmlx-private-evidence/sentry-inference-20261108, including earlier
failed attempts and compiler-cache snapshots; no screenshots are in the repo.
