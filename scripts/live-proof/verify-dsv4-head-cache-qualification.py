#!/usr/bin/env python3
"""Fail-closed verifier for the DSV4 FP32 lm-head qualification manifest.

The verifier has two deliberately different phases:

* ``pre_campaign`` hashes every model inventory file once, before a campaign
  root is created or any arm is started.
* ``process`` checks canonical paths, the exact inventory set, identity/size
  metadata, and the attestation binding.  It does not byte-hash model shards.

The second phase is what an app process or in-process guard can run at every
matrix position without repeatedly warming the file cache with approximately
79 large shard reads.  The manifest is never self-hashed; its exact bytes are
hashed before JSON decoding and compared with the caller-supplied pin.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import posixpath
import re
import stat
import sys
from dataclasses import dataclass
from typing import Any, Iterable, Mapping


HERE = pathlib.Path(__file__).resolve().parent
SCHEMA_ID = "osaurus.dsv4-head-cache-qualification/1"
ARM_ENVIRONMENT_KEY = "OSAURUS_DSV4_QUALIFICATION_ARM"
ARM_ENVIRONMENTS: dict[str, dict[str, str]] = {
    "A": {
        "VMLX_DSV4_LM_HEAD_MODE": "exact",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD": "0",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "0",
    },
    "B": {
        "VMLX_DSV4_LM_HEAD_MODE": "exact",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD": "1",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "0",
    },
    "P": {
        "VMLX_DSV4_LM_HEAD_MODE": "qmm",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD": "0",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "0",
    },
}
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ARRAY_ITEMS = 512
REQUIRED_SOURCE_SUFFIXES = {
    "Packages/OsaurusCore/Package.swift",
    "Packages/OsaurusCore/Services/ModelRuntime.swift",
    "Packages/OsaurusCore/Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift",
    "Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift",
}
REQUIRED_REQUEST_KINDS = {
    "ordinary_coding",
    "instruction",
    "tool_call",
    "refusal",
    "long_context",
    "repeated_prefix_miss",
    "repeated_prefix_hit",
    "normal_unload",
    "normal_reload",
    "adapter_token_id",
}
FIXTURE_ROOT = HERE / "fixtures" / "dsv4-head-cache-v1"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
PLACEHOLDER = re.compile(r"(?:__REPLACE|PLACEHOLDER|REPLACE_WITH|<REQUIRED_)", re.IGNORECASE)


class QualificationError(ValueError):
    """A deterministic manifest rejection with a stable field path."""

    def __init__(self, field: str, message: str):
        self.field = field
        self.message = message
        super().__init__(f"{field}: {message}")


@dataclass(frozen=True)
class VerificationReport:
    manifest_sha256: str
    phase: str
    campaign_id: str
    campaign_root: str
    model_entries: int
    model_bytes_hashed: bool
    model_bytes_hashed_count: int
    identity_checks: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "manifest_sha256": self.manifest_sha256,
            "phase": self.phase,
            "campaign_id": self.campaign_id,
            "campaign_root": self.campaign_root,
            "model_entries": self.model_entries,
            "model_bytes_hashed": self.model_bytes_hashed,
            "model_bytes_hashed_count": self.model_bytes_hashed_count,
            "identity_checks": self.identity_checks,
        }


def _fail(field: str, message: str) -> None:
    raise QualificationError(field, message)


def _placeholder(value: str) -> bool:
    return bool(PLACEHOLDER.search(value))


def _object(value: Any, field: str, allowed: set[str], required: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(field, "must be an object")
    unknown = sorted(set(value) - allowed)
    if unknown:
        _fail(field, "unknown field(s): " + ", ".join(unknown))
    missing = sorted(required - set(value))
    if missing:
        _fail(field, "missing field(s): " + ", ".join(missing))
    return value


def _array(value: Any, field: str, min_items: int = 0, max_items: int = MAX_ARRAY_ITEMS) -> list[Any]:
    if not isinstance(value, list):
        _fail(field, "must be an array")
    if len(value) < min_items:
        _fail(field, f"must contain at least {min_items} item(s)")
    if len(value) > max_items:
        _fail(field, f"exceeds bounded maximum of {max_items} items")
    return value


def _string(value: Any, field: str, *, nonempty: bool = True, max_length: int = 4096) -> str:
    if not isinstance(value, str):
        _fail(field, "must be a string")
    if nonempty and not value:
        _fail(field, "must not be empty")
    if len(value) > max_length:
        _fail(field, f"exceeds maximum length {max_length}")
    if _placeholder(value):
        _fail(field, "placeholder is not a live value")
    return value


def _bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        _fail(field, "must be a boolean")
    return value


def _int(value: Any, field: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(field, "must be an integer")
    if value < minimum:
        _fail(field, f"must be at least {minimum}")
    return value


def _digest(value: Any, field: str) -> str:
    value = _string(value, field, max_length=64)
    if not HEX64.fullmatch(value):
        _fail(field, "must be 64 lowercase hexadecimal characters")
    return value


def _revision(value: Any, field: str) -> str:
    value = _string(value, field, max_length=40)
    if not HEX40.fullmatch(value):
        _fail(field, "must be 40 lowercase hexadecimal characters")
    return value


def _id(value: Any, field: str) -> str:
    value = _string(value, field, max_length=128)
    if not ID.fullmatch(value):
        _fail(field, "must match the bounded lowercase identifier form")
    return value


def canonical_path(value: Any, field: str, *, must_exist: bool, directory: bool | None = None) -> str:
    """Validate a lexical absolute path and every existing component with lstat."""

    value = _string(value, field, max_length=4096)
    if "\x00" in value or not value.startswith("/") or value.startswith("//"):
        _fail(field, "must be a canonical absolute POSIX path")
    if value == "/" or value != posixpath.normpath(value):
        _fail(field, "must not contain '.', '..', repeated separators, or a non-normal form")

    components = value.split("/")[1:]
    if any(not component or component in {".", ".."} for component in components):
        _fail(field, "contains an invalid path component")

    current = "/"
    missing = False
    for index, component in enumerate(components):
        current = current + component if current == "/" else current + "/" + component
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            missing = True
            break
        except OSError as exc:
            _fail(field, f"cannot inspect path component {current}: {exc}")
        if stat.S_ISLNK(info.st_mode):
            _fail(field, f"symlink component is forbidden: {current}")
        if index < len(components) - 1 and not stat.S_ISDIR(info.st_mode):
            _fail(field, f"non-directory path component blocks the path: {current}")

    if must_exist:
        if missing:
            _fail(field, "path does not exist")
        try:
            info = os.lstat(value)
        except OSError as exc:
            _fail(field, f"cannot inspect final path: {exc}")
        if stat.S_ISLNK(info.st_mode):
            _fail(field, "final symlink is forbidden")
        if directory is True and not stat.S_ISDIR(info.st_mode):
            _fail(field, "must be a directory")
        if directory is False and not stat.S_ISREG(info.st_mode):
            _fail(field, "must be a regular file")
    return value


def _contained(path: str, root: str, field: str) -> None:
    try:
        common = os.path.commonpath([path, root])
    except ValueError:
        _fail(field, "path and root use incompatible path forms")
    if common != root:
        _fail(field, f"path escapes canonical root {root}")


def _stat_identity(path: str, field: str) -> dict[str, int]:
    try:
        info = os.lstat(path)
    except OSError as exc:
        _fail(field, f"cannot read identity metadata: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        _fail(field, "identity target must be a regular non-symlink file")
    return {
        "device": int(info.st_dev),
        "inode": int(info.st_ino),
        "mtime_ns": int(info.st_mtime_ns),
    }


def _identity(value: Any, field: str) -> dict[str, int]:
    value = _object(value, field, {"device", "inode", "mtime_ns"}, {"device", "inode", "mtime_ns"})
    return {
        "device": _int(value["device"], f"{field}.device"),
        "inode": _int(value["inode"], f"{field}.inode"),
        "mtime_ns": _int(value["mtime_ns"], f"{field}.mtime_ns"),
    }


def _sha256_file(path: str, field: str) -> str:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            while True:
                block = handle.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
    except OSError as exc:
        _fail(field, f"cannot hash file: {exc}")
    return digest.hexdigest()


def _file_ref(
    value: Any,
    field: str,
    *,
    verify_bytes: bool,
    identity_required: bool = False,
    root: str | None = None,
    fixture_root: str | None = None,
) -> tuple[str, int, dict[str, int] | None]:
    allowed = {"path", "sha256", "size"} | ({"identity"} if identity_required else set())
    required = {"path", "sha256", "size"} | ({"identity"} if identity_required else set())
    value = _object(value, field, allowed, required)
    path = canonical_path(value["path"], f"{field}.path", must_exist=True, directory=False)
    if root is not None:
        _contained(path, root, f"{field}.path")
    if fixture_root is not None:
        _contained(path, fixture_root, f"{field}.path")
    expected_size = _int(value["size"], f"{field}.size")
    expected_hash = _digest(value["sha256"], f"{field}.sha256")
    try:
        actual_size = os.lstat(path).st_size
    except OSError as exc:
        _fail(field, f"cannot stat file: {exc}")
    if actual_size != expected_size:
        _fail(field, f"size mismatch: manifest={expected_size}, disk={actual_size}")
    identity = None
    if identity_required:
        identity = _identity(value["identity"], f"{field}.identity")
    if verify_bytes and _sha256_file(path, field) != expected_hash:
        _fail(field, "SHA-256 mismatch")
    return path, expected_size, identity


def _source_binding(value: Any, field: str, *, expected_suffix: str | None) -> None:
    value = _object(value, field, {"path", "sha256", "size", "symbol"}, {"path", "sha256", "size", "symbol"})
    path = canonical_path(value["path"], f"{field}.path", must_exist=True, directory=False)
    if expected_suffix and not path.endswith(expected_suffix):
        _fail(f"{field}.path", f"must bind {expected_suffix}")
    _digest(value["sha256"], f"{field}.sha256")
    _int(value["size"], f"{field}.size")
    _string(value["symbol"], f"{field}.symbol")
    actual_size = os.lstat(path).st_size
    if actual_size != value["size"]:
        _fail(field, "source binding size mismatch")
    if _sha256_file(path, field) != value["sha256"]:
        _fail(field, "source binding SHA-256 mismatch")


def _validate_sources(value: Any) -> None:
    value = _object(value, "sources", {"paths", "base", "head", "clean", "sealed_diff"}, {"paths", "base", "head"})
    paths = _array(value["paths"], "sources.paths", min_items=len(REQUIRED_SOURCE_SUFFIXES))
    normalized = [canonical_path(path, f"sources.paths[{index}]", must_exist=True, directory=False) for index, path in enumerate(paths)]
    if len(set(normalized)) != len(normalized):
        _fail("sources.paths", "duplicate paths are forbidden")
    missing = sorted(suffix for suffix in REQUIRED_SOURCE_SUFFIXES if not any(path.endswith(suffix) for path in normalized))
    if missing:
        _fail("sources.paths", "missing required source binding(s): " + ", ".join(missing))
    _revision(value["base"], "sources.base")
    _revision(value["head"], "sources.head")
    has_clean = "clean" in value
    has_diff = "sealed_diff" in value
    if has_clean == has_diff:
        _fail("sources", "provide exactly one of clean or sealed_diff")
    if has_clean and value["clean"] is not True:
        _fail("sources.clean", "must be true when supplied")
    if has_diff:
        _file_ref(value["sealed_diff"], "sources.sealed_diff", verify_bytes=True)


def _validate_dependency_pins(value: Any) -> str:
    pins = _array(value, "dependency_pins", min_items=4, max_items=4)
    revisions: list[str] = []
    paths: list[str] = []
    for index, pin in enumerate(pins):
        pin = _object(pin, f"dependency_pins[{index}]", {"path", "revision"}, {"path", "revision"})
        path = canonical_path(pin["path"], f"dependency_pins[{index}].path", must_exist=True, directory=False)
        revision = _revision(pin["revision"], f"dependency_pins[{index}].revision")
        paths.append(path)
        revisions.append(revision)
        try:
            with open(path, "rb") as handle:
                content = handle.read()
        except OSError as exc:
            _fail(f"dependency_pins[{index}].path", f"cannot read pin surface: {exc}")
        if revision.encode("ascii") not in content:
            _fail(f"dependency_pins[{index}]", "path does not contain the bound revision")
    if len(set(paths)) != 4:
        _fail("dependency_pins", "the four paths must be distinct")
    if len(set(revisions)) != 1:
        _fail("dependency_pins", "all four paths must bind the same revision")
    return revisions[0]


def _validate_model(value: Any, *, verify_bytes: bool) -> tuple[int, int, int]:
    value = _object(value, "model", {"canonical_root", "id", "revision", "attestation", "inventory"}, {"canonical_root", "id", "revision", "attestation", "inventory"})
    root = canonical_path(value["canonical_root"], "model.canonical_root", must_exist=True, directory=True)
    _string(value["id"], "model.id", max_length=512)
    revision = _revision(value["revision"], "model.revision")

    attestation = _object(
        value["attestation"],
        "model.attestation",
        {"type", "repository", "revision", "path", "sha256", "size"},
        {"type", "repository", "revision", "path", "sha256", "size"},
    )
    if attestation["type"] not in {"huggingface_revision", "local_signed_attestation"}:
        _fail("model.attestation.type", "unsupported attestation type")
    _string(attestation["repository"], "model.attestation.repository")
    if _revision(attestation["revision"], "model.attestation.revision") != revision:
        _fail("model.attestation.revision", "must equal model.revision")
    _file_ref(
        {key: attestation[key] for key in ("path", "sha256", "size")},
        "model.attestation",
        verify_bytes=True,
    )

    inventory = _object(
        value["inventory"],
        "model.inventory",
        {"config", "tokenizer", "weights", "file_count", "total_bytes"},
        {"config", "tokenizer", "weights", "file_count", "total_bytes"},
    )
    file_refs: list[tuple[str, int, dict[str, int] | None]] = []
    config = _file_ref(
        inventory["config"],
        "model.inventory.config",
        verify_bytes=verify_bytes,
        identity_required=True,
        root=root,
    )
    file_refs.append(config)
    tokenizer = _array(inventory["tokenizer"], "model.inventory.tokenizer", min_items=1)
    for index, item in enumerate(tokenizer):
        file_refs.append(
            _file_ref(
                item,
                f"model.inventory.tokenizer[{index}]",
                verify_bytes=verify_bytes,
                identity_required=True,
                root=root,
            )
        )
    weights = _array(inventory["weights"], "model.inventory.weights", min_items=1, max_items=256)
    for index, item in enumerate(weights):
        file_refs.append(
            _file_ref(
                item,
                f"model.inventory.weights[{index}]",
                verify_bytes=verify_bytes,
                identity_required=True,
                root=root,
            )
        )
    expected_count = _int(inventory["file_count"], "model.inventory.file_count", minimum=3)
    expected_total = _int(inventory["total_bytes"], "model.inventory.total_bytes")
    if expected_count != len(file_refs):
        _fail("model.inventory.file_count", f"must equal exact inventory count {len(file_refs)}")
    if expected_total != sum(size for _, size, _ in file_refs):
        _fail("model.inventory.total_bytes", "does not equal the exact inventory byte sum")

    expected_paths = {path for path, _, _ in file_refs}
    actual_paths: set[str] = set()
    for current_root, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        for directory_name in list(dirnames):
            directory_path = os.path.join(current_root, directory_name)
            if os.path.islink(directory_path):
                _fail("model.inventory", f"symlink directory is forbidden: {directory_path}")
        for filename in filenames:
            file_path = os.path.join(current_root, filename)
            if os.path.islink(file_path):
                _fail("model.inventory", f"symlink file is forbidden: {file_path}")
            if stat.S_ISREG(os.lstat(file_path).st_mode):
                actual_paths.add(canonical_path(file_path, "model.inventory.actual", must_exist=True, directory=False))
    if actual_paths != expected_paths:
        missing = sorted(expected_paths - actual_paths)
        extra = sorted(actual_paths - expected_paths)
        _fail("model.inventory", f"exact inventory set mismatch; missing={missing}, extra={extra}")

    identities_checked = 0
    for path, _, identity in file_refs:
        if identity is None:
            _fail("model.inventory", "identity metadata missing")
        actual_identity = _stat_identity(path, "model.inventory.identity")
        if actual_identity != identity:
            _fail("model.inventory", f"identity mismatch for {path}")
        identities_checked += 1
    return len(file_refs), sum(size for _, size, _ in file_refs), identities_checked


def _validate_file_map(value: Any, field: str, keys: set[str]) -> None:
    value = _object(value, field, keys, keys)
    for key in sorted(keys):
        _file_ref(value[key], f"{field}.{key}", verify_bytes=True)


def _validate_schemas(value: Any) -> None:
    value = _object(value, "schemas", {"manifest", "request", "output"}, {"manifest", "request", "output"})
    expected = {
        "manifest": (
            SCHEMA_ID,
            HERE / "dsv4-head-cache-qualification-v1.schema.json",
        ),
        "request": (
            "dsv4-head-cache-request/1",
            FIXTURE_ROOT / "request-rails.json",
        ),
        "output": (
            "dsv4-head-cache-output/1",
            FIXTURE_ROOT / "output-rails.json",
        ),
    }
    for key, (version, expected_path_value) in expected.items():
        field = f"schemas.{key}"
        stamp = _object(
            value[key],
            field,
            {"version", "path", "sha256", "size"},
            {"version", "path", "sha256", "size"},
        )
        if _string(stamp["version"], f"{field}.version", max_length=256) != version:
            _fail(f"{field}.version", f"must equal {version}")
        expected_path = canonical_path(
            str(expected_path_value),
            f"{field}.expected_path",
            must_exist=True,
            directory=False,
        )
        actual_path, _, _ = _file_ref(
            {name: stamp[name] for name in ("path", "sha256", "size")},
            field,
            verify_bytes=True,
        )
        if actual_path != expected_path:
            _fail(f"{field}.path", f"must bind the tracked contract file {expected_path}")


def _validate_generation(value: Any) -> None:
    value = _object(value, "generation", {"seed", "temperature", "top_p", "max_tokens", "processors", "eos", "stop"}, {"seed", "temperature", "top_p", "max_tokens", "processors", "eos", "stop"})
    if value["seed"] != 42 or value["temperature"] != 0 or value["top_p"] != 1 or value["max_tokens"] != 64:
        _fail("generation", "seed, temperature, top_p, and max_tokens must be exactly 42, 0, 1, and 64")
    for key in ("processors", "eos", "stop"):
        items = [_string(item, f"generation.{key}[{index}]") for index, item in enumerate(_array(value[key], f"generation.{key}", min_items=1))]
        if len(set(items)) != len(items):
            _fail(f"generation.{key}", "order list must not contain duplicates")


def _validate_runtime_settings(value: Any) -> None:
    value = _object(value, "runtime_settings", {"exact_bytes", "mtp", "proposals", "decode_compile"}, {"exact_bytes", "mtp", "proposals", "decode_compile"})
    _file_ref(value["exact_bytes"], "runtime_settings.exact_bytes", verify_bytes=True)
    for key in ("mtp", "proposals", "decode_compile"):
        if _bool(value[key], f"runtime_settings.{key}") is not False:
            _fail(f"runtime_settings.{key}", "must be false for this qualification")


def _validate_arm(value: Any, field: str, expected: Mapping[str, Any]) -> None:
    value = _object(value, field, {"id", "mode", "environment", "cache_requested", "source_supported", "prepared", "cache_identity", "logical_bytes", "shadow"}, {"id", "mode", "environment", "cache_requested", "source_supported", "prepared", "cache_identity", "logical_bytes", "shadow"})
    for key, wanted in expected.items():
        if value.get(key) != wanted:
            _fail(f"{field}.{key}", f"must equal {wanted!r}")
    arm_id = value["id"]
    _id(arm_id.lower(), f"{field}.id")
    if arm_id not in ARM_ENVIRONMENTS:
        _fail(f"{field}.id", "must name A, B, or P")
    arm_environment = _object(
        value["environment"],
        f"{field}.environment",
        set(ARM_ENVIRONMENTS[arm_id]),
        set(ARM_ENVIRONMENTS[arm_id]),
    )
    if arm_environment != ARM_ENVIRONMENTS[arm_id]:
        _fail(f"{field}.environment", "does not match the frozen arm environment")
    _bool(value["cache_requested"], f"{field}.cache_requested")
    _bool(value["source_supported"], f"{field}.source_supported")
    _bool(value["prepared"], f"{field}.prepared")
    if value["cache_identity"] is not None:
        identity = _string(value["cache_identity"], f"{field}.cache_identity", max_length=512)
        if not identity.strip():
            _fail(f"{field}.cache_identity", "must be nonempty")
    _int(value["logical_bytes"], f"{field}.logical_bytes")
    shadow = _object(value["shadow"], f"{field}.shadow", {"declared", "logical_bytes"}, {"declared", "logical_bytes"})
    _bool(shadow["declared"], f"{field}.shadow.declared")
    _int(shadow["logical_bytes"], f"{field}.shadow.logical_bytes")
    if shadow["declared"] is not True and shadow["logical_bytes"] != 0:
        _fail(f"{field}.shadow", "undeclared shadow must have zero logical bytes")


def _validate_arms(value: Any) -> None:
    value = _object(value, "arms", {"A", "B", "P"}, {"A", "B", "P"})
    shadow_off = {"declared": False, "logical_bytes": 0}
    _validate_arm(value["A"], "arms.A", {"id": "A", "mode": "exact", "cache_requested": False, "source_supported": True, "prepared": False, "cache_identity": None, "logical_bytes": 0, "shadow": shadow_off})
    _validate_arm(value["B"], "arms.B", {"id": "B", "mode": "exactCached", "cache_requested": True, "source_supported": True, "prepared": True, "logical_bytes": 2118123520, "shadow": shadow_off})
    if not isinstance(value["B"].get("cache_identity"), str) or not value["B"]["cache_identity"].strip():
        _fail("arms.B.cache_identity", "must be a nonempty cache identity")
    _validate_arm(value["P"], "arms.P", {"id": "P", "mode": "qmm", "cache_requested": False, "source_supported": True, "prepared": False, "cache_identity": None, "logical_bytes": 0, "shadow": shadow_off})


def validate_process_arm_environment(environment: Mapping[str, str]) -> str | None:
    """Return the exact process arm, or None for an ordinary process."""

    qualification_keys = {
        ARM_ENVIRONMENT_KEY,
        "VMLX_DSV4_LM_HEAD_MODE",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW",
    }
    if not any(key in environment for key in qualification_keys):
        return None
    arm = environment.get(ARM_ENVIRONMENT_KEY)
    if arm not in ARM_ENVIRONMENTS:
        _fail(ARM_ENVIRONMENT_KEY, "must be exactly A, B, or P")
    expected = ARM_ENVIRONMENTS[arm]
    for key, wanted in expected.items():
        if environment.get(key) != wanted:
            if key not in environment:
                _fail(key, f"is required for qualification arm {arm}")
            _fail(key, f"does not match qualification arm {arm}; expected {wanted!r}")
    return arm


def _validate_diagnostics(value: Any) -> None:
    value = _object(value, "diagnostics", {"shadow_control"}, {"shadow_control"})
    control = _object(
        value["shadow_control"],
        "diagnostics.shadow_control",
        {"timed", "environment", "snapshot"},
        {"timed", "environment", "snapshot"},
    )
    if control["timed"] is not False:
        _fail("diagnostics.shadow_control.timed", "must be false")
    environment = _object(
        control["environment"],
        "diagnostics.shadow_control.environment",
        {
            "VMLX_DSV4_CACHE_FP32_LM_HEAD",
            "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW",
            "VMLX_DSV4_LM_HEAD_MODE",
        },
        {
            "VMLX_DSV4_CACHE_FP32_LM_HEAD",
            "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW",
            "VMLX_DSV4_LM_HEAD_MODE",
        },
    )
    expected_environment = {
        "VMLX_DSV4_CACHE_FP32_LM_HEAD": "1",
        "VMLX_DSV4_CACHE_FP32_LM_HEAD_SHADOW": "1",
        "VMLX_DSV4_LM_HEAD_MODE": "exact",
    }
    if environment != expected_environment:
        _fail("diagnostics.shadow_control.environment", "does not match the frozen diagnostic-only control")
    snapshot = _object(
        control["snapshot"],
        "diagnostics.shadow_control.snapshot",
        {"cache_requested", "shadow_requested", "source_quantized", "source_supported", "prepared", "logical_bytes", "effective_path"},
        {"cache_requested", "shadow_requested", "source_quantized", "source_supported", "prepared", "logical_bytes", "effective_path"},
    )
    expected_snapshot = {
        "cache_requested": True,
        "shadow_requested": True,
        "source_quantized": True,
        "source_supported": True,
        "prepared": True,
        "logical_bytes": 2118123520,
        "effective_path": "exact",
    }
    if snapshot != expected_snapshot:
        _fail("diagnostics.shadow_control.snapshot", "does not match the frozen diagnostic snapshot")


def _validate_effective_path(value: Any) -> None:
    value = _object(value, "effective_path_proof", {"source_gate", "adapter_gate", "runtime_artifact", "arm_order", "effective_arm"}, {"source_gate", "adapter_gate", "runtime_artifact", "arm_order", "effective_arm"})
    _source_binding(value["source_gate"], "effective_path_proof.source_gate", expected_suffix="Packages/OsaurusCore/Services/ModelRuntime.swift")
    _source_binding(value["adapter_gate"], "effective_path_proof.adapter_gate", expected_suffix="Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift")
    _file_ref(value["runtime_artifact"], "effective_path_proof.runtime_artifact", verify_bytes=True)
    order = _array(value["arm_order"], "effective_path_proof.arm_order", min_items=3, max_items=3)
    if order != ["A", "B", "P"]:
        _fail("effective_path_proof.arm_order", "must be exactly [A, B, P]")
    if value["effective_arm"] not in {"A", "B", "P"}:
        _fail("effective_path_proof.effective_arm", "must name one of A, B, or P")


def _validate_requests(value: Any, fixture_ids: set[str]) -> None:
    requests = _array(value, "requests", min_items=len(REQUIRED_REQUEST_KINDS))
    ids: set[str] = set()
    kinds: set[str] = set()
    for index, item in enumerate(requests):
        field = f"requests[{index}]"
        item = _object(item, field, {"id", "kind", "fixture_id", "arm", "expected_rail", "max_tokens", "trace_accepted_ids"}, {"id", "kind", "fixture_id", "arm", "expected_rail", "max_tokens", "trace_accepted_ids"})
        request_id = _id(item["id"], f"{field}.id")
        if request_id in ids:
            _fail("requests", f"duplicate id {request_id}")
        ids.add(request_id)
        kind = _string(item["kind"], f"{field}.kind")
        if kind not in REQUIRED_REQUEST_KINDS:
            _fail(f"{field}.kind", "unsupported Gate D request kind")
        kinds.add(kind)
        fixture_id = _string(item["fixture_id"], f"{field}.fixture_id")
        if fixture_id not in fixture_ids:
            _fail(f"{field}.fixture_id", f"unknown fixture {fixture_id}")
        if item["arm"] not in {"A", "B", "P"}:
            _fail(f"{field}.arm", "must be A, B, or P")
        _string(item["expected_rail"], f"{field}.expected_rail", max_length=256)
        if item["max_tokens"] != 64:
            _fail(f"{field}.max_tokens", "must be exactly 64")
        trace_accepted_ids = _bool(item["trace_accepted_ids"], f"{field}.trace_accepted_ids")
        if trace_accepted_ids != (kind != "normal_unload"):
            _fail(
                f"{field}.trace_accepted_ids",
                "must be false only for the pure normal_unload step and true for generation rows",
            )
    missing = sorted(REQUIRED_REQUEST_KINDS - kinds)
    if missing:
        _fail("requests", "missing Gate D request kind(s): " + ", ".join(missing))


def _validate_prefixes(value: Any) -> None:
    value = _object(value, "prefixes", {"miss", "hit"}, {"miss", "hit"})
    ids: set[str] = set()
    for key, expected in (("miss", "miss"), ("hit", "hit")):
        field = f"prefixes.{key}"
        item = _object(value[key], field, {"id", "request_id", "expected", "cache_identity"}, {"id", "request_id", "expected", "cache_identity"})
        identifier = _id(item["id"], f"{field}.id")
        if identifier in ids:
            _fail("prefixes", f"duplicate id {identifier}")
        ids.add(identifier)
        _string(item["request_id"], f"{field}.request_id")
        if item["expected"] != expected:
            _fail(f"{field}.expected", f"must be {expected!r}")
        if key == "miss" and item["cache_identity"] is not None:
            _fail(f"{field}.cache_identity", "miss arm must not carry a cache identity")
        if key == "hit":
            identity = _string(item["cache_identity"], f"{field}.cache_identity", max_length=512)
            if not identity.strip():
                _fail(f"{field}.cache_identity", "hit must carry a nonempty cache identity")


def _validate_fixtures(value: Any) -> set[str]:
    fixtures = _array(value, "fixtures", min_items=3)
    ids: set[str] = set()
    fixture_root = canonical_path(
        str(FIXTURE_ROOT),
        "fixtures.root",
        must_exist=True,
        directory=True,
    )
    for index, item in enumerate(fixtures):
        field = f"fixtures[{index}]"
        item = _object(item, field, {"id", "path", "sha256", "size"}, {"id", "path", "sha256", "size"})
        identifier = _id(item["id"], f"{field}.id")
        if identifier in ids:
            _fail("fixtures", f"duplicate id {identifier}")
        ids.add(identifier)
        path = canonical_path(item["path"], f"{field}.path", must_exist=True, directory=False)
        _contained(path, fixture_root, f"{field}.path")
        _file_ref(
            {key: item[key] for key in ("path", "sha256", "size")},
            field,
            verify_bytes=True,
            fixture_root=fixture_root,
        )
    return ids


def _validate_output(value: Any) -> str:
    value = _object(value, "output", {"campaign_root", "ledger", "stem", "state", "cache", "tmp"}, {"campaign_root", "ledger", "stem", "state", "cache", "tmp"})
    root = canonical_path(value["campaign_root"], "output.campaign_root", must_exist=False)
    paths = {"campaign_root": root}
    for key in ("ledger", "stem", "state", "cache", "tmp"):
        paths[key] = canonical_path(value[key], f"output.{key}", must_exist=False)
        _contained(paths[key], root, f"output.{key}")
    if len(set(paths.values())) != len(paths):
        _fail("output", "campaign root and rails must be distinct paths")
    return root


def _validate_safety(value: Any) -> None:
    value = _object(value, "safety", {"fail_closed", "allow_destructive_actions", "require_manifest_hash_env", "manifest_external", "live_claims"}, {"fail_closed", "allow_destructive_actions", "require_manifest_hash_env", "manifest_external", "live_claims"})
    if _bool(value["fail_closed"], "safety.fail_closed") is not True:
        _fail("safety.fail_closed", "must be true")
    if _bool(value["allow_destructive_actions"], "safety.allow_destructive_actions") is not False:
        _fail("safety.allow_destructive_actions", "must be false")
    if _bool(value["require_manifest_hash_env"], "safety.require_manifest_hash_env") is not True:
        _fail("safety.require_manifest_hash_env", "must be true")
    if _bool(value["manifest_external"], "safety.manifest_external") is not True:
        _fail("safety.manifest_external", "must be true")
    if value["live_claims"] not in {"none", "measured"}:
        _fail("safety.live_claims", "must be none or measured")


def _validate_decision(value: Any) -> None:
    value = _object(value, "decision", {"status", "qualified", "live_gates_ran", "reason"}, {"status", "qualified", "live_gates_ran", "reason"})
    status = value["status"]
    if status not in {"unproven", "qualified", "rejected"}:
        _fail("decision.status", "unsupported decision status")
    qualified = _bool(value["qualified"], "decision.qualified")
    live_gates_ran = _bool(value["live_gates_ran"], "decision.live_gates_ran")
    _string(value["reason"], "decision.reason", max_length=2048)
    if qualified != (status == "qualified"):
        _fail("decision", "qualified must match status == qualified")
    if qualified and not live_gates_ran:
        _fail("decision", "qualified manifests must state that live gates ran")


def _reject_constants(value: str) -> Any:
    _fail("json", f"non-standard JSON constant {value} is forbidden")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("json", f"duplicate object key {key!r}")
        result[key] = value
    return result


def _decode_manifest(data: bytes) -> dict[str, Any]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail("json", f"manifest must be UTF-8: {exc}")
    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constants,
        )
    except QualificationError:
        raise
    except json.JSONDecodeError as exc:
        _fail("json", f"invalid JSON: {exc}")
    if not isinstance(value, dict):
        _fail("json", "top level must be an object")
    return value


def _validate_manifest(value: dict[str, Any], *, phase: str) -> tuple[str, str, int, int, int]:
    allowed = {
        "schema", "campaign_id", "sources", "dependency_pins", "artifacts", "model", "schemas",
        "generation", "runtime_settings", "arms", "diagnostics", "effective_path_proof", "requests", "prefixes",
        "fixtures", "output", "safety", "decision", "notes",
    }
    required = allowed - {"notes"}
    value = _object(value, "manifest", allowed, required)
    if value["schema"] != SCHEMA_ID:
        _fail("schema", f"must equal {SCHEMA_ID}")
    campaign_id = _id(value["campaign_id"], "campaign_id")

    _validate_sources(value["sources"])
    _validate_dependency_pins(value["dependency_pins"])
    _validate_file_map(value["artifacts"], "artifacts", {"app_executable", "cli", "default_metallib"})

    verify_model_bytes = phase == "pre_campaign"
    model_entries, _, identities = _validate_model(value["model"], verify_bytes=verify_model_bytes)
    _validate_schemas(value["schemas"])
    _validate_generation(value["generation"])
    _validate_runtime_settings(value["runtime_settings"])
    _validate_arms(value["arms"])
    _validate_diagnostics(value["diagnostics"])
    _validate_effective_path(value["effective_path_proof"])
    fixture_ids = _validate_fixtures(value["fixtures"])
    _validate_requests(value["requests"], fixture_ids)
    _validate_prefixes(value["prefixes"])
    campaign_root = _validate_output(value["output"])
    _validate_safety(value["safety"])
    _validate_decision(value["decision"])
    if "notes" in value:
        _string(value["notes"], "notes", max_length=4096)
    return campaign_id, campaign_root, model_entries, identities, int(verify_model_bytes)


def verify_manifest_bytes(data: bytes, *, expected_sha256: str | None, phase: str) -> VerificationReport:
    """Hash exact bytes first, then decode and validate the manifest."""

    if len(data) > MAX_MANIFEST_BYTES:
        _fail("manifest", f"manifest exceeds bounded maximum of {MAX_MANIFEST_BYTES} bytes")
    actual_hash = hashlib.sha256(data).hexdigest()
    if expected_sha256 is not None:
        expected_sha256 = _digest(expected_sha256, "expected_manifest_sha256")
        if actual_hash != expected_sha256:
            _fail("expected_manifest_sha256", f"manifest hash mismatch: actual={actual_hash}")
    if phase not in {"pre_campaign", "process"}:
        _fail("phase", "must be pre_campaign or process")
    value = _decode_manifest(data)
    campaign_id, campaign_root, entries, identities, hashed = _validate_manifest(value, phase=phase)
    return VerificationReport(
        manifest_sha256=actual_hash,
        phase=phase,
        campaign_id=campaign_id,
        campaign_root=campaign_root,
        model_entries=entries,
        model_bytes_hashed=bool(hashed),
        model_bytes_hashed_count=entries if hashed else 0,
        identity_checks=identities,
    )


def _read_manifest_file(path: str | os.PathLike[str]) -> tuple[str, bytes]:
    manifest_path = canonical_path(os.fspath(path), "manifest_path", must_exist=True, directory=False)
    try:
        data = pathlib.Path(manifest_path).read_bytes()
    except OSError as exc:
        _fail("manifest_path", f"cannot read manifest: {exc}")
    return manifest_path, data


def _verify_sealed_manifest(
    manifest_path: str,
    data: bytes,
    *,
    expected_sha256: str | None,
    phase: str,
) -> VerificationReport:
    report = verify_manifest_bytes(data, expected_sha256=expected_sha256, phase=phase)
    if manifest_path == report.campaign_root or manifest_path.startswith(report.campaign_root + os.sep):
        _fail(
            "output.campaign_root",
            "sealed manifest must be outside the mutable campaign output",
        )
    return report


def verify_manifest_file(path: str | os.PathLike[str], *, expected_sha256: str | None, phase: str) -> VerificationReport:
    manifest_path, data = _read_manifest_file(path)
    return _verify_sealed_manifest(
        manifest_path,
        data,
        expected_sha256=expected_sha256,
        phase=phase,
    )


def verify_pre_model_work(
    manifest_path: str | os.PathLike[str],
    expected_sha256: str,
    *,
    model_id: str,
    request_id: str | None,
    environment: Mapping[str, str],
) -> VerificationReport:
    """Validate every binding needed immediately before model work."""

    arm = validate_process_arm_environment(environment)
    if arm is None:
        _fail(ARM_ENVIRONMENT_KEY, "is required for qualified model work")
    if not environment.get("OSAURUS_DSV4_QUALIFICATION_MANIFEST"):
        _fail("OSAURUS_DSV4_QUALIFICATION_MANIFEST", "is required")
    if not environment.get("OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256"):
        _fail("OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256", "is required")
    if not request_id:
        _fail("qualification.request_id", "is required before qualified model work")

    sealed_path, sealed_bytes = _read_manifest_file(manifest_path)
    report = _verify_sealed_manifest(
        sealed_path,
        sealed_bytes,
        expected_sha256=expected_sha256,
        phase="process",
    )
    manifest = _decode_manifest(sealed_bytes)
    if manifest["model"]["id"] != model_id:
        _fail("model.id", "does not match the requested model ID")
    rows = [row for row in manifest["requests"] if row["id"] == request_id]
    if len(rows) != 1:
        _fail("qualification.request_id", "does not name exactly one manifest request")
    if rows[0]["arm"] != arm:
        _fail("requests.arm", f"does not match process arm {arm}")
    return report


def reserve_output(manifest_path: str, expected_sha256: str) -> VerificationReport:
    """Create the campaign rails only after a complete pre-campaign verify."""

    sealed_path, sealed_bytes = _read_manifest_file(manifest_path)
    report = verify_manifest_bytes(
        sealed_bytes,
        expected_sha256=expected_sha256,
        phase="pre_campaign",
    )
    if sealed_path == report.campaign_root or sealed_path.startswith(report.campaign_root + os.sep):
        _fail("output.campaign_root", "sealed manifest must be outside the mutable campaign output")
    # Extract rails from the same exact bytes that passed the hash and all
    # normative checks. Never reread a mutable path between verify and create.
    manifest = _decode_manifest(sealed_bytes)
    output = manifest["output"]
    root = pathlib.Path(report.campaign_root)
    if root.exists():
        _fail("output.campaign_root", "campaign root already exists; refusing to reuse it")
    try:
        root.mkdir(parents=False)
        for key in ("state", "cache", "tmp"):
            pathlib.Path(output[key]).mkdir(parents=False)
        pathlib.Path(output["ledger"]).open("x").close()
        pathlib.Path(output["stem"]).open("x").close()
    except FileExistsError as exc:
        _fail("output", f"output reservation collided: {exc}")
    except OSError as exc:
        _fail("output", f"output reservation failed: {exc}")
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--expected-sha256", default=os.environ.get("OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256"))
    parser.add_argument("--phase", choices=("pre_campaign", "process"), default="pre_campaign")
    parser.add_argument("--reserve-output", action="store_true")
    parser.add_argument("--json", action="store_true", dest="as_json")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(list(argv) if argv is not None else None)
    try:
        if args.reserve_output:
            if not args.expected_sha256:
                _fail("expected_manifest_sha256", "required when reserving output")
            report = reserve_output(str(args.manifest), args.expected_sha256)
        else:
            report = verify_manifest_file(str(args.manifest), expected_sha256=args.expected_sha256, phase=args.phase)
    except QualificationError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 2
    payload = report.as_dict()
    if args.as_json:
        print(json.dumps(payload, sort_keys=True))
    else:
        print(
            "PASS "
            + f"phase={report.phase} campaign_id={report.campaign_id} "
            + f"manifest_sha256={report.manifest_sha256} "
            + f"model_entries={report.model_entries} "
            + f"model_bytes_hashed={str(report.model_bytes_hashed).lower()} "
            + f"identity_checks={report.identity_checks}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
