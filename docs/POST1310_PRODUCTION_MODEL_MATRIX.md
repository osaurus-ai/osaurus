# Post-1310 Production Model Matrix

Date: 2026-05-31

Base after merge: `65d0171d9b93eaa8b99cd19a648cf87976af1d71`.

vMLX pin in Osaurus: `60b888659e1196995fa57f7af91d982e5948a680`.

No-sign app used for live proof:
`/tmp/osaurus-post1310-nosign-dd/Build/Products/Release/osaurus.app`

Model root used for live proof: `/tmp/osaurus-post1310-modelroot`

The app was launched through the keychain-free proof lane with
`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` and `OSU_MODELS_DIR` set to the model
root above. The build lane used no signing identity. Local ad-hoc sealing, when
performed by the build script, is certificate-free and does not use Keychain.

## Served Models

The fresh app launch served these model ids through `/v1/models`:

- `lfm2.5-8b-a1b-jang_2l`
- `lfm2.5-8b-a1b-mxfp4`
- `lfm2.5-8b-a1b-mxfp8`
- `step-3.7-flash-jang_2l`

`Step-3.7-Flash-JANG_K` is not claimed in this matrix. The only local matching
directory found was `/Volumes/EricsLLMDrive/jangq-ai/Step-3.7-Flash-JANG_K`,
and that directory was empty. The temporary symlink was removed from the test
model root because the empty target made model scanning unreliable.

## Step 3.7 Flash JANG_2L

Cold artifact:
`/tmp/osaurus-post1310-step-jang2l-cold-20260531-123421/step-3.7-flash-jang_2l_summary.json`

Warm artifact:
`/tmp/osaurus-post1310-step-jang2l-warm-20260531-130248/step-3.7-flash-jang_2l_summary.json`

Verdict: partial. The strict three-turn tool/history/cache harness passed, but
decode speed is not production acceptable in this no-sign Osaurus row.

Confirmed:

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible answer, no tool call, no protocol leak.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Cache topology: 45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, `turbo_quant_kv_layer_count=0`.
- Warm row recorded disk reuse with `block_disk_hits=1`.

Speed boundary:

- Cold visible answer: 8 completion tokens in 229.63s, about 0.035 tok/s.
- Warm visible answer: 3 completion tokens in 19.80s, about 0.152 tok/s.

This proves routing, tool parser behavior, history behavior, topology, and a
warm L2 hit. It does not prove user-facing speed.

## LFM2.5 JANG_2L

Cold artifact before the disk-cache gate:
`/tmp/osaurus-post1310-lfm-jang2l-cold-20260531-130552/lfm2.5-8b-a1b-jang_2l_summary.json`

Warm disk artifact before the disk-cache gate:
`/tmp/osaurus-post1310-lfm-jang2l-warm-20260531-130613/lfm2.5-8b-a1b-jang_2l_summary.json`

Post-gate artifact:
`/tmp/osaurus-post1310-lfm-jang2l-postgate2-20260531-132314/lfm2.5-8b-a1b-jang_2l_summary.json`

Verdict: green for strict multi-turn tool/history behavior on the current
conservative app path; partial for cross-session disk L2 reuse.

Confirmed on the post-gate row:

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no tool call, no protocol
  leak, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- App health after the row: healthy, no in-flight requests, requested model
  resident and current.
- Token/s recorded: visible answer emitted 201 completion tokens in 0.812s,
  about 247.5 tok/s.
- Topology: 24 layers, 6 KV layers, 18 Mamba/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `companion=ssm`, `turbo_quant_kv_layer_count=0`.

Why the code gates LFM2 disk L2:

- The pre-gate cold row passed with exact tool behavior and the same topology.
- The pre-gate warm disk row recorded real reuse
  (`block_disk_hits=1`, `ssm_companion_hits=1`, `companion_hits=1`) but failed
  the required turn after history: turn 3 returned prose instead of a tool call.
- The production-safe change keeps LFM2's in-memory SSM companion topology
  available but disables automatic cross-session disk restore for LFM2 until a
  dedicated warm disk row proves exact required-tool behavior.

This is not a sampler, logit-bias, repetition-penalty, prompt-coercion, or
parser-forcing fix. It is a conservative cache-compatibility gate around a live
warm-cache failure.

## LFM2.5 MXFP4 and MXFP8

The app served `lfm2.5-8b-a1b-mxfp4` and `lfm2.5-8b-a1b-mxfp8`, but this
post-merge matrix did not run live multi-turn tool/cache rows for those sibling
bundles. Do not claim them production proven from the JANG_2L row.

## TurboQuant KV Boundary

This matrix does not prove TurboQuant KV for Step or LFM.

- Step JANG_2L topology reports `turbo_quant_kv_layer_count=0`.
- LFM JANG_2L topology reports `turbo_quant_kv_layer_count=0`.
- Step and LFM are hybrid/paged-incompatible paths in these rows, so the
  conservative behavior is native/cache-topology handling rather than forcing a
  global TurboQuant KV default.

## VL Boundary

No VL/media row was run in this post-merge matrix. VL correctness remains
outside this PR's proof unless a separate real-media live row is added.
