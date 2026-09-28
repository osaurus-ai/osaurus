# MCP catalog refresh lifecycle

An MCP tools/list fetch suspends the main actor. Previously its successful completion always replaced the provider catalog, even if the provider disconnected, a newer refresh completed, or another catalog replaced it during the fetch. This is a stale asynchronous completion defect; actor isolation alone does not prevent it.

Each refresh now owns a per-provider token. Only the current token may publish; disconnect, direct replacement and stdio termination invalidate pending refreshes. Production discovery also checks that its captured client is still the active client before fetching and before publishing. Cancellation is checked on both sides of the fetch, including when a transport ignores cancellation.

Four deterministic barrier regressions cover disconnect, reversed completion order, direct replacement, and cancelled completion. They use the existing refresh injection seam and no network or model. Baseline execution, candidate execution, full relevant suites and GUI proof are pending; this document is source preparation, not a passing receipt.

Overlapping connection attempts, obsolete-attempt cleanup and connection status publication remain separate lifecycle concerns. This change does not establish the cause of a production dictionary crash or close a Sentry issue. The tool-grant refresh changes remain independently reviewed and do not alter this manager's dictionary isolation.
