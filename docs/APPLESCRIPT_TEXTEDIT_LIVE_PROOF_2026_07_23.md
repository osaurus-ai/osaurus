# AppleScript TextEdit state and completion proof — 2026-07-23

## Scope

This checkpoint is intentionally limited to the reported TextEdit/AppleScript
regressions:

- a blank-document request typed invented/example text;
- TextEdit's startup Open panel was mistaken for an editable document;
- a successful mutation was retried or followed by an unrequested save;
- the helper returned success even when the requested UI postcondition was not
  present;
- an informational follow-up was incorrectly treated as a new tool request.

It does not claim to close Sandbox GPU utilization, global screen-context
freshness, cache-family coverage, or other model-runtime work.

## Source trace

Current branch base: Osaurus `main` at
`46c0748611a7ac07c400344f191a1e16abb2b74d`.

Workspace vMLX pin:
`7d6235316226ba9fe608018f86c463784e48b3d5`.

The old loop treated a successful `NSAppleScript` return as sufficient. In a
live baseline, `make new document` returned successfully while TextEdit still
showed its standard Open panel, so Osaurus finalized a false success. Small
AppleScript bundles also generated placeholder text through several distinct
forms (`text`, document properties, and `body`) and could place `save front
document` after `then`, outside the old line-start save matcher.

The patch:

- adds explicit TextEdit blank-document recipes for both AppleScript and
  Computer Use;
- recognizes only literal-free blank TextEdit creation tasks;
- rejects unauthorized text/body/content/value assignments and literal
  keystrokes before confirmation;
- recognizes inline `save ... document` as an unrequested save when the task
  did not opt in;
- accepts both AppleScript Command-N spellings for classification, then leaves
  syntax validity to the compile check;
- records the pre-action document count;
- requires both a larger document count and live Accessibility state
  `editable` with no Open panel before returning success;
- feeds a failed postcondition back for a bounded retry instead of silently
  finalizing.

No sampler override, forced reasoning tag, prompt answer, synthetic completion,
or hidden save behavior was added.

## Automated evidence

The following targeted macOS suites passed after the final inline-save change:

```text
OsaurusCoreTests/AppleScriptLoopTests
OsaurusCoreTests/AppRecipeTests
OsaurusCoreTests/AppleScriptAppKnowledgeTests
```

The invocation used the checked-in workspace and the isolated derived-data
directory:

```text
xcodebuild -workspace osaurus.xcworkspace \
  -scheme OsaurusCoreTests -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath /private/tmp/osaurus-applescript-live-derived-20260723 \
  -disableAutomaticPackageResolution -skipPackagePluginValidation test \
  -only-testing:OsaurusCoreTests/AppleScriptLoopTests \
  -only-testing:OsaurusCoreTests/AppRecipeTests \
  -only-testing:OsaurusCoreTests/AppleScriptAppKnowledgeTests
```

`git diff --check` and `swiftc -parse` also passed. Xcode emitted the
machine's pre-existing out-of-date CoreSimulator warning, but the macOS tests
executed and exited zero.

## Live UI evidence

All live rows use:

- an isolated Release app with bundle identifier
  `com.dinoki.osaurus.curootproof202607220512`;
- `OSAURUS_TEST_ROOT=/private/tmp/osaurus-cu-root-proof-root-20260722-2343`;
- keychain disabled for the proof app;
- actual Settings -> Agents -> Assistant -> Abilities -> Subagents ->
  AppleScript model selection;
- Confirm Each Script;
- Computer Use inspection of both the Osaurus approval/final state and the
  real TextEdit window.

Final Release executable:
`1035ff23916e7e2f99306423d81d486248e447e0ea94f5465ffbf359ad47f657`.

### Current-source final rows

- Shipped Osaurus AppleScript 8B JANG_6M, blank document: the first proposed
  script contained no invented text or save, but mistook TextEdit's Open panel
  for a document and failed before mutation. The bounded retry created one
  visibly blank editable document. Osaurus then emitted a terminal response;
  there was no duplicate text, save attempt, or hang. This is a safe recovery,
  not a one-shot pass.
- AppleScript 16B A4B JANG_4M, blank document: one approval containing only
  `make new document`; TextEdit's Open panel closed; one visibly blank,
  editable and unmodified document appeared; Osaurus emitted a terminal
  response. No retry, invented text, save, or hang.
- AppleScript 16B A4B JANG_4M, exact replacement: after `Hello World` was
  entered as the user, one approval contained one exact text assignment and no
  save. TextEdit visibly showed `Hello from OracHQ` exactly once and remained
  Edited. Osaurus emitted a terminal response. No retry or hang.
- Parent feedback-only message: the model acknowledged the information directly
  in 0.48 seconds TTFT. It did not call AppleScript, `mac_query`, or a
  date/time tool.

### Earlier checkpoint rows

- AppleScript 16B A4B JANG_4M, blank document: one safe approval, a visibly
  blank editable TextEdit window, and terminal Osaurus success. No retry or
  hang.
- AppleScript 16B A4B JANG_4M, exact replacement: the user-created text
  `Hello World` changed exactly once to `Hello from OracHQ`; the approval
  contained one direct `set text` statement and no save; TextEdit remained
  edited; Osaurus finalized successfully without retry.
- Parent feedback-only message: Osaurus acknowledged the message directly in
  0.60 seconds TTFT and did not call AppleScript, `mac_query`, or a date/time
  tool.
- Shipped Osaurus AppleScript 8B JANG_6M: unsafe generated text was rejected
  before approval until the model produced a safe `make new document`; the
  resulting document was visibly blank and Osaurus finalized.

### Regressions caught during live proof

- The shipped 8B used `set body ...` to inject canned text, exposing a missing
  alias in the content guard.
- The 16B used `keystroke "n" using command down`, exposing a classifier that
  accepted only the braced Command-N spelling.
- The shipped 8B used
  `if modified of front document then save front document`, exposing a
  line-start-only save matcher. The script was declined and not executed.
- With a stale frozen screen context naming Warp, the ambiguous phrase
  `the file` targeted Warp. That action was declined. The explicit TextEdit
  replacement path passed, but global frozen-context freshness is outside this
  PR and remains open.

## Final gate status

VERIFIED-LIVE for the narrow TextEdit/AppleScript scope above. The final
Release binary was ad-hoc signed, passed strict code-sign verification, and was
operated through the real Osaurus Settings, chat, approval, and TextEdit UI.
The shipped 8B row retains the explicit one-retry limitation described above.

Global frozen screen-context freshness, Sandbox GPU utilization, and broader
model/cache-family work remain outside this PR and are not claimed fixed.

No screenshots are added to Git history.
