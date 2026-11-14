# Preserve prose after numeric dollar literals

An actual Gemma E2B MXFP4 calculator answer contained `($1081$) by $2$ is $2162$`. The inline renderer rejected the numeric pair under its existing currency rule, then reused the closing dollar as a new opener. It typeset `) by $2` as math, making coherent model output look broken.

The scanner now consumes both delimiters of a rejected numeric literal containing ASCII digits and decimal/grouping separators. It preserves that source text verbatim. Other rejected spans still resume after the opener, so a price such as `$5 to $10` does not consume a later `$O(n)$` expression. Numeric dollar literals remain literal under the existing currency policy. Model output, templates, reasoning parsing, tools and generation settings are unchanged.

## Component evidence

The new regression tests fail before the production change: 15 tests, three issues across two test functions. The exact production scanner replay on the recorded E2B response also fails. After the patch, all 52 focused scanner/Markdown tests across 19 suites pass, including existing currency, code, escaped-dollar, streaming and fallback-delimiter cases. The same recorded-response replay passes without changing its input.

Raw evidence is retained under `/Users/eric/vmlx-private-evidence/osaurus-cache-wiring-20261103/`: `INLINE-MATH-ACTUAL-E2B-BASELINE-RED.json`, `INLINE-MATH-ACTUAL-E2B-CORRECTED-GREEN.json`, and `inline-math-numeric-delimiters-focused-{red,green}.log`.

## Native acceptance boundary

Fresh isolated Release build 2026110418, source `164e1993160f764780bd6f8b084a912f47656e61`, pins runtime `ca5bdc98313aafd080475207cda4c29ec85392ee`. Its binary SHA256 is `cd63bb303effcd94a468f1418a9a96d64eb0322df63c3b925b0ac72d6f573fe3`. The native app displays the identical persisted E2B response with the complete prose intact. All seven original target request/response event dictionaries remain equal, including the separate wrong answer19227; all168 original profile file hashes remain unchanged after the candidate closes.

Two new real calculator workflows execute83*17→1411 and1411*2→2822, four actual model requests. The latter emits the same formerly broken numeric-dollar sentence shape and now displays it completely. Native UI rates106.8/104.7tok/s are correctness observations, not a controlled benchmark. Explicit ThinkingOff is the only generation override; sampler settings inherit the active bundle. Both tool cards settle, Stop disappears and input unlocks. The app and resource collector exit normally0 before freezing23artifacts in `INLINE-MATH-NUMERIC-LITERALS-NATIVE-QUALIFICATION-RECEIPT.json`. Physical footprint4.76GB still exceeds4.00GB weights: RAM FAIL remains.

Rebasing onto the normal parent consumer3313 merge changes ancestry only: the complete tree remains equal to the native-qualified implementation. The final documentation update does not change executable source or tests. Required hosted CI remains a separate merge gate, recorded in the PR receipt.

This patch does not repair the separate E2B tool-result grounding failure, MXFP4 F32/cache-key mismatch, image-recognition failures or RAM gates. It does not establish broad model readiness. No release tags or publishing.
