# D3 downloader catalog and import investigation

Status: candidate, not yet qualified or merge-ready.

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
