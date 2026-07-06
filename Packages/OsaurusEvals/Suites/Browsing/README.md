# Browsing

Current-behavior browsing evidence for the native `osaurus.browser` plugin.

These cases exercise live `agent_loop` tool execution against deterministic
HTTP fixture pages supplied by `OSAURUS_EVALS_BROWSER_FIXTURE_URL`. They are
not security-result assertions: they do not claim unsafe URL blocking,
redirect/private-target blocking, redaction, or prompt-injection resistance.
Run evidence through `scripts/review/evals-browsing-evidence.sh` so the report
records the app checkout, the optional `osaurus-tools` source SHA, plugin
artifact hashes, fixture URL, model, commands, and per-case outcomes.

Direct run:

```bash
OSAURUS_EVALS_BROWSER_FIXTURE_URL=http://127.0.0.1:PORT \
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/Browsing \
  --model auto \
  --bootstrap-plugins \
  --transcripts \
  --out build/evals/pr-evidence/browsing-report.json
```

Cases skip when `osaurus.browser` is not loaded or the fixture URL environment
variable is absent.

The helper starts a loopback fixture server for deterministic current-behavior
proof. Future browser URL-policy adoption must keep that allowance eval-only
and continue blocking loopback in production by default.
