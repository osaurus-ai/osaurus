# Isolated runtime follow-up proof stack

NOT a main/release branch. No full-model/native proof claimed yet.

This worktree combines current-main app PR2796/2798 handoff ownership and
PR2806 Gemma required-media handling by ordinary merges, with no conflicts.
The parent PR branches remain separate and unchanged. Engine pin
6c4fee39fd10284dcefb8115d79b163ec7ca329c is an ordinary merge of packed-load
PR481(eacab3c7; executed code34026e3f) and media-prefillPR482(f3e0cb08;
executed codea30e86a9), on engine main87a686e9. No extra production changes.

The separate engine component runs passed35Swift Testing functions, and
4XCTest+14Swift Testing functions respectively. App2796 and2806 exact-head
CI passed. These facts do not qualify this combined app; build and native
proof must use this source and exact pin. Source plans, retained failures and
native acceptance are in the corresponding PR docs.

Next: one isolated optimized development app; no release/install. Once the
named follow-up runtime permission is granted: real Settings swap ON/OFF,
30-second idle hold/release, Gemma tool/media/parent continuation, then Bonsai
storages sequentially with one loaded at a time. Separate load, prefill,
decode, physical footprint and actual hybrid-cache/media restoration. Keep
the previous8049-token image/history memory failure until the same workload
is reproduced. Never use component timing as a claimed app speedup.

Evidence and guard scripts:
`/Users/eric/vmlx-private-evidence/runtime-followup-2026-09-18/STATUS.md`.
