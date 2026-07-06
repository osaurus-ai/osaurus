#!/usr/bin/env bash
set -euo pipefail

# Emit a local-model-vs-reference diff table and per-failure class
# suggestions from optimization-loop run dirs (scripts/evals/optimization-loop.sh).
#
# Usage:
#   scripts/evals/triage-loop.sh <reports-dir> [candidate-dir]
#
#   <reports-dir>    run dir holding llm-*.json reports. The first non-remote
#                    model becomes the triaged column; a grok column (when
#                    present) is the reference for the differential table.
#   [candidate-dir]  optional newer run dir; its first model column replaces
#                    the triaged column while the reference stays from
#                    <reports-dir> (compare a scoped re-run against a full
#                    baseline without re-running the reference lane).
#
# Classes are triage SUGGESTIONS to seed a manual pass, not verdicts:
#   SUBSYSTEM           AppleScript-16B live/liveProof + live image lanes
#                       (matches EvalMatrixBuilder.isSubsystemCase)
#   EVAL-CONTRACT?      judge failed on narration-shaped rubric wording
#   HARNESS-INVESTIGATE compaction-family rows (verify watermark behavior)
#   MODEL               everything else — chat-model attributable

BASELINE="${1:?reports dir required}"
CANDIDATE="${2:-}"

python3 - <<PY
import collections
import json
import sys
from pathlib import Path

baseline = Path("$BASELINE")
candidate = Path("$CANDIDATE") if "$CANDIDATE" else None

REMOTE_PREFIXES = ("xai/", "openai/", "groq/", "openrouter/", "anthropic/", "google/", "deepseek/")


def load_cases(d, model_id):
    cases = {}
    for f in sorted(d.glob("*.json")):
        if any(x in f.name for x in ("matrix", "diff", "SNAPSHOT")):
            continue
        try:
            report = json.load(open(f))
        except Exception:
            continue
        if not isinstance(report, dict) or "cases" not in report:
            continue
        if report.get("modelId") != model_id:
            continue
        for c in report["cases"]:
            cases[c["id"]] = c
    return cases


def models_in(d):
    ids = set()
    for f in d.glob("*.json"):
        try:
            r = json.load(open(f))
            if isinstance(r, dict) and r.get("modelId"):
                ids.add(r["modelId"])
        except Exception:
            pass
    return sorted(ids)


def is_subsystem(cid, domain):
    # Mirrors EvalMatrixBuilder.isSubsystemCase.
    if domain == "apple_script":
        lower = cid.lower()
        return "liveproof" in lower or ".live-" in lower
    return domain == "subagent" and cid.startswith("subagent.image-")


def classify(cid, domain, notes):
    if is_subsystem(cid, domain):
        return "SUBSYSTEM"
    if "judge FAIL" in notes and any(x in notes.lower() for x in ("narrat", "describes an actual")):
        return "EVAL-CONTRACT?"
    if "compaction" in cid.lower():
        return "HARNESS-INVESTIGATE"
    return "MODEL"


def score(cases):
    passed = sum(1 for c in cases.values() if c["outcome"] == "passed")
    scored = sum(1 for c in cases.values() if c["outcome"] in ("passed", "failed"))
    return passed, scored


models = models_in(baseline)
if not models:
    print("no reports under", baseline, file=sys.stderr)
    sys.exit(1)

local = next((m for m in models if not m.startswith(REMOTE_PREFIXES)), models[0])
reference = next((m for m in models if "grok" in m), None)

b = load_cases(baseline, local)
if candidate and candidate.exists():
    cand_models = models_in(candidate)
    cand_local = next((m for m in cand_models if not m.startswith(REMOTE_PREFIXES)), None)
    if cand_local:
        overlay = load_cases(candidate, cand_local)
        b.update(overlay)
        local = cand_local
        print(f"# Overlay: {len(overlay)} case(s) for {cand_local} from {candidate}")

g = load_cases(baseline, reference) if reference else {}

passed, scored = score(b)
print(f"# Model: {local}")
print(f"# Totals: {passed}/{scored} ({100 * passed / scored:.1f}%)" if scored else "# Totals: 0/0")
if g:
    gp, gs = score(g)
    print(f"# Reference {reference}: {gp}/{gs} ({100 * gp / gs:.1f}%)" if gs else f"# Reference {reference}: 0/0")
    chat_b = {k: c for k, c in b.items() if not is_subsystem(k, c.get("domain", ""))}
    chat_g = {k: c for k, c in g.items() if not is_subsystem(k, c.get("domain", ""))}
    cb, cs = score(chat_b)
    cg, cgs = score(chat_g)
    if cs and cgs:
        print(f"# Chat-model attributable: {cb}/{cs} vs reference {cg}/{cgs} (gap {cg - cb})")

diff = [
    cid
    for cid in sorted(set(b) & set(g))
    if b[cid]["outcome"] == "failed" and g[cid]["outcome"] == "passed"
]
if diff:
    print(f"\n## local fail / reference pass ({len(diff)})")
    for cid in diff:
        notes = " ".join((b[cid].get("notes") or [])[:4])
        print(f"- {cid} — {classify(cid, b[cid].get('domain', ''), notes)}")

wins = [
    cid
    for cid in sorted(set(b) & set(g))
    if b[cid]["outcome"] == "passed" and g[cid]["outcome"] == "failed"
]
if wins:
    print(f"\n## local pass / reference fail ({len(wins)}) — regression guard")
    for cid in wins:
        print(f"- {cid}")

failures = [(cid, c) for cid, c in sorted(b.items()) if c["outcome"] in ("failed", "errored")]
by_class = collections.Counter()
for cid, c in failures:
    notes = " ".join((c.get("notes") or [])[:4])
    by_class[classify(cid, c.get("domain", ""), notes)] += 1
print(f"\n## Failure classes ({len(failures)})")
for k, v in sorted(by_class.items()):
    print(f"- {k}: {v}")
PY
