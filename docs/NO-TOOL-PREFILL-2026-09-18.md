# Do not require tool execution for a no-tool recall request

## Measured failure and history

Fresh native development app `1643da66eb63fa625978016145ee97da0b69439e`,
engine `6c4fee39fd10284dcefb8115d79b163ec7ca329c`, ternary Bonsai2 27B with
native sampling 1/.95/20, None reasoning, actual image and tool history.
User text: "How many lines did file_read report for bonsai-defaults-ternary.txt?
Use the tool result already present in this chat; do not run another tool."

The submitted request had `tool_choice=required` despite that instruction.
The existing `.freshRequiredToolSelection` policy therefore disallowed restore:
9,928 prompt tokens, 23,315ms prefill, 23.99s TTFT plus 6.0s model reload;
35 output tokens at 25.9 tok/s, correct final with no tool execution. The
preceding ordinary follow-up restored 9,461/9,726 tokens with 807ms prefill.
These are different prompts, not a matched speedup claim.

Source trace: `ChatToolChoicePolicy.requiresToolCall` matches the exposed
file_read name; `containsNegatedToolIntent` recognized "do not use/call" but
not "do not run" or "without calling". `MLXBatchAdapter.prepareInput` assigns
the required-tool cache policy. No change to engine cache safety is justified.

History checked: main #2774 added identifier boundaries to avoid the earlier
completed/complete false positive. Draft #2718 separates framework delegation
delivery text from actual task intent; it does not alter this negation matcher.
This correction does not replace either fix or absorb that draft.

## Bounded plan and change

1. Extend the existing negation vocabulary for run/invoke/without calling.
   Preserve `.auto`, not `.none`: no tools or model responses are filtered.
2. Test the exact observed request and related wording, affirmative execution,
   redaction exclusion, existing identifier boundaries and follow-up policy.
3. Rebuild the isolated native app, repeat no-tool recall on existing media/tool
   history, observe Auto and real restore, then execute an affirmative file_read.
4. Record source identity, actual sampler, complete UI result, token/s, cache
   counters and resources. Ordinary CI and applicable evaluation remain gates.

No sampler, prompt/template rewrite, permission, schema, explicit API tool
choice, model identity or cache-restore guard changed. General semantic intent
recognition is not claimed; bare tool-name mentions remain the existing policy.

Before receipts: private `runtime-followup-2026-09-18/BONSAI-RUN6.md`,
`run6-prefill-full.log`, `run6.oslog`, `run6-prompts/`,
`live-captures/run6-ternary-complete`, binary SHA256
`e762a0b4657aba2331adb1cebf89df6e0fdd3e3f3e086baa16dbcb06177ca380`.

## Executed checks (2026-09-18)

Production source `590a48dd8fc7c373f60d9c4a1a28fbbe2825f5f4` was integrated
into isolated app `56fe954b8076d06630231f858c8d97d4bc22734a`, unchanged engine
`6c4fee39fd10284dcefb8115d79b163ec7ca329c`. Binary SHA256
`d1fa5e13930d18372bef64571438c61b23de0f616426c6c34c7da7aae48884c7`.
The app used the actual local OsaurusAI/Bonsai-2-27B-Ternary-JANG bundle,
native sampling T1/P.95/K20, explicit None reasoning, 13 file tools and real
image/tool history. No sampler or answer hints were added.

- Compiled the actual complete policy source in a deterministic component
  harness with minimal API type shells: **20/30 before, 30/30 after**. The ten
  baseline failures were nine new negation variants plus negated redaction.
  Affirmative execution, identifier boundaries, existing negation, subsequent
  attempts and empty tool lists retained their expected behavior. This does
  not replace execution of the full OsaurusCore test module in CI.
- Native Regenerate on the exact prior user request submitted **Auto**, not
  Required, and answered six lines without a tool. 5,667 prompt tokens,
  14,807ms prefill, 20 tokens at30.8tok/s, natural stop. This is not a matched
  speed comparison: a separately discovered persisted document-ref omission
  reduced the historical prompt from the previous9,928 tokens.
- Repeated the exact no-tool request through the composer: Auto,
  5,857 prompt tokens, **5,660 restored from disk**, **510ms prefill**,
  34 tokens at30.5tok/s; visible correct six-line answer, natural stop,
  TTFT1.35s plus5.9s idle reload, no tool execution.
- Affirmative control: "Use file_read to read bonsai-defaults-ternary.txt
  and report the exact line count." Required,6,048 prompt tokens,
  10,518ms prefill,31 tokens at28.6tok/s; actual file_read executed. The
  tool-result continuation submitted Auto, restored6,041/6,283 tokens,
  **563ms prefill**,20 tokens at29.0tok/s, natural stop and correct six-line
  final. Native tool card settled, Stop disappeared and input unlocked.

Hybrid topology remained16 KV plus48 Mamba/SSM layers with FP16 KV,
disk-backed restore, paged RAM off and TurboQuant count0. This is not a
separate SSM-companion-hit counter claim. Required-tool cache safety is intact.

Receipts under `/Users/eric/vmlx-private-evidence/runtime-followup-2026-09-18/`:
`NO-TOOL-RUN7.md`, `tool-intent-component.8P4IXB/{before,after}.log`,
`run7-launch.json`, `run7-prefill-full.log`, `run7.stdout`, `run7.oslog`,
`live-captures/run7-{recall,affirmative}`, and native CUA visual inspection.
Run7 also covered packed-model load cancellation/retry for separate engine
PR481. Normal app quit06:37:35PDT, supervisor exit0, zero owned survivors;
swap1.67GiB unchanged. Sampled app peak13,448,612,696 bytes, lifetime peak
14,133,791,552 bytes; no low-RAM/M4-16GB claim.

PARTIAL for promotion until exact-head CI/applicable evaluation gates finish.
These scoped controls are not full-model quality certification: run6's
unrelated omitted-line-count answer remains a failed row. Persisted
document-ref hydration is a separate source-traced defect, not changed here.
