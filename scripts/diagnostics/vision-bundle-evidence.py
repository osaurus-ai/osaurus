#!/usr/bin/env python3
"""Read bundle config and actual safetensors headers without loading tensor payloads.

Diagnostic inventory, not a capability decision or model correctness test. A tensor
name alone does not establish a complete, compatible encoder/projector.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def inspect(directory):
    root = Path(directory).resolve(strict=True)
    result = {"directory": str(root), "metadata": {}, "shards": [], "errors": []}
    for name in ("config.json", "preprocessor_config.json", "processor_config.json",
                 "video_preprocessor_config.json", "config_omni.json", "jang_config.json"):
        path = root / name
        if not path.exists():
            continue
        raw = path.read_bytes()
        try:
            value = json.loads(raw)
        except (ValueError, UnicodeError) as error:
            result["errors"].append(f"{name}: {error}")
            continue
        result["metadata"][name] = {"sha256": hashlib.sha256(raw).hexdigest(), "value": value}

    actual = {}
    # Top-level payloads match the normal local MLX bundle layout. Companion
    # subdirectories are deliberately not pooled into a model's tensor evidence.
    for path in sorted(root.glob("*.safetensors")):
        size = path.stat().st_size
        try:
            with path.open("rb") as handle:
                prefix = handle.read(8)
                if len(prefix) != 8:
                    raise ValueError("truncated length prefix")
                length = struct.unpack("<Q", prefix)[0]
                if not 0 < length <= min(64 * 1024 * 1024, size - 8):
                    raise ValueError("invalid or oversized header")
                raw = handle.read(length)
                header = json.loads(raw)
            payload_size = size - 8 - length
            tensors = {k: v for k, v in header.items() if k != "__metadata__"}
            for key, value in tensors.items():
                start, end = value["data_offsets"]
                if not 0 <= start <= end <= payload_size:
                    raise ValueError(f"out-of-file tensor offsets: {key}")
                actual.setdefault(key, []).append(path.name)
            vision = {k: v for k, v in tensors.items() if any(
                part in k.split(".") for part in ("visual", "vision_tower", "vision_model"))}
            result["shards"].append({
                "file": path.name, "bytes": size,
                "header_sha256": hashlib.sha256(raw).hexdigest(),
                "tensor_count": len(tensors), "vision_tensors": vision,
            })
        except (OSError, ValueError, KeyError, TypeError) as error:
            result["errors"].append(f"{path.name}: {error}")

    index = root / "model.safetensors.index.json"
    if index.exists():
        raw = index.read_bytes()
        try:
            weight_map = json.loads(raw)["weight_map"]
            result["index"] = {
                "sha256": hashlib.sha256(raw).hexdigest(),
                "entries": len(weight_map),
                "unbacked_entries": {k: v for k, v in weight_map.items()
                                     if v not in actual.get(k, [])},
                "header_keys_not_in_index": sorted(set(actual) - set(weight_map)),
            }
        except (ValueError, KeyError, TypeError) as error:
            result["errors"].append(f"index: {error}")
    result["actual_tensor_count"] = len(actual)
    result["actual_vision_tensor_count"] = sum(len(s["vision_tensors"]) for s in result["shards"])
    result["scope"] = "Config and bounded header reads only; no payload hashes or inference"
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundles", nargs="+")
    args = parser.parse_args()
    print(json.dumps([inspect(p) for p in args.bundles], indent=2, sort_keys=True))
