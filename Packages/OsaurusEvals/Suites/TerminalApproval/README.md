# Terminal Approval Eval Suite

Deterministic, model-free pins over how an external agent run's Ask cards
are answered from the `osaurus agent run` terminal. `TerminalApprovalEvalHarness`
(OsaurusCore) runs a probe `.ask` tool through the real `ToolRegistry` gate
on an external surface, the context `/agents/{id}/run` binds, and answers its
card through the same terminal-session API the `/approvals?session=` routes use.
No network, no model, no AppKit panel.

| Case | Scenario | Pins |
| --- | --- | --- |
| `terminal_approval.terminal-approve` | `terminal_approve` | The card reaches only its own session; other sessions and the phone can't see or answer it; `allow_once` runs the tool once. |
| `terminal_approval.terminal-deny` | `terminal_deny` | `deny` refuses the call; the tool never runs; an answered card can't be answered again. |
| `terminal_approval.headless-refusal` | `headless_refusal` | No session: refused with "requires interactive approval", no card, no run. |
| `terminal_approval.narrowed-answers` | `narrowed_answers` | On a per-call card, `always_allow` and `allow_for_run` become `allow_once`. |

## Run

```bash
make evals-deterministic FILTER=terminal_approval
swift run --package-path Packages/OsaurusEvals osaurus-evals run --suite Packages/OsaurusEvals/Suites/TerminalApproval --fail-on-floor
```
