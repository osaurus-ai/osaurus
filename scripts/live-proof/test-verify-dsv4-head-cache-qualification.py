#!/usr/bin/env python3
"""Focused fail-closed tests for the DSV4 qualification manifest verifier."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
VERIFY_PATH = HERE / "verify-dsv4-head-cache-qualification.py"
SPEC = importlib.util.spec_from_file_location("dsv4_qualification_verifier_tests", VERIFY_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
sys.dont_write_bytecode = True
SPEC.loader.exec_module(VERIFY)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_ref(path: pathlib.Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"path": str(path), "sha256": digest(data), "size": len(data)}


def model_ref(path: pathlib.Path) -> dict[str, object]:
    value = file_ref(path)
    info = path.stat()
    value["identity"] = {
        "device": info.st_dev,
        "inode": info.st_ino,
        "mtime_ns": info.st_mtime_ns,
    }
    return value


class ManifestFixture:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.revision = "a" * 40
        self.head = "b" * 40
        self.model_root = root / "model"
        self.model_root.mkdir()
        config = self._write(self.model_root / "config.json", b'{"model_type":"deepseek_v4"}\n')
        tokenizer = self._write(self.model_root / "tokenizer.json", b'{"tokens":["a","b"]}\n')
        weight = self._write(self.model_root / "model-00001-of-00001.safetensors", b"weight-bytes")

        attestation = self._write(root / "model-attestation.json", b'{"pinned":true}\n')
        runtime_settings = self._write(root / "runtime-settings.json", b'{"seed":42}\n')
        app = self._write(root / "osaurus-app", b"app-executable")
        cli = self._write(root / "osaurus-cli", b"cli-executable")
        metallib = self._write(root / "default.metallib", b"metal")
        effective = self._write(root / "effective-path.json", b'{"arm":"A"}\n')

        pins = []
        for index in range(4):
            pin = self._write(root / f"pin-{index}.json", f'{{"revision":"{self.revision}"}}\n'.encode())
            pins.append({"path": str(pin), "revision": self.revision})

        source_paths = [
            REPO / "Packages/OsaurusCore/Package.swift",
            REPO / "Packages/OsaurusCore/Services/ModelRuntime.swift",
            REPO / "Packages/OsaurusCore/Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift",
            REPO / "Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift",
        ]
        fixture_root = HERE / "fixtures" / "dsv4-head-cache-v1"
        fixture_paths = {
            "request-rails": fixture_root / "request-rails.json",
            "output-rails": fixture_root / "output-rails.json",
            "adapter-token-ids": fixture_root / "adapter-token-ids.json",
        }
        schemas = {
            "manifest": ("osaurus.dsv4-head-cache-qualification/1", HERE / "dsv4-head-cache-qualification-v1.schema.json"),
            "request": ("dsv4-head-cache-request/1", fixture_paths["request-rails"]),
            "output": ("dsv4-head-cache-output/1", fixture_paths["output-rails"]),
        }
        requests = []
        request_rows = [
            ("ordinary-coding", "ordinary_coding", "request-rails", "A"),
            ("instruction", "instruction", "request-rails", "A"),
            ("tool-call", "tool_call", "request-rails", "A"),
            ("refusal", "refusal", "request-rails", "A"),
            ("long-context", "long_context", "request-rails", "A"),
            ("repeated-prefix-miss", "repeated_prefix_miss", "request-rails", "B"),
            ("repeated-prefix-hit", "repeated_prefix_hit", "request-rails", "B"),
            ("normal-unload", "normal_unload", "output-rails", "A"),
            ("normal-reload", "normal_reload", "output-rails", "A"),
            ("adapter-token-id", "adapter_token_id", "adapter-token-ids", "A"),
        ]
        for request_id, kind, fixture_id, arm in request_rows:
            requests.append(
                {
                    "id": request_id,
                    "kind": kind,
                    "fixture_id": fixture_id,
                    "arm": arm,
                    "expected_rail": f"{kind}-rail",
                    "max_tokens": 64,
                    "trace_accepted_ids": kind != "normal_unload",
                }
            )

        campaign = root / "campaign"
        self.manifest = {
            "schema": "osaurus.dsv4-head-cache-qualification/1",
            "campaign_id": "unit-campaign",
            "sources": {"paths": [str(path) for path in source_paths], "base": self.revision, "head": self.head, "clean": True},
            "dependency_pins": pins,
            "artifacts": {"app_executable": file_ref(app), "cli": file_ref(cli), "default_metallib": file_ref(metallib)},
            "model": {
                "canonical_root": str(self.model_root),
                "id": "unit/dsv4",
                "revision": self.revision,
                "attestation": {
                    "type": "huggingface_revision",
                    "repository": "unit/dsv4",
                    "revision": self.revision,
                    **file_ref(attestation),
                },
                "inventory": {
                    "config": model_ref(config),
                    "tokenizer": [model_ref(tokenizer)],
                    "weights": [model_ref(weight)],
                    "file_count": 3,
                    "total_bytes": config.stat().st_size + tokenizer.stat().st_size + weight.stat().st_size,
                },
            },
            "schemas": {
                key: {"version": version, **file_ref(path)} for key, (version, path) in schemas.items()
            },
            "generation": {"seed": 42, "temperature": 0, "top_p": 1, "max_tokens": 64, "processors": ["greedy"], "eos": ["eos"], "stop": ["stop"]},
            "runtime_settings": {"exact_bytes": file_ref(runtime_settings), "mtp": False, "proposals": False, "decode_compile": False},
            "arms": {
                "A": {"id": "A", "mode": "exact", "environment": VERIFY.ARM_ENVIRONMENTS["A"], "cache_requested": False, "source_supported": True, "prepared": False, "cache_identity": None, "logical_bytes": 0, "shadow": {"declared": False, "logical_bytes": 0}},
                "B": {"id": "B", "mode": "exactCached", "environment": VERIFY.ARM_ENVIRONMENTS["B"], "cache_requested": True, "source_supported": True, "prepared": True, "cache_identity": "cache-1", "logical_bytes": 2_118_123_520, "shadow": {"declared": False, "logical_bytes": 0}},
                "P": {"id": "P", "mode": "qmm", "environment": VERIFY.ARM_ENVIRONMENTS["P"], "cache_requested": False, "source_supported": True, "prepared": False, "cache_identity": None, "logical_bytes": 0, "shadow": {"declared": False, "logical_bytes": 0}},
            },
            "diagnostics": {
                "shadow_control": {
                    "timed": False,
                    "environment": {"VMLX_DSV4_CACHE_FP32_LM_HEAD": "1", "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "1", "VMLX_DSV4_LM_HEAD_MODE": "exact"},
                    "snapshot": {"cache_requested": True, "shadow_requested": True, "source_quantized": True, "source_supported": True, "prepared": True, "logical_bytes": 2_118_123_520, "effective_path": "exact"},
                }
            },
            "effective_path_proof": {
                "source_gate": {**file_ref(source_paths[1]), "symbol": "ModelRuntime"},
                "adapter_gate": {**file_ref(source_paths[3]), "symbol": "MLXBatchAdapter"},
                "runtime_artifact": file_ref(effective),
                "arm_order": ["A", "B", "P"],
                "effective_arm": "A",
            },
            "requests": requests,
            "prefixes": {
                "miss": {"id": "prefix-miss", "request_id": "repeated-prefix-miss", "expected": "miss", "cache_identity": None},
                "hit": {"id": "prefix-hit", "request_id": "repeated-prefix-hit", "expected": "hit", "cache_identity": "cache-1"},
            },
            "fixtures": [{"id": fixture_id, **file_ref(path)} for fixture_id, path in fixture_paths.items()],
            "output": {
                "campaign_root": str(campaign),
                "ledger": str(campaign / "ledger.jsonl"),
                "stem": str(campaign / "qualification"),
                "state": str(campaign / "state"),
                "cache": str(campaign / "cache"),
                "tmp": str(campaign / "tmp"),
            },
            "safety": {"fail_closed": True, "allow_destructive_actions": False, "require_manifest_hash_env": True, "manifest_external": True, "live_claims": "none"},
            "decision": {"status": "unproven", "qualified": False, "live_gates_ran": False, "reason": "unit fixture"},
        }
        self.app = app

    @staticmethod
    def _write(path: pathlib.Path, data: bytes) -> pathlib.Path:
        path.write_bytes(data)
        return path

    def bytes(self, value: dict[str, object] | None = None) -> bytes:
        return (json.dumps(value or self.manifest, sort_keys=True, separators=(",", ":")) + "\n").encode()

    def write_manifest(self, value: dict[str, object] | None = None) -> pathlib.Path:
        path = self.root / "manifest.json"
        path.write_bytes(self.bytes(value))
        return path


class QualificationVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dsv4-qualification-test-")
        self.fixture = ManifestFixture(pathlib.Path(self.temporary.name).resolve())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def verify(self, value: dict[str, object] | None = None, phase: str = "process"):
        data = self.fixture.bytes(value)
        return VERIFY.verify_manifest_bytes(data, expected_sha256=digest(data), phase=phase)

    def test_pre_campaign_hashes_inventory_once_and_process_guard_does_not(self) -> None:
        pre = self.verify(phase="pre_campaign")
        process = self.verify(phase="process")
        self.assertTrue(pre.model_bytes_hashed)
        self.assertEqual(pre.model_bytes_hashed_count, 3)
        self.assertFalse(process.model_bytes_hashed)
        self.assertEqual(process.model_bytes_hashed_count, 0)
        self.assertEqual(process.identity_checks, 3)

    def test_exact_hash_is_checked_before_invalid_json_decode(self) -> None:
        with self.assertRaises(VERIFY.QualificationError) as caught:
            VERIFY.verify_manifest_bytes(b"not-json", expected_sha256="0" * 64, phase="process")
        self.assertEqual(caught.exception.field, "expected_manifest_sha256")

    def test_normal_process_has_no_arm_and_exact_process_arms_are_disjoint(self) -> None:
        self.assertIsNone(VERIFY.validate_process_arm_environment({}))
        for arm, controls in VERIFY.ARM_ENVIRONMENTS.items():
            self.assertEqual(
                VERIFY.validate_process_arm_environment(
                    {VERIFY.ARM_ENVIRONMENT_KEY: arm, **controls}
                ),
                arm,
            )
        with self.assertRaises(VERIFY.QualificationError):
            VERIFY.validate_process_arm_environment(
                {
                    VERIFY.ARM_ENVIRONMENT_KEY: "B",
                    **VERIFY.ARM_ENVIRONMENTS["A"],
                }
            )

    def test_pre_model_guard_binds_request_and_model_before_work(self) -> None:
        manifest_path = self.fixture.write_manifest()
        environment = {
            "OSAURUS_DSV4_QUALIFICATION_MANIFEST": str(manifest_path),
            "OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256": digest(manifest_path.read_bytes()),
            VERIFY.ARM_ENVIRONMENT_KEY: "A",
            **VERIFY.ARM_ENVIRONMENTS["A"],
        }
        report = VERIFY.verify_pre_model_work(
            manifest_path,
            environment["OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256"],
            model_id="unit/dsv4",
            request_id="ordinary-coding",
            environment=environment,
        )
        self.assertEqual(report.phase, "process")
        bad = dict(environment)
        bad["VMLX_DSV4_CACHE_FP32_LM_HEAD"] = "1"
        with self.assertRaises(VERIFY.QualificationError) as caught:
            VERIFY.verify_pre_model_work(
                manifest_path,
                environment["OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256"],
                model_id="unit/dsv4",
                request_id="ordinary-coding",
                environment=bad,
            )
        self.assertEqual(caught.exception.field, "VMLX_DSV4_CACHE_FP32_LM_HEAD")

    def test_unknown_fields_duplicate_ids_and_bad_digests_fail_closed(self) -> None:
        unknown = copy.deepcopy(self.fixture.manifest)
        unknown["unexpected"] = True
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(unknown)
        duplicate = copy.deepcopy(self.fixture.manifest)
        duplicate["requests"][1]["id"] = duplicate["requests"][0]["id"]
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(duplicate)
        malformed = copy.deepcopy(self.fixture.manifest)
        malformed["artifacts"]["app_executable"]["sha256"] = "ABC"
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(malformed)

    def test_fixture_lookalike_path_is_rejected(self) -> None:
        lookalike = self.fixture.root / "scripts" / "live-proof" / "fixtures" / "dsv4-head-cache-v1-lookalike"
        lookalike.mkdir(parents=True)
        fake = lookalike / "request-rails.json"
        fake.write_text("{}\n", encoding="utf-8")
        value = copy.deepcopy(self.fixture.manifest)
        value["fixtures"][0] = {"id": "request-rails", **file_ref(fake)}
        with self.assertRaises(VERIFY.QualificationError) as caught:
            self.verify(value)
        self.assertEqual(caught.exception.field, "fixtures[0].path")

    def test_schema_stamps_bind_exact_tracked_bytes_and_paths(self) -> None:
        value = copy.deepcopy(self.fixture.manifest)
        value["schemas"]["request"]["path"] = value["schemas"]["output"]["path"]
        value["schemas"]["request"]["sha256"] = value["schemas"]["output"]["sha256"]
        value["schemas"]["request"]["size"] = value["schemas"]["output"]["size"]
        with self.assertRaises(VERIFY.QualificationError) as caught:
            self.verify(value)
        self.assertEqual(caught.exception.field, "schemas.request.path")

    def test_timed_shadow_and_source_support_contracts_are_exact(self) -> None:
        shadow = copy.deepcopy(self.fixture.manifest)
        shadow["arms"]["B"]["shadow"] = {"declared": True, "logical_bytes": 2_118_123_520}
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(shadow)
        support = copy.deepcopy(self.fixture.manifest)
        support["arms"]["A"]["source_supported"] = False
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(support)
        diagnostic = copy.deepcopy(self.fixture.manifest)
        diagnostic["diagnostics"]["shadow_control"]["timed"] = True
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(diagnostic)

    def test_trace_selection_field_is_required_and_false_only_for_unload(self) -> None:
        missing = copy.deepcopy(self.fixture.manifest)
        del missing["requests"][0]["trace_accepted_ids"]
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(missing)
        wrong = copy.deepcopy(self.fixture.manifest)
        wrong["requests"][0]["trace_accepted_ids"] = False
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(wrong)
        unload = copy.deepcopy(self.fixture.manifest)
        unload["requests"][7]["trace_accepted_ids"] = True
        with self.assertRaises(VERIFY.QualificationError):
            self.verify(unload)

    def test_process_identity_guard_detects_same_size_rewrite(self) -> None:
        tokenizer = self.fixture.model_root / "tokenizer.json"
        original = tokenizer.read_bytes()
        tokenizer.write_bytes(bytes(reversed(original)))
        self.assertEqual(len(original), tokenizer.stat().st_size)
        with self.assertRaises(VERIFY.QualificationError) as caught:
            self.verify(phase="process")
        self.assertIn("identity mismatch", str(caught.exception))

    def test_reservation_uses_one_sealed_read_and_creates_every_rail(self) -> None:
        path = self.fixture.write_manifest()
        expected = digest(path.read_bytes())
        original_reader = VERIFY._read_manifest_file
        with mock.patch.object(VERIFY, "_read_manifest_file", wraps=original_reader) as reader:
            VERIFY.reserve_output(str(path), expected)
        self.assertEqual(reader.call_count, 1)
        output = self.fixture.manifest["output"]
        for key in ("campaign_root", "state", "cache", "tmp"):
            self.assertTrue(pathlib.Path(output[key]).is_dir())
        for key in ("ledger", "stem"):
            self.assertTrue(pathlib.Path(output[key]).is_file())

    def test_invalid_manifest_creates_no_campaign_root(self) -> None:
        value = copy.deepcopy(self.fixture.manifest)
        value["arms"]["B"]["shadow"]["declared"] = True
        path = self.fixture.write_manifest(value)
        with self.assertRaises(VERIFY.QualificationError):
            VERIFY.reserve_output(str(path), digest(path.read_bytes()))
        self.assertFalse(pathlib.Path(value["output"]["campaign_root"]).exists())


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--emit-fixture":
        destination = pathlib.Path(sys.argv[2]).resolve()
        destination.mkdir(parents=True, exist_ok=True)
        print(ManifestFixture(destination).write_manifest())
    else:
        unittest.main()
