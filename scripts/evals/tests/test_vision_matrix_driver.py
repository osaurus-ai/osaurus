"""Driver regression tests; fake responses here are not model/runtime proof."""
import json
import os
import pathlib
import struct
import subprocess
import tempfile
import unittest


class VisionMatrixDriverTests(unittest.TestCase):
    def run_driver(self, outcome="passed", representatives=False, admitted=True, corrupt_header=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            bundles = []
            for name in ("first-neutral-bundle", "renamed-copy"):
                directory = root / name
                directory.mkdir()
                (directory / "config.json").write_text(json.dumps({"model_type": "fixture", "vision_config": {"depth": 1}}))
                header = json.dumps({"weight": {"dtype": "F16", "shape": [1], "data_offsets": [0, 2]}}).encode()
                (directory / "model.safetensors").write_bytes(struct.pack("<Q", len(header)) + header + b"\0\0")
                if corrupt_header and name == "renamed-copy":
                    (directory / "model.safetensors").write_bytes(b"broken")
                bundles.append({"modelID": name, "directory": str(directory), "modelType": "fixture",
                                "supportsImage": admitted, "declaresVision": admitted, "reason": "fixture", "tensorCount": 1})
            (root / "input.json").write_text(json.dumps(bundles))
            fake = root / "evals"
            fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
out = pathlib.Path(args[args.index('--out') + 1])
if args[0] == 'vision-inventory':
    out.write_text(pathlib.Path(os.environ['FIXTURE_INVENTORY']).read_text())
else:
    assert '--no-plugin-bootstrap' in args
    outcome = os.environ['FIXTURE_OUTCOME']
    if outcome != 'missing':
        out.write_text(json.dumps({'cases': [{'id': 'vision.image-runtime-history', 'outcome': outcome}]}))
''')
            fake.chmod(0o755)
            output = root / "proof"
            driver = pathlib.Path(__file__).resolve().parents[2] / "live-proof/run-installed-vision-evals.sh"
            command = ["/bin/bash", str(driver), str(fake), str(output)]
            if representatives:
                command.append("--representatives")
            result = subprocess.run(command, env={**os.environ, "FIXTURE_INVENTORY": str(root / "input.json"),
                                                   "FIXTURE_OUTCOME": outcome}, capture_output=True, text=True)
            report = output / "coverage-results.json"
            return result, json.loads(report.read_text()) if report.exists() else None

    def test_default_runs_all_and_retains_results_on_macos_bash(self):
        result, report = self.run_driver()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["selected_count"], 2)
        self.assertEqual([row["runtime_status"] for row in report["bundles"]], ["passed", "passed"])

    def test_representative_does_not_qualify_unexecuted_alias(self):
        result, report = self.run_driver(representatives=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["selected_count"], 1)
        self.assertEqual(sorted(row["runtime_status"] for row in report["bundles"]), ["not_run", "passed"])

    def test_missing_failed_and_skipped_reports_cannot_pass(self):
        for outcome in ("missing", "failed", "skipped"):
            with self.subTest(outcome=outcome):
                result, report = self.run_driver(outcome=outcome)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(all(row["runtime_status"] != "passed" for row in report["bundles"]))

    def test_empty_admission_inventory_cannot_pass(self):
        result, _ = self.run_driver(admitted=False)
        self.assertNotEqual(result.returncode, 0)

    def test_header_audit_failure_cannot_silently_omit_an_admitted_bundle(self):
        result, report = self.run_driver(corrupt_header=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["selected_count"], 1)
        broken = next(row for row in report["bundles"] if row["modelID"] == "renamed-copy")
        self.assertTrue(broken["header_errors"])
        self.assertEqual(broken["runtime_status"], "not_run")


if __name__ == "__main__":
    unittest.main()
