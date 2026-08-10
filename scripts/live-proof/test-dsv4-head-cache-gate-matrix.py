#!/usr/bin/env python3
"""Tests that the current Gate 4/5 grader remains honest and plan-only."""

from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


MATRIX = load("dsv4_gate_matrix_tests", HERE / "dsv4-head-cache-gate-matrix.py")
FIXTURES = load("dsv4_verifier_fixture_builder", HERE / "test-verify-dsv4-head-cache-qualification.py")


class GateMatrixTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dsv4-matrix-test-")
        self.fixture = FIXTURES.ManifestFixture(pathlib.Path(self.temporary.name).resolve())
        self.manifest_path = self.fixture.write_manifest()
        self.manifest_hash = hashlib.sha256(self.manifest_path.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_plan_is_explicitly_nonqualifying_and_lists_frozen_residual(self) -> None:
        plan = MATRIX.run_matrix(
            self.manifest_path,
            self.manifest_hash,
            execute=False,
        )
        self.assertEqual(plan["scope"], "schema_plan_only")
        self.assertFalse(plan["qualification_capable"])
        self.assertEqual(plan["decision"], "unproven")
        self.assertFalse(plan["live_gates_ran"])
        self.assertEqual(plan["frozen_live_requirements"]["gate_4"]["fresh_pids_per_arm"], 3)
        self.assertEqual(plan["frozen_live_requirements"]["gate_5"]["unload_reload_cycles_per_pid"], 3)
        self.assertIn("not implemented", plan["residual"])
        self.assertTrue(all(row["status"] == "unproven" for row in plan["rows"]))

    def test_execute_rejects_before_any_key_only_result_can_qualify(self) -> None:
        with self.assertRaises(MATRIX.MatrixError) as caught:
            MATRIX.run_matrix(
                self.manifest_path,
                self.manifest_hash,
                execute=True,
            )
        self.assertIn("cannot set qualified", str(caught.exception))

    def test_plan_checks_bound_request_and_output_contract_bytes(self) -> None:
        manifest, report = MATRIX._load_manifest(self.manifest_path, self.manifest_hash, "process")
        manifest["fixtures"][1]["sha256"] = "0" * 64
        with self.assertRaises(MATRIX.MatrixError):
            MATRIX.build_plan(manifest, report.manifest_sha256)

    def test_live_launcher_fails_before_manifest_verification_or_app_start(self) -> None:
        marker = pathlib.Path(self.temporary.name) / "app-started"
        fake_app = pathlib.Path(self.temporary.name) / "fake-app"
        fake_app.write_text(f"#!/bin/sh\ntouch '{marker}'\n", encoding="utf-8")
        fake_app.chmod(0o700)
        environment = os.environ.copy()
        environment.update(
            {
                "OSAURUS_DSV4_RUN_LIVE": "1",
                "OSAURUS_DSV4_OSAURUS_BIN": str(fake_app),
                "OSAURUS_DSV4_QUALIFICATION_MANIFEST": str(pathlib.Path(self.temporary.name) / "missing.json"),
                "OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256": "0" * 64,
            }
        )
        completed = subprocess.run(
            [str(HERE / "run-dsv4-head-cache-qualification.sh")],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn(b"schema/plan-only", completed.stderr)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
