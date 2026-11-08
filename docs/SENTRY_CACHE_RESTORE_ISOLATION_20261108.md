# Rotating KV restore isolation consumer checkpoint

The runtime pin consumes vmlx-swift #752, merged as
`1a227377fcca0e94ea8b6304f7cd9dff68791130`. Restored rotating caches now receive
independent mutable MLXArray wrappers while retaining copy-on-write storage.
Previously, advancing one restored request changed retained arrays and another
request's arrays without changing that other request's metadata.

The currently shipped runtime reproduces the failure in all four standalone /
composite and keep=0/1 fixture rows through public restoreFromDiskArrays. Its
exact regression XCTest has 24 failed assertions. A complete MLXLMCommon rebuild
with the fix passes the four-row public restore matrix and four affected XCTest
cases, including three existing disk-persistence guards. The runtime merge tree
matches that tested projection exactly. These tests use real Cmlx/Metal arrays.

This consumer checkpoint is PARTIAL until its fresh Osaurus development app has
passed the applicable live cache and multi-turn rows. No incident-specific Sentry
attribution, model-family readiness, speed improvement or release is claimed.
No generation defaults or cache settings change in this pin update.

Cumulative raw events, original failed runs, revised runs, compiler commands,
shader identity and retained disk fixtures are kept privately at
`/Users/eric/vmlx-private-evidence/sentry-inference-20261108/rotating-restore/`.
They must remain available through later iterations.
