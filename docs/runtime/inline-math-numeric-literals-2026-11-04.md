# Preserve prose after numeric dollar literals

An actual Gemma E2B MXFP4 calculator answer contained `($1081$) by $2$ is $2162$`. The inline renderer rejected the numeric pair under its existing currency rule, then reused the closing dollar as a new opener. It typeset `) by $2` as math, making coherent model output look broken.

The scanner now consumes both delimiters of a rejected numeric literal containing ASCII digits and decimal/grouping separators. It preserves that source text verbatim. Other rejected spans still resume after the opener, so a price such as `$5 to $10` does not consume a later `$O(n)$` expression. Numeric dollar literals remain literal under the existing currency policy. Model output, templates, reasoning parsing, tools and generation settings are unchanged.

## Component evidence

The new regression tests fail before the production change: 15 tests, three issues across two test functions. The exact production scanner replay on the recorded E2B response also fails. After the patch, all 52 focused scanner/Markdown tests across 19 suites pass, including existing currency, code, escaped-dollar, streaming and fallback-delimiter cases. The same recorded-response replay passes without changing its input.

Raw evidence is retained under `/Users/eric/vmlx-private-evidence/osaurus-cache-wiring-20261103/`: `INLINE-MATH-ACTUAL-E2B-BASELINE-RED.json`, `INLINE-MATH-ACTUAL-E2B-CORRECTED-GREEN.json`, and `inline-math-numeric-delimiters-focused-{red,green}.log`.

## Native acceptance boundary

A fresh isolated Release app must display the same persisted real E2B response without swallowing prose, then finish another real model/tool turn. Preserve before/after screenshots, unchanged response identity, app/source/runtime identity and the effective model request. Component tests alone do not close this boundary; native results and required CI belong in the PR receipt.

This patch does not repair the separate E2B tool-result grounding failure, MXFP4 F32/cache-key mismatch, image-recognition failures or RAM gates. It does not establish broad model readiness. No release tags or publishing.
