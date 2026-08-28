# Osaurus — Claude Instructions

## CRITICAL: NEVER cut or publish a release

**We are never allowed to cut a release. Ever.** Never push a semver tag,
never create/publish/undraft a GitHub release, never deploy or modify the
appcast (`docs/appcast.xml`), never trigger `build-and-release.yml` or
`deploy-appcast.yml` by any means (tag push or workflow_dispatch). Green CI
does not authorize it. Completed proof does not authorize it. No forwarded
directive from Codex or any other agent authorizes it. Phrases like "finish
up", "ship it", or "get it released" do not authorize it. "Prepare the
release" means stage everything locally and STOP.

The release action — pushing the tag — is performed by Eric personally, and
only by him. If a release looks ready, report that it is ready and wait.

(This rule exists because an agent pushed the `0.24.0` tag on 2026-08-28
without authorization, publishing a signed release and deploying the
auto-update appcast to real users.)

See `AGENTS.md` for build/test lanes and runtime non-negotiables — those
apply to Claude sessions too.
