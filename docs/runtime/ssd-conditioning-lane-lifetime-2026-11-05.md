# SSD conditioning and model reload checkpoint

The runtime pin consumes vmlx-swift PRs #729, #730 and #731 through merge
`4d8cb97e18613f282ec27e969b32ef4a43324a64`. Four dependency locations and two
source-contract expectations move together. AgentLoop, orchestration, queues
and in-app tool implementations are unchanged.

The runtime retains optional DFlash hidden features at the target SSD boundary,
validates them on restore and falls back when optional data is missing or bad.
Required target checks remain intact. Warm image-history AR turns capture the
existing recurrent boundary inline when only text remains after restore.
Lane installation tracks weak live owners, so a newly loaded model receives
its own acceleration setup even when an old model's address is reused.

Validation includes 13 cache integration tests, the real BatchEngine boundary
regression, 77 adjacent passes with one inventory skip, and 23 normal Xcode
tests for lane lifetimes, source lookup and diagnostic children. The strengthened
64-lifetime Metal control failed 124 acceleration assertions before the owner
fix and passed after it. A normal Release dev app used the same final production
code: three growing AR media-history turns avoided full boundary replay; an
actual 45-second shell command returned stdout and restored 12,175 tokens for
its answer; three model unload/reload cycles each installed 305 target and 47
drafter projections and answered correctly. Native decode rates for the reload
turns were 79.95, 92.92 and 94.80 tokens/s. These are unpaired observations.

The app binary was built on runtime `9842ca9e` and consumer `cd546945`.
Subsequent runtime commits change tests/documentation only. Production-source
identity is verified against the merged pin; this repin changes dependency and
expectation metadata. The dev archive remains locally signed and unreleased.

Limits remain explicit. A cold AR stable-system seed still required a 9.196 s
rebuild. DFlash arithmetic, long-answer and numerical-parity failures remain,
including one wrong post-tool answer. Physical footprint fails the low-RAM
gate under retained owned loading. The broader focused run remains red with
source-directory and other parser/config assertions; focused repairs do not
relabel it green. Family-wide settings, media, concurrency and paired speed
qualification remain separate work. No release or tag is created.
