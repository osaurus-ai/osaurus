# Consume the merged Bonsai load and media-prefill corrections

The four runtime pin sites and two regression tripwires move together from
`87a686e929c4bbd9e99728126b30095339d0df5b` to merged engine main
`125f961272908697f87a983f972ccf50e0810a05` (vmlx-swift #481 and #482).
No sampler, template, cache policy, residency setting or app version changes.

SOURCE EVIDENCE: merged engine and the tested integration engine
`6c4fee39fd10284dcefb8115d79b163ec7ca329c` have the identical complete Git tree
`bb852fd2b0ab25b1fbfcbaeb416836799ee661bc`. This includes all source, tests,
documentation and submodule pointers, not just the two edited runtime files.
The packed-expansion implementation is unchanged from `34026e3f`; the media
chunking implementation is unchanged from `a30e86a9`. All other package pins
must remain unchanged. Normal Osaurus PR CI remains required.

LIVE EVIDENCE: source-bound local Metal runs executed 35 Swift Testing functions
in eight suites for packed/runtime contracts, then four XCTest cases plus 14
Swift Testing functions in four suites for media/hybrid parity, with zero
failures/skips. Engine GitHub Mac/CUDA checks were queued at merge; repository
advisory lint failures remained visible. Four Linux builds succeeded. Local
Metal execution is not labelled as completed Mac GitHub CI.

Native development app `1643da66eb63fa625978016145ee97da0b69439e`, engine
`6c4fee39fd10284dcefb8115d79b163ec7ca329c`, binary SHA256
`e762a0b4657aba2331adb1cebf89df6e0fdd3e3f3e086baa16dbcb06177ca380`:
both Bonsai2 storages loaded sequentially, real image/file tools and long media
history ran, explicit sampler overrides/reset and mid-turn reasoning controls
were exercised. Bundle defaults were 1/.95/20. Packed task score 5/5; ternary
3/4, retaining the omitted line-count failure. Final rates 20.2–30.3 tok/s,
sampled peak 15,860,452,064 bytes under the 20GiB guard. This is neither a
paired speed comparison nor a 16GB-machine or universal quality qualification.

Run7 on app `56fe954b8076d06630231f858c8d97d4bc22734a` additionally exercised
native initial-load Stop: no decode, cleanup to no resident/inflight model,
then a normal 11.8s reload and 54-token answer at 30.0 tok/s. Expansion was not
instantaneously interrupted. Run8 retained a second-turn wrong-answer case
despite a complete rendered document/new request; no clean quality pass is
inferred from cache-hit telemetry.

Detailed receipts: private `runtime-followup-2026-09-18/BONSAI-RUN6.md`,
`NO-TOOL-RUN7.md`, `run8-*`, and the engine PR comments
[#481](https://github.com/osaurus-ai/vmlx-swift/pull/481#issuecomment-5731183044)
and [#482](https://github.com/osaurus-ai/vmlx-swift/pull/482#issuecomment-5731183727).
This repin is not a fresh exact-app-head live run. The tested engine is
byte-identical; app-main CI/build and final pin verification are separate gates.
No release, tag, install or publishing is authorized.
