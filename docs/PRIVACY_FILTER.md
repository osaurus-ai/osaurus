# Privacy Filter

The Privacy Filter redacts sensitive content from cloud-bound requests on its way out of your Mac and unscrubs the placeholders back on the way in.

It runs as **two independent layers**:

- **Deterministic regex** (built-ins, opt-in presets, your custom rules) — ships on, needs **zero download**, and is the default detector. This is all most users need.
- **On-device AI classifier** (opt-in) — **OpenAI's `openai/privacy-filter`** (Apache-2.0), served via the MLX conversion at [`mlx-community/openai-privacy-filter-bf16`](https://huggingface.co/mlx-community/openai-privacy-filter-bf16) (~2.8 GB). It adds the categories regex can't model — names, addresses, free-form secrets — but is entirely optional: the ~2.8 GB bundle is never downloaded unless you turn AI detection on. When on, the model runs entirely on-device, so no third-party model ever sees your raw text, even to *decide* what counts as sensitive.

The mental model is a redaction gate sitting between the chat surface and any remote provider: detect → review → scrub → send → stream back → unscrub → render. The user is never the last line of defense; the pipeline is **fail-closed** on every write path (scrub produced no substitutions, post-scrub invariant tripped → block the send, surface the reason). Fail-closed is preserved per-layer: with AI detection **on**, a missing/corrupt model still blocks; with AI detection **off**, detection runs regex-only and never blocks on the model.

