# Preserve persisted document text in chat requests

## Measured defect and source trace

Native app56fe954b8076d06630231f858c8d97d4bc22734a, engine
6c4fee39fd10284dcefb8115d79b163ec7ca329c, reopened a Bonsai2 ternary chat with
a160-entry18KB pasted attachment. The UI retained the attachment chip but
the rendered request omitted its entire document body. Before relaunch the
body was present. A1995-byte inline attachment and the image were still sent.

`ChatSession.buildUserMessageText` used `Attachment.documentContent`, which
returns text only for `.document`. Persistence spills documents at16KiB into
`.documentRef`; JSON reopening retains that reference. The existing
`loadDocumentContent()` hydrates both kinds through the policy-aware blob
store. The blob format/encryption is not the defect.

Source history checked before editing: original document support4effbc94b,
wrapper hardening#925/efba25824, structured metadata#1367/2f7ff1074. Preserve
the latter two fixes. Warmup and actual send both call buildUserChatMessage;
compaction already uses loadDocumentContent. This is not a new cache policy.

## Minimal change and acceptance

- Change the rendering accessor to existing loadDocumentContent. Keep
  basename normalization, XML escaping, metadata and ordering unchanged.
- Regression: actual blob spill, JSON encode/decode and send/warmup byte
  parity in plaintext and encrypted storage; hostile wrapper text remains
  escaped. Missing blobs retain existing nil/skip behavior, never fabricated
  document content. Missing-blob error UX is not changed here.
- Fresh native development app: reopen the retained affected chat, inspect
  rendered input for all160 entries, obtain complete visible answer and
  follow-up/cache telemetry. Native defaults and real image history retained.
- Record exact source/binary/engine, token/s, footprint and shutdown; normal
  PR CI before promotion. No model/prompt/sampler changes or release actions.

Initial baseline evidence in private runtime-followup-2026-09-18:
NO-TOOL-RUN7.md, live-captures/run7-recall/transcript.json,
run6-prompts/prompt-1789737363129-26749-BatchEngine.generate-OsaurusAI_Bonsai-2-27B-Ternary-JANG.txt,
run7-prompts/prompt-1789738086329-83384-BatchEngine.generate-OsaurusAI_Bonsai-2-27B-Ternary-JANG.txt.
Do not attribute the smaller post-relaunch prompt to a prefill optimization.

## Native reopened-chat result and CI correction

SOURCE EVIDENCE: production473ae2e602fe6abb853d032dc5612daf19187776,
ChatView.swift2252. Integrationf2d152aa2fe67a5629ec0b9f7f9b0f7f5e79e94e,
engine6c4fee39fd10284dcefb8115d79b163ec7ca329c, binarySHA256
1b96587c3591c9701e5a8824c9d20bd7443d532d8f39cf8b44b1b3a4638d4dd0.

LIVE EVIDENCE: native run8 reopened the same persisted chat and18KB blob.
Both actual rendered requests contain all160 reference entries. Bonsai2
ternary, native1/.95/20,None reasoning, actual image and file-tool history.
The first request quoted Entry073 exactly:10106prompt,18201msprefill,
24tokens27.7tok/s,natural stop. The follow-up requested Entry125 and the
earlier image word but repeated Entry073: FAILED full task,26tokens28.9tok/s,
10292prompt,10099disk-restored,552msprefill,natural stop. New request and
full document are present in its rendered input. Hydration present2/2;
full-task score1/2. No causal attribution or blanket quality pass claimed.

Raw receipts: private runtime-followup-2026-09-18/DOCUMENT-RUN8.md,
run8-prompts/,run8-prefill-full.log,run8-measurements.jsonl,
live-captures/run8-document-reopened. Normal Quit07:04:37PDT,guardexit0,
zero owned survivors,swap1.67GiB unchanged. App sampled peak9360281920bytes;
no M4/16GB qualification. No source/prompt/sampler masking.

First CI core job35352342959/105623229848 failed at the new JSON decode's
`[Attachment].self` expression with a Swift diagnostic failure. Qualifying
`[OsaurusCore.Attachment].self` disambiguates it from Swift Testing's generic
Attachment. Local actual-module typecheck no longer reports that diagnostic;
it cannot complete against the Release module's absent DEBUG-only storage-key
test hook. This is not a test execution pass. Normal Debug CI must run the
plaintext/encrypted spill, escaping, warmup and missing-blob cases before merge.
Production source is unchanged by the test-only correction.
