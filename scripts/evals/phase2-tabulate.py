#!/usr/bin/env python3
"""Tabulate a phase2-run-lanes.sh output directory for the PR body.

Usage: phase2-tabulate.py <lane-dir> [--failures] [--judged]

Prints one markdown row per (suite, model, routing) report: passed/total,
failed and errored counts, token-weighted decode tok/s, peak physical
footprint, and the state_call_rate line when the log has one.
--failures lists every non-passing case with its first failing note.
--judged dumps every self-judged rubric verdict beside the final answer,
for manual grading when no external judge key is available.
Deterministic parsing only; it runs nothing.
"""
import glob
import json
import os
import re
import sys


def load(path):
    with open(path) as handle:
        return json.load(handle)


def decode_rate(cases):
    weighted, weight = 0.0, 0
    for case in cases:
        tel = case.get("telemetry") or {}
        rate = tel.get("decodeTokensPerSecond")
        tokens = tel.get("completionTokens") or 1
        if rate:
            weighted += rate * tokens
            weight += tokens
    return weighted / weight if weight else None


def state_line(log_path):
    if not os.path.exists(log_path):
        return ""
    lines = open(log_path, errors="replace").read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("[state_call_rate]") and i + 1 < len(lines):
            return re.sub(r"\s+", " ", lines[i + 1]).strip()
    return ""


def first_failure(notes):
    for note in notes:
        if any(marker in note for marker in ("FAIL", "missing", "error", "errored")):
            return note[:200]
    return ""


def main():
    root = sys.argv[1]
    show_failures = "--failures" in sys.argv
    show_judged = "--judged" in sys.argv
    meta = os.path.join(root, "run.meta")
    if os.path.exists(meta):
        print("```\n" + open(meta).read().strip() + "\n```\n")
    print("| suite | model | routing | passed | failed | errored | decode tok/s | peak MB | state |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    reports = sorted(glob.glob(os.path.join(root, "*", "*.json")))
    for path in reports:
        suite = os.path.basename(os.path.dirname(path))
        name = os.path.basename(path)[: -len(".json")]
        model, _, routing = name.rpartition(".")
        data = load(path)
        cases = data.get("cases", [])
        count = {k: sum(1 for c in cases if c.get("outcome") == k) for k in ("passed", "failed", "errored")}
        rate = decode_rate(cases)
        peak = max(((c.get("telemetry") or {}).get("peakPhysFootprintMb") or 0) for c in cases) if cases else 0
        print(
            f"| {suite} | {data.get('modelId', model)} | {routing.replace('routing', '')} "
            f"| {count['passed']}/{len(cases)} | {count['failed']} | {count['errored']} "
            f"| {rate:.1f} | {peak:.0f} | {state_line(path[:-5] + '.log')} |"
            if rate is not None
            else f"| {suite} | {data.get('modelId', model)} | {routing.replace('routing', '')} "
            f"| {count['passed']}/{len(cases)} | {count['failed']} | {count['errored']} | n/a | {peak:.0f} "
            f"| {state_line(path[:-5] + '.log')} |"
        )
    if show_failures:
        print("\nNon-passing cases:\n")
        for path in reports:
            for case in load(path).get("cases", []):
                if case.get("outcome") != "passed":
                    print(f"- `{os.path.basename(path)}` {case['id']} ({case['outcome']}): "
                          f"{first_failure(case.get('notes', []))}")
    if show_judged:
        print("\nSelf-judged verdicts:\n")
        for path in reports:
            for case in load(path).get("cases", []):
                judge = case.get("judge") or {}
                if not judge.get("selfJudge"):
                    continue
                final = next((n for n in case.get("notes", []) if n.startswith("final:")), "")
                print(f"### {os.path.basename(path)} {case['id']} ({case['outcome']})")
                print(f"query: {case.get('query', '')}")
                print(final[:1500])
                for verdict in judge.get("verdicts", []):
                    print(f"- [{'pass' if verdict.get('pass') else 'FAIL'}] {verdict.get('condition')}")
                print()


if __name__ == "__main__":
    main()