> Privacy Filter is **experimental**. The regex layer covers deterministic shapes (email, URL, phone, SSN, credit cards, IBAN, AWS keys, GitHub tokens, passport, driver's license) with no model. Turn on AI detection to also catch the fuzzy shapes (names, addresses, dates, free-form secrets). Always review the redaction sheet for messages that contain things you genuinely care about.

---

## Getting Started

1. Open the Management window (`⌘ Shift M`) → **Privacy**. The four sub-tabs (**Overview** / **Rules** / **Providers** / **Model**) are available immediately — no download required.
2. Flip **Enable Privacy Filter** on in Overview. The deterministic regex layer (built-ins + any presets/custom rules you enable) is now active with zero model download.
3. *(Optional)* To also catch names, addresses, and free-form secrets, install the AI model: go to the **Model** tab, click **Install** — the ~2.8 GB bundle streams from Hugging Face and is SHA-256 verified file-by-file — then turn **AI detection** on in Overview. The toggle stays disabled (with an inline install prompt) until the bundle is verified.
4. Send a chat message that contains PII — a review sheet appears showing each detected entity, the surrounding context, and a side-by-side scrubbed preview with hover-to-reveal originals. Approve → message scrubs and sends → reply streams back with placeholders unscrubbed inline.

Both toggles are sticky: they persist synchronously to `~/.osaurus/config/privacy-filter.json` so Cmd-Q immediately after toggling can't lose the state.

> Want to see exactly what your rules catch before sending anything real? The **Rules** tab has a built-in **dry-run tester** — paste sample text and it shows every entity the live rule set (plus the AI model when it's on and loaded) would redact, with the placeholder each one gets.

---

## Architecture

```
                       ┌──────────────────────────────────┐
                       │  Chat → RemoteProviderService    │
                       └─────────────────┬────────────────┘
                                         │ outbound messages
                                         ▼
                       ┌──────────────────────────────────┐
                       │   PrivacyFilterPipeline          │
                       │   .applyOutbound(messages, ...)  │
                       └─────────────────┬────────────────┘
       skip-code-blocks                  │
       providerOverrides[id] == false ───┤ no-op pass-through
                                         │
                                         ▼
                       ┌──────────────────────────────────┐
                       │   PrivacyFilterEngine            │
                       │   ├─ RegexEntityDetector         │  built-in + presets
                       │   │                              │  + user custom rules
                       │   └─ openai-privacy-filter-bf16  │  BIOES decoder
                       │      (vendored PrivacyFilterKit) │  + Viterbi calibration
                       └─────────────────┬────────────────┘
                                         │ [DetectedEntity]
                                         ▼
                       ┌──────────────────────────────────┐
                       │   PrivacyReviewService           │  presenter token
                       │   → RedactionReviewSheet (UI)    │  → user approve/cancel
                       └─────────────────┬────────────────┘
                                         │ [DetectedEntity] approved
                                         ▼
                       ┌──────────────────────────────────┐
                       │   RedactionMap (per conversation)│  intern by original
                       │   → mints [PERSON_1], [EMAIL_2]… │  stable across turns
                       └─────────────────┬────────────────┘
                                         │ scrubbed messages
                                         ▼
                       ┌──────────────────────────────────┐
                       │   Post-scrub invariant           │  fail-closed if any
                       │   re-scan via RegexEntityDetector│  PII still matches
                       └─────────────────┬────────────────┘
                                         │
                                         ▼
       ┌─────────────────────────────────┴────────────────────────────┐
       │                          HTTP (cloud)                         │
       └─────────────────────────────────┬────────────────────────────┘
                                         │ streaming chunks (placeholders)
                                         ▼
                       ┌──────────────────────────────────┐
                       │   StreamingUnscrubber            │  splice between
                       │   recall(placeholder) → original │  upstream + UI
                       └─────────────────┬────────────────┘
                                         │
                                         ▼
                       Chat rendering + inline highlights
```

`applyOutbound` branches on `aiDetectionEnabled` before detection. With AI **on**, it lazy-loads the model and **fails closed** if the bundle is missing/corrupt, then calls `detect(…, useModel: true)` (regex + classifier). With AI **off**, it skips the model entirely and calls `detect(…, useModel: false)` (regex only) — no `.engineUnavailable` is ever thrown. Either way the merge, review sheet, scrub, and regex-only post-scrub leak scan are identical.

Two side channels run alongside the main path:

- **`WireTransportProbe`** captures the *post-scrub* HTTP body actually written to the network and the *pre-unscrub* inbound bytes, so the Insights view can show "this is verbatim what the cloud saw / sent back" — not the local pre-scrub copy. Without this, the Insights logs would lie by omission.
- **`SessionRedactionStore`** is a process-wide actor that holds one `RedactionMap` per chat session (keyed by `sessionId` string). It also tracks which sessions the user flipped "Always approve in this conversation" on. Both the maps and the auto-approve set are wiped via `invalidate(_:)` on chat close / reset / switch — used by the inline-highlight renderer (chat UI) and by the streaming unscrubber on multi-turn conversations so `[PERSON_1]` from turn 2 still resolves on turn 6.

---

## Detection

Detection runs as a **regex layer** (always) plus an **optional AI classifier**, and unions the results. The merge is by `(category, range)` — overlapping detections from different sources collapse to one entity in the review sheet. The regex layer (sections 1–3 below) needs no model and is the default; the classifier (section 4) only participates when `aiDetectionEnabled` is on and the bundle is loaded (`detect(useModel:)` gates this).

### 1. Built-in regex (`RegexEntityDetector`)

Deterministic patterns toggled per-category in **Privacy → Rules → Detection Patterns**. Each toggle controls BOTH the detection pass and the post-scrub leak check — turning a category off here means Osaurus won't flag it AND won't block a send that leaks it. The settings copy is explicit about that trade-off so users don't think the leak check is independent.

| Category         | Pattern                                              |
| ---------------- | ---------------------------------------------------- |
| `phone`          | US-style 10–12 digit phone numbers, ± separators     |
| `email`          | Standard `local@domain.tld` addresses                |
| `url`            | `http(s)://…` URLs with a scheme                     |
| `accountNumber`  | US SSN + Luhn-valid credit card numbers              |

### 2. Preset rules (`PrivacyRulePresets`)

Opt-in patterns for common secrets and IDs, shipped disabled. Enable individually under **Privacy → Rules → Preset Rules**. Current presets:

| ID                  | Detects                                        |
| ------------------- | ---------------------------------------------- |
| `driversLicense`    | US state driver's license number heuristic     |
| `passport`          | US passport number heuristic                   |
| `iban`              | IBAN (ISO 13616 country prefix + check digits) |
| `awsKey`            | AWS access key IDs                             |
| `githubToken`       | GitHub personal access tokens                  |

Adding a preset to the ship-list extends the table here and the corresponding localization keys in `Localizable.xcstrings`.

### 3. Custom rules

User-defined rules from **Privacy → Rules → Custom Rules**. The editor sheet has two modes (`PrivacyRule.kind`):

- **Simple** (`.builder`) — a no-regex builder for non-technical users. Pick a **match type** and type literals; Osaurus generates an escaped, always-valid pattern (`RuleBuilder.compile()` via `NSRegularExpression.escapedPattern(for:)`), so a malformed regex is impossible by construction. Match types:

  | Match type       | Matches                                                | Generated shape         |
  | ---------------- | ------------------------------------------------------ | ----------------------- |
  | `exactWord`      | Whole word(s)/phrase(s), word-bounded                  | `\b(?:term1\|term2)\b`  |
  | `anyOfTerms`     | Any of a list of literals, anywhere (the "redact this list of strings" mode) | `(?:term1\|term2)`      |
  | `startsWith`     | A token that starts with one of the terms              | `\b(?:term)[\w.\-]*`    |
  | `endsWith`       | A token that ends with one of the terms                | `[\w.\-]*(?:term)\b`    |
  | `contains`       | A token that contains one of the terms                 | `[\w.\-]*(?:term)[\w.\-]*` |
  | `numberSequence` | A run of digits of a configurable length               | `\b\d{min,max}\b`       |
  | `betweenMarkers` | Everything between a start and end marker (non-greedy) | `start[\s\S]*?end`      |

- **Regex** (`.regex`, the default and the only shape older config files know) — a raw `NSRegularExpression` pattern. Validated through `safeCompile` in the editor *before* save (bad regex never reaches disk); at detection time bad rules are silently dropped (forward-compat: an old rule that no longer compiles can't crash the pipeline). Max pattern length is 512 chars to bound the matcher's work.

Both modes share two extras:

- **Case sensitivity** (`caseSensitive`, default `true`) — uncheck to match case-insensitively (compiles with `.caseInsensitive`). Defaults to `true` to preserve the historical behavior.
- **Custom placeholder label** (`placeholderLabel`, optional) — mint `[CUSTOMER_1]` instead of the category default `[SECRET_1]`. Sanitized to uppercase ASCII letters so the inbound `StreamingUnscrubber` (which only recognizes `[A-Z]+_<digits>` tokens) can still restore it.

A live test panel in the editor shows the generated pattern and what it matches against sample text as you type. The **Rules** tab also has an all-rules dry-run tester (see Getting Started) that runs the entire effective rule set at once.

### 4. On-device classifier (opt-in)

This layer is **off by default** and only runs when `aiDetectionEnabled` is on and the bundle is installed; the ~2.8 GB model is never downloaded otherwise. It adds the fuzzy categories regex can't model (`person`, `address`, `date`, `secret`).

The detection model is [`openai/privacy-filter`](https://huggingface.co/openai/privacy-filter) — OpenAI's bidirectional 1.5B-parameter / ~50M-active sparse-MoE token classifier, Apache-2.0 licensed. Sparse-MoE matters here: only ~50M of those 1.5B parameters fire per token, which is why a 2.8 GB BF16 model is practical to run locally per outbound request. Osaurus ships the MLX conversion at [`mlx-community/openai-privacy-filter-bf16`](https://huggingface.co/mlx-community/openai-privacy-filter-bf16).

The vendored `PrivacyFilterKit` decodes the model's BIOES-tagged token output with Viterbi calibration (`viterbi_calibration.json`) so adjacent tokens collapse into one span — `"John"` `"Doe"` becomes one `person` entity instead of two. The model's eight native categories (`person`, `email`, `phone`, `url`, `address`, `date`, `accountNumber`, `secret`) map 1:1 onto Osaurus's `EntityCategory` via `EntityCategory.init(_:)`.

Categories the classifier emits that aren't backed by a regex layer (`address`, `person`, `date`, `secret`) are model-only.

---

## Placeholder Wire Format

Placeholders are emitted as `[CATEGORY_N]` where `N` is per-category, per-conversation:

```
[PERSON_1]    [PERSON_2]    [PERSON_3]
[EMAIL_1]     [EMAIL_2]
[PHONE_1]
[URL_1]       [URL_2]
[ADDR_1]
[ACCT_1]
[DATE_1]
[SECRET_1]
```

`RedactionMap` interns by original string so `"Alice"` appearing five times in one conversation is always `[PERSON_1]`. The same original in a different conversation gets a fresh map and starts indices over at 1. Stability across turns matters because the model often refers back to entities ("about [PERSON_1]'s preference…") and the unscrubber needs to recall the original on the way back.

The category prefix is kept short (`PERSON`, `EMAIL`, `URL`, `ACCT`, `ADDR`, `PHONE`, `DATE`, `SECRET`) so the model doesn't waste attention on verbose placeholders.

A custom rule may override the prefix with its own `placeholderLabel` (e.g. `[CUSTOMER_1]`). To keep numbering collision-free, `RedactionMap` keys its counters by the **effective prefix string** (the custom label, or the category default), not by `EntityCategory` — so two rules that share a label across different categories still mint distinct tokens (`[TAG_1]`, `[TAG_2]`) rather than colliding. Labels are constrained to `[A-Z]+` so the `[A-Z]+_<digits>` tokens still round-trip through `StreamingUnscrubber` on the inbound side.

---

## Fail-Closed Guarantees

The pipeline throws — never silently sends — on five distinct failure modes. `RemoteProviderService` catches the typed `PrivacyFilterPipelineError` and surfaces a non-generic chat-bubble error instead of the standard "Error: …" rendering.

| Error case                | When it fires                                                                                          | What the user sees                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| `.reviewCanceled`         | User dismissed the review sheet or the awaiting task was cancelled                                     | "Privacy Filter: review canceled."                                  |
| `.engineUnavailable(d)`   | **AI detection on** but model bundle is missing / failed to load (regex-only sends never hit this — they don't load the model) | Points at **Settings → Privacy** to re-download or turn AI detection off |
| `.scrubNoOp(count)`       | User approved N entities but the substitution produced zero changes (`entity.original` doesn't match the wire text — almost always a bug) | "N approved redaction(s) didn't apply. Please report."              |
| `.scrubLeaked(counts)`    | Post-scrub re-scan of the outbound payload found PII the substitution missed. Send is blocked         | Per-category counts of what leaked, no raw values                   |
| (review cancel via Cmd-.) | `withTaskCancellationHandler` resolves the suspended continuation as `.canceled`                       | Same as `.reviewCanceled`                                            |

The post-scrub invariant only re-scans categories whose built-in regex is enabled. A user who explicitly turned off `phone` detection won't trip the leak check on a phone number — consistent with the principle that the same toggle controls both halves.

---

## The Review Sheet

The first turn that detects anything pops the redaction review sheet (per-conversation; once the user approves a session, subsequent turns of the same conversation can short-circuit via **Always Approve by Default** if enabled). The sheet has three regions:

1. **Detected entities list** — one row per `(category, original, placeholder)` triple. Toggle per-row to drop a false positive; the `.approved` flag flows into the scrub.
2. **Outgoing preview** — a scrubbed reconstruction of the message that would actually be sent. Highlighted placeholders reveal the original value on hover via `RedactionHoverController`. Uses the same `NSTextView` + `RedactionHighlighter` stack as the chat bubbles, so the preview's hover UX matches the inline highlights below.
3. **Send / Cancel** — Send is the default action (Return). Cancel aborts the request; the chat surface doesn't move and no HTTP fires.

Cancel is a *typed* cancel: `PrivacyReviewService.review` returns `.canceled`, the pipeline throws `PrivacyFilterPipelineError.reviewCanceled`, and the request layer aborts. Earlier versions returned a sentinel `([], map)` empty-message tuple, which silently produced malformed cloud requests when callers forgot to check.

---

## Chat-side Inline Highlights

Once a message ships, the chat surface replaces every placeholder with the original locally (via the conversation's `RedactionMap`) but visually marks each substitution. The renderer stack:

- `NativeMessageCellView` → `NativeMarkdownView` (the body) + `NativeThinkingView` (the thinking trace)
- `SelectableNSTextView` (custom `NSTextView` subclass) hosts the rendered attributed string
- `RedactionHighlighter` walks `NSTextStorage` and applies an underline + accent-tinted span to every original-value range
- `RedactionHoverController` tracks the mouse over those spans; hovering shows an `NSPopover` whose title/subtitle differ by direction (`outbound`: "Replaced with [PERSON_1]" → "stays on this device"; `inbound`: "Restored from [PERSON_1]" → "the original was unscrubbed locally"; `preview`: "Original value" → "stays on your Mac")

The hover tooltip's `Direction` enum is the single signal that lets the same component serve the chat bubble (placeholder ↔ original) and the review sheet's preview (placeholder → original) without forking the renderer.

---

## Insights Verification

Open **Insights** (`⌘ Shift I`) → pick a request → **Request** / **Response** tabs. Each tab has a sub-section labelled **Server Request** / **Server Response** showing the bytes captured by `WireTransportProbe` — i.e. the exact JSON sent to OpenAI / Anthropic / etc., and the exact stream that came back BEFORE the unscrubber ran.

This is the verification surface for "did the redaction actually take?" — if you see `[EMAIL_3]` in the Server Request body and `alice@example.com` in your local message, the filter worked. The pre-scrub local copy lives in **Request → Local** for comparison.

---

## Settings Surface

```
Privacy (Management → Privacy)  ← tabs always render; no model required
└── ManagerHeaderWithTabs
    │
    ├── Overview
    │   ├── Enable Privacy Filter (master toggle — regex layer, no download)
    │   ├── AI detection
    │   │   ├── (model ready)   toggle for aiDetectionEnabled
    │   │   └── (no model)      disabled + inline "Install" link → Model tab
    │   ├── (no-detector note)  shown when enabled but nothing can detect
    │   │                       (AI off + all built-ins off + no presets/customs)
    │   ├── Skip Code Blocks (fenced + inline)
    │   ├── Always Approve by Default (skip the sheet per-session)
    │   └── Conversation Privacy
    │       └── Forget Redactions in Every Conversation
    │
    ├── Rules
    │   ├── Detection Patterns (4 built-in toggles)
    │   ├── Preset Rules (collapsible, 5 patterns, all opt-in)
    │   ├── Custom Rules (Simple builder / Regex editor sheet)
    │   └── Dry-run tester (paste text → see every rule's hits + placeholder)
    │
    ├── Providers
    │   ├── per-provider override toggles (RemoteProvider.id keyed)
    │   └── empty state when no providers — points at Remote Providers tab
    │
    └── Model
        ├── (not installed) PrivacyInstallHero
        │   88pt accent-glow circle + state-driven icon
        │   "Install the on-device detection model"
        │   3 benefit cards + Install/Cancel/Retry CTA + progress
        └── (installed) Status card with bundle version + Re-verify + Remove
```

The tabbed surface renders immediately — the deterministic regex layer needs no model, so gating the whole UI behind a 2.8 GB download would hide a fully working feature. The install hero now lives inside the **Model** tab as its empty state (matching `SettingsEmptyState` visual weight — Schedules, Watchers, Skills — so the onboarding language is consistent across the app). The **AI detection** toggle in Overview is the only control that requires the bundle: it's disabled with an inline install link until the model verifies, and removing the model flips `aiDetectionEnabled` back off so the UI can't claim AI detection while the bundle is gone.

---

## Configuration Reference

| Setting                  | Default | Description                                                                                       |
| ------------------------ | ------- | ------------------------------------------------------------------------------------------------- |
| `enabled`                | `false` | Master toggle. When false the pipeline never invokes detection. Does **not** require the model — the regex layer runs on its own. |
| `aiDetectionEnabled`     | `false`* | Opt into the on-device AI classifier. When on, the pipeline loads the model and **fails closed** if it's missing; when off, detection is regex-only and never blocks on the model. *Fresh installs default `false` (regex-only, no download). A legacy config file missing this key decodes to `true` so users who already had the model keep AI detection on. |
| `skipCodeBlocks`         | `true`  | Skip fenced (` ``` `) + inline (` ` `) code spans.                                                |
| `alwaysApproveByDefault` | `false` | Skip the review sheet — still redact, just don't ask each turn.                                   |
| `builtinPatternEnabled`  | all on  | Per-category toggle (`phone` / `email` / `url` / `accountNumber`). Controls detection + leak check together. |
| `presetRules`            | `{}`    | Opt-in preset toggles by preset id. Missing keys → disabled.                                       |
| `customRules`            | `[]`    | User-defined `PrivacyRule` array (name, category, `kind` + raw `pattern` or `builder` spec, `caseSensitive`, optional `placeholderLabel`, enabled). |
| `providerOverrides`      | `{}`    | Per-provider enable map keyed by `RemoteProvider.id.uuidString`. Missing keys → true.             |

Stored at `~/.osaurus/config/privacy-filter.json`. The `Codable` decoder is hand-rolled (not synthesized) so new fields land with safe defaults instead of failing the whole decode when an older on-disk config file is missing them — turning on the master toggle in a future Osaurus that grows a new setting will never reset the user's other choices.

---

## Storage

| Path                                                                        | Contents                                                                            |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `~/.osaurus/config/privacy-filter.json`                                     | User configuration (plaintext, atomic write)                                        |
| `~/.osaurus/aux-models/openai-privacy-filter-bf16-v1/`                      | Model bundle (`config.json`, `model.safetensors`, `tokenizer.json`, calibration)    |
| `~/.osaurus/aux-models/openai-privacy-filter-bf16-v1/osaurus-manifest.json` | Locally generated SHA-256 manifest used by **Re-verify**                            |

The manifest is synthesized from Hugging Face's `/api/models/.../tree/main` payload at download time (LFS files expose `lfs.oid` which is a real SHA-256). The upstream repo doesn't ship one, so this is Osaurus's own integrity record. Re-verify re-hashes every required file and reports mismatches without re-downloading.

`SessionRedactionStore` is in-memory only — placeholder maps don't persist across app restarts, and each chat session has its own entry keyed by `sessionId`. **Forget Redactions in Every Conversation** in the Overview tab clears the live actor state; the next outbound send mints fresh placeholders.

---

## Per-Provider Overrides

The Providers tab lets you disable the filter for a specific cloud provider. Common reasons:

- A provider you trust to not log (e.g. an on-prem self-hosted deployment) doesn't need the redaction overhead
- A provider whose API rejects the placeholder shape (extremely rare — `[PERSON_1]` is plain text and the model treats it as a token sequence)
- Debugging — turn off scrubbing for one provider while diagnosing model behavior

Overrides are keyed by `RemoteProvider.id` (UUID) so renaming or re-creating a provider doesn't accidentally drop the user's preference; missing entries default to enabled.

---

## Threading and Persistence Notes

- `PrivacyFilterStore.save(_:)` is **synchronous**. Earlier versions deferred the JSON write through `Task.detached`, which let Cmd-Q race the write and reset the toggle to off on next launch. The encode + atomic write of the ~1 KB config is microseconds; main-thread cost is negligible.
- `snapshot()` is `nonisolated` and reads from a lock-protected in-memory cache that's updated on every save. The hot request path (`PrivacyFilterPipeline.applyOutbound`) calls `snapshot()` directly without an actor hop.
- A test-only `setOverrideDirectory(_:)` redirects the config path to a sandbox so the test suite can't clobber the user's real `privacy-filter.json` between runs. `PrivacyFilterStorePersistenceTests` covers the round-trip and the override swap semantics.

---

## Limitations

- The classifier is **English-leaning**. Non-English names and addresses get lower confidence and are easier to miss. The regex layer is locale-agnostic for shape-based categories (email, URL, IBAN, AWS keys) but can't help with names.
- **No semantic redaction.** "My medical history" passes through unchanged because the model classifies tokens, not topics. Combine with `alwaysApproveByDefault: false` so the review sheet shows you what was caught.
- **No cross-conversation memory of redactions.** Each session has its own `RedactionMap` keyed by `sessionId`; the same email in two different chats gets `[EMAIL_1]` in both, indexed independently. Replies referring to entities from another conversation arrive as raw `[EMAIL_1]` tokens the local map doesn't know how to resolve — the unscrubber logs and leaves them in place.
- **Local inference paths bypass the filter** by design — Apple Foundation Models route through `FoundationModelService`, local MLX models route through `MLXService`, and neither leaves your Mac. The pipeline only attaches to `RemoteProviderService`, so anything that doesn't go to a remote provider is never scrubbed (and doesn't need to be).
- **Multimodal / image content is NOT scanned.** `MessageScrubbing.appendScrubbableTexts` walks `content`, the text-typed entries of `contentParts`, every tool-call's argument JSON, and `reasoning_content`. Image URLs, inline base64 image data, and audio attachments are passed through untouched. PII captured in a screenshot or scan that the cloud model can OCR is therefore visible to the provider. Disable the filter or strip the attachment before sending if this matters.
- **Huge segments are split at `8 000` characters.** A pasted contract or transcript that exceeds this length is chunked before the classifier sees it. The detector still runs on every chunk, but each chunk is scored independently — long entities (e.g. a multi-line postal address) split across the chunk boundary may register as two partial matches instead of one. The cap exists to keep classifier latency and VRAM bounded.

---

## Multimodal Scanning (Design — not yet implemented)

> **Status:** design pass only. No outbound image/audio/video content is
> scanned today (see the Limitations bullet above). Shipping this is gated
> on a product decision (warn vs. strip vs. box-redact) and is intentionally
> NOT wired into the pipeline yet — adding a half-measure would risk the
> fail-closed contract for binary content.

### The gap

`MessageScrubbing.appendScrubbableTexts` only walks text: `content`, the
`.text` entries of `contentParts`, tool-call argument JSON, and
`reasoning_content`. Image parts (`MessageContentPart.imageUrl` — a `data:`
URL or an `http(s)` URL, surfaced via `ChatMessage.imageDataFromParts`),
audio, and video flow to the provider untouched. A cloud model can OCR a
pasted screenshot, so PII in an image is a real leak path the text filter
can't see.

### Reusable machinery (already on-device)

- **`ComputerUse/Perception/FrameScrubber.swift`** already does exactly the
  hard part for screenshots: Vision OCR → run the SAME `RegexEntityDetector`
  over the recognized text → paint opaque boxes over matched regions →
  return a `ScrubbedFrame` + `ScrubReport` (`textRegions`, `maskedRegions`,
  per-category counts). It supports `.pii` (mask only matches) and
  `.allText` (mask everything) modes.
- **`PrivacyFilterEngine.modelSpans(in:)`** is the seam for adding the
  model's NER categories (person / address / secret) on top of the regex
  layer over OCR'd text — best-effort, regex-only when the bundle isn't
  loaded.

### Product options (the decision to settle first)

| Option | Behavior | Pros | Cons |
| ------ | -------- | ---- | ---- |
| **Detect-and-warn** (recommended first step) | OCR each outbound image, run detection on the text, surface "this image appears to contain PII (N emails, 1 person…)" in the review sheet. User decides. | Non-destructive; no false-positive data loss; reuses the existing review sheet; matches the text path's "review before send" posture. | Doesn't remove the PII — the user must act (strip the attachment or send anyway). |
| **Box-redact** | Reuse `FrameScrubber` to paint boxes over matched regions and send the redacted image. | Strongest protection; image still useful to the model. | Destructive; OCR misses leak; alignment/UX work; no inbound "unscrub" (unlike text, a boxed image can't be restored). |
| **Strip** | Drop the image part entirely when PII is detected. | Simple; zero leak. | Most destructive; likely breaks the user's intent. |

### Recommended phased plan

1. **Phase A — detect-and-warn (opt-in).** Add an `aiImageScanEnabled`
   (or `scanImageContent`) config flag, default off. In
   `PrivacyFilterPipeline.applyOutbound`, when on, decode
   `ChatMessage.imageDataFromParts`, OCR via `FrameScrubber`'s recognizer,
   run `RegexEntityDetector` (+ `modelSpans` when AI detection is on), and
   attach a per-image `ScrubReport`-style summary to the review sheet as an
   advisory row. No bytes are modified; the user approves or cancels.
2. **Phase B — optional box-redact.** Behind its own toggle, let the user
   choose `.pii` box-redaction (reusing `FrameScrubber.scrub`) so the
   modified image replaces the original `contentParts` entry before send.

### Why it's gated

- **No inbound symmetry.** Text redaction round-trips via `RedactionMap` +
  `StreamingUnscrubber`; an image has no placeholder to restore, so
  box-redaction is one-way and must be a deliberate, well-understood choice.
- **Fail-closed cost.** Treating "couldn't OCR / model not loaded" as a hard
  block on every image-bearing send is a heavy default; detect-and-warn
  keeps the user in control without silently dropping content.
- **Latency.** OCR + per-region model passes are bounded in `FrameScrubber`
  (region cap) for screenshots; the chat path needs the same bound and a
  size guard before it runs on arbitrary pasted images.

Until the product decision lands, the text path's behavior is unchanged and
the limitation stays documented above and in the master-toggle copy.

---

## Troubleshooting

**Toggle resets to off after restart.** Fixed in the synchronous-save change. If it recurs, check that `~/.osaurus/config/privacy-filter.json` is writable (`-rw-r--r--`) and that `PrivacyFilterStore.setOverrideDirectory` isn't stuck on a leftover test path (only relevant if you're running Osaurus from a development build right after `swift test`).

**Review sheet appears but the send goes unscrubbed.** The sheet's Send button used to be wired through the `.approved` array but didn't always re-run the scrub when the user toggled individual entities off and then back on. Confirm by checking **Insights → Server Request** for placeholders. If you see raw PII in the wire body, file an issue with the request log — the `WireTransportProbe` capture is the smoking-gun evidence.

**"Privacy Filter is enabled but the on-device model isn't available."** You have **AI detection** on but the bundle isn't installed or failed to verify. Two fixes: (a) turn **AI detection** off in **Privacy → Overview** to fall back to the regex-only layer (no model needed), or (b) open **Privacy → Model** and click **Re-verify**. If the verifier reports mismatches, the easiest path is to delete `~/.osaurus/aux-models/openai-privacy-filter-bf16-v1/` and re-install from the **Model** tab.

**Per-category leak block is too aggressive.** The post-scrub invariant re-scans for the same categories as detection, so if you've enabled `awsKey` as a preset and your prompt legitimately contains a string that matches the AWS-key heuristic but ISN'T a key, the send blocks. Disable the preset or refine its pattern via a custom rule with a tighter regex.

---

## Code Layout

| Module                                                                 | Role                                                                                       |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `PrivacyFilter/Core/PrivacyFilterPipeline.swift`                       | Outbound scrub + inbound unscrub orchestration; typed errors                               |
| `PrivacyFilter/Core/PrivacyFilterEngine.swift`                         | Detection ensemble (regex + classifier) over a message history                              |
| `PrivacyFilter/Core/RegexEntityDetector.swift`                         | Built-in + preset + user regex detection                                                   |
| `PrivacyFilter/Core/PrivacyRulePresets.swift`                          | Ship-list of opt-in preset rules                                                           |
| `PrivacyFilter/Core/Placeholder.swift`                                 | `EntityCategory` + `[CATEGORY_N]` wire format                                              |
| `PrivacyFilter/Core/RedactionMap.swift`                                | Per-conversation intern of `original → placeholder`                                        |
| `PrivacyFilter/Core/CodeBlockMasker.swift`                             | Skip-code-blocks logic for the `skipCodeBlocks` config                                      |
| `PrivacyFilter/Core/StreamingUnscrubber.swift`                         | Splices into the inbound stream and replaces placeholders on the fly                       |
| `PrivacyFilter/Store/SessionRedactionStore.swift`                      | Per-session `RedactionMap` cache (actor) + auto-approve session set                        |
| `PrivacyFilter/Core/PrivacyReviewService.swift`                        | Modal review presenter registry + `.canceled` continuation contract                         |
| `PrivacyFilter/Model/PrivacyFilterModelBundle.swift`                   | On-disk bundle layout + SHA-256 verifier                                                    |
| `PrivacyFilter/Model/PrivacyFilterModelDownloader.swift`               | Hugging Face streaming download + manifest synthesis                                         |
| `PrivacyFilter/Store/PrivacyFilterConfiguration.swift`                 | Persisted user settings model (`Codable`, hand-rolled decoder)                              |
| `PrivacyFilter/Store/PrivacyFilterStore.swift`                         | JSON-on-disk persistence + lock-protected in-memory snapshot                                |
| `PrivacyFilter/Views/PrivacyView.swift`                                | Settings UI (4 sub-tabs always rendered; AI-detection toggle; Rules-tab dry-run tester; install hero inside Model tab) |
| `PrivacyFilter/Views/RedactionReviewSheet.swift`                       | Modal review sheet with scrubbed preview + hover-reveal                                     |
| `PrivacyFilter/Views/RedactionPreviewBuilder.swift`                    | Pure helper that turns `(original, placeholder)` pairs into scrubbed text + highlight map  |
| `PrivacyFilter/Views/RedactionPreviewTextView.swift`                   | `NSViewRepresentable` wrapper that reuses the chat's highlighter inside the review sheet  |
| `PrivacyFilter/Views/PrivacyCustomRuleEditor.swift`                    | Custom-rule editor sheet — Simple (no-regex builder) / Regex modes, case toggle, custom label, live test panel |
| `PrivacyFilter/Vendor/PrivacyFilterKit/`                               | Vendored detection kit (BIOES decoder, Viterbi calibration, label vocabulary)              |
| `Views/Chat/RedactionHighlighter.swift`                                | Walks `NSTextStorage` and applies underline + accent to placeholder ranges                  |
| `Views/Chat/RedactionHoverController.swift`                            | Hover tracking + `NSPopover` tooltip with direction-aware copy                              |
| `Services/Provider/WireTransportProbe.swift`                           | Captures post-scrub HTTP body + pre-unscrub stream for Insights verification                |
| `Tests/PrivacyFilter/PrivacyFilterStorePersistenceTests.swift`         | Regression coverage for the toggle-resets-on-quit bug                                       |
| `Tests/PrivacyFilter/PrivacyReviewServiceTests.swift`                  | Cancel + presenter-token + always-approve contracts                                         |
| `Tests/PrivacyFilter/PrivacyFilterPipelineCancelTests.swift`           | `.reviewCanceled` propagation contract                                                      |
| `Tests/PrivacyFilter/RedactionReviewContextTests.swift`                | `RedactionPreviewBuilder` substitution / dedup / ordering                                   |
| `Tests/PrivacyFilter/DecouplingAndBuilderTests.swift`                  | Regex-only path (`useModel: false`), `RuleBuilder.compile()`, per-rule case flag, custom-label minting + unscrub round-trip |
| `Tests/PrivacyFilter/PrivacyRuleConfigTests.swift`                     | `safeCompile`, `EffectiveRuleSet`, config/rule `Codable` round-trip + legacy decode defaults |
| `Tests/Chat/PrivacyHighlightAccumulatorTests.swift`                    | Chat-side highlight accumulator (FIFO cap, dedup, empty-original skip)                      |
| `Tests/Provider/WireTransportProbeTests.swift`                         | Probe lifecycle, task-local propagation, no-leak across requests                            |

---

## Related Docs

- [Memory](MEMORY.md) — what Osaurus *keeps* about your conversations (orthogonal to what gets scrubbed on send)
- [Remote Providers](REMOTE_PROVIDERS.md) — provider configuration; per-provider overrides in Privacy live alongside provider records
- [Developer Tools](DEVELOPER_TOOLS.md) — Insights surface used to verify wire-level redaction
- [Localization](LOCALIZATION.md) — adding new languages for the Privacy settings and review sheet
- [Security](SECURITY.md) — how to report a privacy bug responsibly
