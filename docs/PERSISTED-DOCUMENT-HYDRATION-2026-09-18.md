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

PARTIAL: implementation and new tests prepared; no candidate test/native
execution yet. Baseline evidence in private runtime-followup-2026-09-18:
NO-TOOL-RUN7.md, live-captures/run7-recall/transcript.json,
run6-prompts/prompt-1789737363129-26749-BatchEngine.generate-OsaurusAI_Bonsai-2-27B-Ternary-JANG.txt,
run7-prompts/prompt-1789738086329-83384-BatchEngine.generate-OsaurusAI_Bonsai-2-27B-Ternary-JANG.txt.
Do not attribute the smaller post-relaunch prompt to a prefill optimization.
