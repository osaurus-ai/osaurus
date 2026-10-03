#!/usr/bin/env python3
"""Exercise installed vision admission through an existing osaurus-evals binary.

Fixtures contain real, tiny safetensors files, but are not runnable models.
This probes header/config admission only; it never requests inference. Existing
installed models may appear in discovery and are excluded from fixture scoring.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time


CASES = {
    "control": True,
    "unknown-processor": False,
    "missing-processor": False,
    "invalid-dtype": False,
    "wrong-byte-count": False,
    "missing-projection": False,
    "missing-block": False,
    "unregistered-architecture": False,
}


def write_fixture(directory: Path, case: str) -> None:
    directory.mkdir(parents=True)
    config = {
        "model_type": "qwen3_5",
        "vision_config": {"depth": 2, "hidden_size": 1152},
        "quantization": {"bits": 4, "group_size": 64},
    }
    processor = {"processor_class": "Qwen3VLProcessor"}
    if case == "unknown-processor":
        processor["processor_class"] = "NotAnInstalledProcessor"
    elif case == "missing-processor":
        processor = {}
    elif case == "unregistered-architecture":
        config["model_type"] = "not_an_installed_architecture"
    names = [
        "visual.patch_embed.proj.weight",
        "visual.blocks.0.attn.qkv.weight",
        "visual.blocks.1.attn.qkv.weight",
        "visual.merger.linear_fc2.weight",
    ]
    if case == "missing-projection":
        names = [name for name in names if ".merger." not in name]
    elif case == "missing-block":
        names = [name for name in names if ".blocks.1." not in name]
    header = {
        name: {
            "shape": [1048576] if case == "wrong-byte-count" else [1],
            "dtype": "NOT_A_DTYPE" if case == "invalid-dtype" else "F32",
            "data_offsets": [index * 4, (index + 1) * 4],
        }
        for index, name in enumerate(names)
    }
    encoded = json.dumps(header, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 8)
    (directory / "model.safetensors").write_bytes(
        struct.pack("<Q", len(encoded)) + encoded + bytes(4 * len(names))
    )
    for filename, value in [
        ("config.json", config),
        ("processor_config.json", processor),
        ("tokenizer.json", {}),
    ]:
        (directory / filename).write_text(json.dumps(value))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evals", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    binary = args.evals.resolve(strict=True)
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)
    models = output / "models"
    for case in CASES:
        write_fixture(models / "EvidenceFixture" / case, case)
    env = dict(os.environ)
    env.update(
        OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS="1",
        OSAURUS_TEST_ROOT=str(output / "profile"),
        OSU_MODELS_DIR=str(models),
    )
    command = [str(binary), "vision-inventory", "--out", str(output / "inventory.json")]
    started = time.monotonic()
    with (output / "inventory.log").open("w") as log:
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    inventory = json.loads((output / "inventory.json").read_text()) if result.returncode == 0 else []
    by_directory = {row["directory"]: row for row in inventory}
    rows = []
    for case, expected in CASES.items():
        actual = by_directory.get(str(models / "EvidenceFixture" / case))
        rows.append({
            "case": case,
            "expected_supports_image": expected,
            "actual": actual,
            "passed": actual is not None and actual.get("supportsImage") is expected,
        })
    receipt = {
        "command": command,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "inventory_exit": result.returncode,
        "elapsed_seconds": time.monotonic() - started,
        "passed": sum(row["passed"] for row in rows),
        "total": len(rows),
        "rows": rows,
        "scope": "Header/config admission only. Synthetic fixtures are not inference or UI proof.",
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"passed": receipt["passed"], "total": len(rows), "receipt": str(output / "receipt.json")}))
    return 0 if result.returncode == 0 and all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
