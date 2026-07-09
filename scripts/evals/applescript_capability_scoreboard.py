#!/usr/bin/env python3
"""Roll up AppleScript capability-lab per-variant reports into a scoreboard.

Two modes:

  scoreboard  (default)
      applescript_capability_scoreboard.py <out_dir> <variant> [<variant> ...]
    Reads <out_dir>/<variant>.json (an EvalReport) for each variant, writes
    <out_dir>/scoreboard.json and <out_dir>/scoreboard.md, and prints the
    markdown. The scoreboard answers the lab's question: which HarnessOptions
    variant gets the most out of the fixed model.

  history
      applescript_capability_scoreboard.py --history <history.jsonl> <scoreboard.json>
    Appends one trend row (commit/label + per-variant pass rate) to the
    append-only history log, so a committed scoreboard has a small diff.

EvalReport JSON has no encoded `counts` (it's computed), so counts are derived
from `cases[].outcome` here. Missing/empty reports read as "no data", never a
crash — a live lane with no installed model legitimately produces skips.
"""

import datetime
import json
import os
import sys

OUTCOMES = ("passed", "failed", "skipped", "errored")


def load_report(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def counts_for(cases):
    counts = {key: 0 for key in OUTCOMES}
    for case in cases:
        outcome = case.get("outcome")
        if outcome in counts:
            counts[outcome] += 1
    counts["scored"] = counts["passed"] + counts["failed"]
    counts["total"] = len(cases)
    counts["passRate"] = (
        counts["passed"] / counts["scored"] if counts["scored"] else None
    )
    # Generation throughput (AGENTS.md: every generation row records token/s).
    # Mean of the per-case decode tok/s over model-driven rows; None when no
    # case carried the measurement (scripted lane / all-skip).
    rates = [
        case.get("telemetry", {}).get("decodeTokensPerSecond")
        for case in cases
        if isinstance(case.get("telemetry"), dict)
    ]
    rates = [rate for rate in rates if isinstance(rate, (int, float))]
    counts["meanTokensPerSecond"] = (sum(rates) / len(rates)) if rates else None
    return counts


def short_id(case_id):
    # Strip the domain prefix so the grid is readable: apple_script.live-x → live-x.
    return case_id.split(".", 1)[1] if "." in case_id else case_id


def badge(outcome):
    return {
        "passed": "PASS",
        "failed": "FAIL",
        "skipped": "SKIP",
        "errored": "ERR ",
    }.get(outcome, "  — ")


def fmt_rate(rate):
    return "—" if rate is None else f"{rate * 100:.0f}%"


def build_scoreboard(out_dir, variant_names):
    variants = []
    case_order = []
    seen = set()
    # The model UNDER TEST is whatever GENERATED the scripts. Prefer the
    # per-case `modelId` the runner actually resolved: the AppleScript loop
    # loads the installed local model (e.g. the 16B) via its own catalog even
    # when the harness's nominal `--model` is `auto`/keepCurrent and resolves to
    # a remote judge (e.g. xai/grok-4.3, bootstrapped from JUDGE_MODEL). The
    # report-level `modelId` is that nominal/judge label, so relying on it made
    # the scoreboard wrongly credit the judge with writing the AppleScript.
    # Fall back to the nominal id / MODEL env only when no case records a model.
    nominal_model = os.environ.get("MODEL", "")
    case_model = ""

    for name in variant_names:
        report = load_report(os.path.join(out_dir, f"{name}.json"))
        cases = (report or {}).get("cases", []) if report else []
        if report and report.get("modelId"):
            nominal_model = report["modelId"]
        outcomes = {}
        for case in cases:
            cid = short_id(case.get("id", "?"))
            outcomes[cid] = case.get("outcome", "")
            case_mid = case.get("modelId")
            if case_mid and not case_model:
                case_model = case_mid
            if cid not in seen:
                seen.add(cid)
                case_order.append(cid)
        entry = counts_for(cases)
        entry["name"] = name
        entry["cases"] = outcomes
        entry["hasReport"] = report is not None
        variants.append(entry)

    model_id = case_model or nominal_model

    scored_variants = [v for v in variants if v["scored"] > 0]
    best = None
    if scored_variants:
        best = max(
            scored_variants,
            key=lambda v: (v["passRate"] or 0, v["passed"], -v["failed"]),
        )["name"]

    return {
        "kind": "applescript_capability_scoreboard",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "model": model_id,
        "nominalModel": nominal_model,
        "filter": os.environ.get("FILTER", ""),
        "judge": os.environ.get("JUDGE_MODEL", ""),
        "label": os.environ.get("LABEL", ""),
        "caseOrder": case_order,
        "variants": variants,
        "best": best,
    }


def render_markdown(board):
    lines = ["# AppleScript capability scoreboard", ""]
    lines.append(f"- model (under test): `{board['model'] or '—'}`")
    nominal = board.get("nominalModel", "")
    if nominal and nominal != board.get("model"):
        lines.append(
            f"- harness nominal model: `{nominal}` "
            "(the `--model auto`/keepCurrent label — usually the remote judge; "
            "the AppleScript loop resolved its own local model above)"
        )
    lines.append(f"- filter: `{board['filter'] or '<all>'}`")
    lines.append(f"- judge: `{board['judge'] or '—'}`")
    if board.get("label"):
        lines.append(f"- label: {board['label']}")
    lines.append(f"- generated: {board['generatedAt']}")
    lines.append("")

    lines.append("## Variant summary")
    lines.append("")
    lines.append("| variant | pass | fail | skip | err | scored | pass rate | tok/s |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for v in board["variants"]:
        marker = " ⭐" if v["name"] == board["best"] else ""
        rate = v.get("meanTokensPerSecond")
        toks = "—" if rate is None else f"{rate:.1f}"
        lines.append(
            f"| {v['name']}{marker} | {v['passed']} | {v['failed']} | "
            f"{v['skipped']} | {v['errored']} | {v['scored']} | {fmt_rate(v['passRate'])} "
            f"| {toks} |"
        )
    lines.append("")
    if board["best"]:
        lines.append(f"Best variant: **{board['best']}**")
    else:
        lines.append(
            "No scored variants (every case skipped — is an AppleScript model installed?)."
        )
    lines.append("")

    if board["caseOrder"]:
        lines.append("## Case × variant")
        lines.append("")
        header = "| case | " + " | ".join(v["name"] for v in board["variants"]) + " |"
        sep = "|---|" + "|".join(["---"] * len(board["variants"])) + "|"
        lines.append(header)
        lines.append(sep)
        for cid in board["caseOrder"]:
            cells = [badge(v["cases"].get(cid, "")) for v in board["variants"]]
            lines.append(f"| {cid} | " + " | ".join(cells) + " |")
        lines.append("")
    return "\n".join(lines)


def append_history(history_path, scoreboard_path):
    board = load_report(scoreboard_path)
    if not board:
        sys.stderr.write(f"history: cannot read {scoreboard_path}\n")
        return 1
    row = {
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "commit": os.environ.get("COMMIT", ""),
        "label": os.environ.get("LABEL", "") or board.get("label", ""),
        "model": board.get("model", ""),
        "nominalModel": board.get("nominalModel", ""),
        "filter": board.get("filter", ""),
        "judge": board.get("judge", ""),
        "best": board.get("best"),
        "variants": {
            v["name"]: {
                "passed": v["passed"],
                "scored": v["scored"],
                "passRate": v["passRate"],
                "meanTokensPerSecond": v.get("meanTokensPerSecond"),
            }
            for v in board.get("variants", [])
        },
    }
    os.makedirs(os.path.dirname(history_path) or ".", exist_ok=True)
    with open(history_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--history":
        if len(argv) < 4:
            sys.stderr.write("usage: --history <history.jsonl> <scoreboard.json>\n")
            return 2
        return append_history(argv[2], argv[3])

    if len(argv) < 3:
        sys.stderr.write("usage: <out_dir> <variant> [<variant> ...]\n")
        return 2

    out_dir = argv[1]
    variant_names = argv[2:]
    board = build_scoreboard(out_dir, variant_names)

    with open(os.path.join(out_dir, "scoreboard.json"), "w", encoding="utf-8") as handle:
        json.dump(board, handle, indent=2, sort_keys=True)
    markdown = render_markdown(board)
    with open(os.path.join(out_dir, "scoreboard.md"), "w", encoding="utf-8") as handle:
        handle.write(markdown + "\n")
    print(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
