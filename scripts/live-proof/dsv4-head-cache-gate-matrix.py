#!/usr/bin/env python3
"""Build the schema/fixture plan for the DSV4 head/cache live matrix.

This runner is intentionally transport-neutral.  It validates the manifest,
checks the process guard before every planned position, and emits only an
unproven plan. The present transport-neutral rows are not the frozen Gate 4/5
campaign (three fresh PIDs per arm plus three unload/reload cycles), so
``--execute`` fails closed. It never turns key presence into a live pass.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import sys
from typing import Any, Iterable


HERE = pathlib.Path(__file__).resolve().parent
VERIFY_PATH = HERE / "verify-dsv4-head-cache-qualification.py"
SPEC = importlib.util.spec_from_file_location("dsv4_head_cache_verifier", VERIFY_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - import failure is fatal
    raise RuntimeError(f"cannot load verifier: {VERIFY_PATH}")
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
sys.dont_write_bytecode = True
SPEC.loader.exec_module(VERIFY)


GATE_ROWS: tuple[dict[str, Any], ...] = (
    {
        "id": "ordinary-coding",
        "request_kind": "ordinary_coding",
        "arm": "A",
        "required_rails": ("visible_output", "token_rate", "greedy_output_hash"),
        "description": "A deterministic coding answer with visible output and a nonzero measured token rate.",
    },
    {
        "id": "instruction",
        "request_kind": "instruction",
        "arm": "A",
        "required_rails": ("visible_output", "instruction_followed", "token_rate"),
        "description": "A constrained instruction response with no hidden prompt coercion.",
    },
    {
        "id": "tool-call",
        "request_kind": "tool_call",
        "arm": "A",
        "required_rails": ("exact_tool_name", "parseable_json_args", "tool_result_continuation", "no_protocol_leak"),
        "description": "One exact tool call, exact JSON arguments, result grounding, and clean continuation.",
    },
    {
        "id": "refusal",
        "request_kind": "refusal",
        "arm": "A",
        "required_rails": ("refusal_text", "no_tool_call", "no_protocol_leak"),
        "description": "A refusal rail that does not execute a tool or leak parser markers.",
    },
    {
        "id": "long-context",
        "request_kind": "long_context",
        "arm": "A",
        "required_rails": ("prompt_token_count", "visible_output", "token_rate", "context_floor"),
        "description": "A long prompt whose rendered token count and output budget are recorded.",
    },
    {
        "id": "repeated-prefix-miss",
        "request_kind": "repeated_prefix_miss",
        "arm": "B",
        "required_rails": ("miss_counter_delta", "no_cache_identity_before_store", "output"),
        "description": "The first repeated-prefix position must be a measured miss.",
    },
    {
        "id": "repeated-prefix-hit",
        "request_kind": "repeated_prefix_hit",
        "arm": "B",
        "required_rails": ("hit_counter_delta", "same_cache_identity", "output"),
        "description": "The following identical prefix must be a measured hit with the same identity.",
    },
    {
        "id": "normal-unload",
        "request_kind": "normal_unload",
        "arm": "A",
        "required_rails": ("resident_before", "unloaded_after", "no_error"),
        "description": "Normal unload releases the resident model without a process error.",
    },
    {
        "id": "normal-reload",
        "request_kind": "normal_reload",
        "arm": "A",
        "required_rails": ("reloaded_after", "same_model_identity", "visible_output"),
        "description": "Reload reaches the same pinned model identity and produces visible output.",
    },
    {
        "id": "adapter-token-id",
        "request_kind": "adapter_token_id",
        "arm": "A",
        "required_rails": ("input_ids", "adapter_ids", "exact_match", "source_trace"),
        "description": "The adapter token-ID rail compares exact IDs rather than only token counts.",
    },
)


class MatrixError(ValueError):
    pass


def _load_manifest(path: pathlib.Path, expected: str | None, phase: str) -> tuple[dict[str, Any], Any]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise MatrixError(f"cannot read manifest: {exc}") from exc
    report = VERIFY.verify_manifest_bytes(data, expected_sha256=expected, phase=phase)
    try:
        value = json.loads(data.decode("utf-8"))
    except json.JSONDecodeError as exc:  # verifier already checked this; keep the error typed
        raise MatrixError(f"manifest decode failed after verification: {exc}") from exc
    return value, report


def _request_by_kind(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {str(row["kind"]): row for row in manifest["requests"]}


def _load_bound_fixture(manifest: dict[str, Any], fixture_id: str) -> dict[str, Any]:
    matches = [item for item in manifest["fixtures"] if item["id"] == fixture_id]
    if len(matches) != 1:
        raise MatrixError(f"manifest must bind exactly one {fixture_id} fixture")
    fixture = matches[0]
    path = pathlib.Path(fixture["path"])
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise MatrixError(f"cannot read bound fixture {fixture_id}: {exc}") from exc
    import hashlib

    if hashlib.sha256(data).hexdigest() != fixture["sha256"] or len(data) != fixture["size"]:
        raise MatrixError(f"bound fixture {fixture_id} changed after manifest verification")
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MatrixError(f"bound fixture {fixture_id} is invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise MatrixError(f"bound fixture {fixture_id} must be an object")
    return value


def build_plan(manifest: dict[str, Any], manifest_sha256: str) -> dict[str, Any]:
    requests = _request_by_kind(manifest)
    request_contract = _load_bound_fixture(manifest, "request-rails")
    output_contract = _load_bound_fixture(manifest, "output-rails")
    if set(request_contract) != {"fixture_version", "purpose", "requests"}:
        raise MatrixError("request-rails fixture has unknown or missing fields")
    if request_contract["fixture_version"] != "dsv4-head-cache-request/1":
        raise MatrixError("request-rails fixture version mismatch")
    if request_contract["requests"] != [row["id"] for row in GATE_ROWS]:
        raise MatrixError("request-rails fixture does not match the ordered schema rows")
    if set(output_contract) != {"fixture_version", "purpose", "rails"}:
        raise MatrixError("output-rails fixture has unknown or missing fields")
    if output_contract["fixture_version"] != "dsv4-head-cache-output/1":
        raise MatrixError("output-rails fixture version mismatch")
    fixture_rails = output_contract["rails"]
    if not isinstance(fixture_rails, dict):
        raise MatrixError("output-rails rails must be an object")
    rows: list[dict[str, Any]] = []
    for row in GATE_ROWS:
        request = requests.get(row["request_kind"])
        if request is None:
            raise MatrixError(f"manifest has no request for {row['request_kind']}")
        if request["arm"] != row["arm"]:
            raise MatrixError(f"request {request['id']} is bound to arm {request['arm']}, expected {row['arm']}")
        if fixture_rails.get(row["request_kind"]) != list(row["required_rails"]):
            raise MatrixError(f"output-rails fixture mismatch for {row['request_kind']}")
        rows.append(
            {
                "id": row["id"],
                "request_id": request["id"],
                "request_kind": row["request_kind"],
                "arm": row["arm"],
                "required_rails": list(row["required_rails"]),
                "description": row["description"],
                "status": "unproven",
                "live_gates_ran": False,
                "evidence": {},
                "failure": None,
            }
        )
    return {
        "schema": "dsv4-head-cache-gate-matrix/1",
        "manifest_sha256": manifest_sha256,
        "campaign_id": manifest["campaign_id"],
        "model_id": manifest["model"]["id"],
        "arm_order": ["A", "B", "P"],
        "rows": rows,
        "scope": "schema_plan_only",
        "qualification_capable": False,
        "frozen_live_requirements": {
            "gate_4": {
                "arms": ["A", "B"],
                "fresh_pids_per_arm": 3,
                "cases": [
                    "exact_instruction",
                    "compiled_short_coding",
                    "tool_call_injected_result_two_followups",
                    "benign_json",
                    "benign_fiction",
                    "harmful_refusal",
                    "prefix_miss_hit_same_prefix_different_suffix",
                    "context_4k_first_repeat",
                    "context_32k_4k_admission_first_repeat",
                ],
                "requires_exact_accepted_token_ids": True,
            },
            "gate_5": {
                "fresh_pids": 3,
                "unload_reload_cycles_per_pid": 3,
            },
        },
        "residual": "A live Gate 4/5 transport and semantic evidence validator are not implemented by this plan-only tool.",
        "live_gates_ran": False,
        "decision": "unproven",
    }


def run_matrix(
    manifest_path: pathlib.Path,
    expected_sha256: str,
    *,
    execute: bool,
) -> dict[str, Any]:
    manifest, preflight = _load_manifest(manifest_path, expected_sha256, "process")
    if preflight.model_bytes_hashed:
        raise MatrixError("process guard unexpectedly performed a full model byte hash")
    plan = build_plan(manifest, preflight.manifest_sha256)

    if execute:
        raise MatrixError(
            "live qualification is not implemented: this tool is schema/plan-only and cannot set qualified"
        )
    for row in plan["rows"]:
        guard = VERIFY.verify_manifest_file(manifest_path, expected_sha256=expected_sha256, phase="process")
        if guard.model_bytes_hashed:
            raise MatrixError(f"process guard hashed model bytes at matrix row {row['id']}")
        row["guard"] = {
            "phase": guard.phase,
            "model_bytes_hashed": guard.model_bytes_hashed,
            "model_entries": guard.model_entries,
            "identity_checks": guard.identity_checks,
        }
    return plan


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--expected-sha256", default=os.environ.get("OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256"), required=False)
    parser.add_argument("--out", type=pathlib.Path)
    parser.add_argument("--execute", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(argv) if argv is not None else None)
    if not args.expected_sha256:
        print("FAIL expected_manifest_sha256: required", file=sys.stderr)
        return 2
    try:
        result = run_matrix(
            args.manifest,
            args.expected_sha256,
            execute=args.execute,
        )
    except (VERIFY.QualificationError, MatrixError) as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.out:
        try:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(encoded, encoding="utf-8", newline="\n")
        except OSError as exc:
            print(f"FAIL output: cannot write {args.out}: {exc}", file=sys.stderr)
            return 2
    else:
        print(encoded, end="")
    print(
        f"PASS matrix rows={len(result['rows'])} live_gates_ran={str(result['live_gates_ran']).lower()} decision={result['decision']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
