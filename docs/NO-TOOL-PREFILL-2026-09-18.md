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

PARTIAL: new regressions prepared; no after-change test or native result yet.
Before receipts: private `runtime-followup-2026-09-18/BONSAI-RUN6.md`,
`run6-prefill-full.log`, `run6.oslog`, `run6-prompts/`,
`live-captures/run6-ternary-complete`, binary SHA256
`e762a0b4657aba2331adb1cebf89df6e0fdd3e3f3e086baa16dbcb06177ca380`.
