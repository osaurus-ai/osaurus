#!/usr/bin/env python3
"""Plan coverage from installed evidence and actual bundle metadata, never names.

Representative runs exercise a group; unexecuted artifacts remain unqualified.
All members, rejections and pending runtime rows remain in the output.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import struct


def object_at(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def quantization_descriptors(value):
    """Collapse per-layer declarations by contract, without layer/model names."""
    if not isinstance(value, dict):
        return []
    fields = ("bits", "group_size", "mode", "quant_method", "format", "weight_format",
              "mxtq_bits", "routed_expert_bits", "expert_dtype", "scale_fmt")
    descriptors = []
    own = {key: value[key] for key in fields if key in value}
    if own:
        descriptors.append(json.dumps(own, sort_keys=True))
    for nested in value.values():
        if isinstance(nested, dict):
            descriptors.extend(quantization_descriptors(nested))
    return sorted(set(descriptors))


def metadata(row):
    root = pathlib.Path(row["directory"])
    config = object_at(root / "config.json")
    omni = object_at(root / "config_omni.json")
    vision = omni.get("vision_config", config.get("vision_config", {}))
    processor_path = next((root / name for name in (
        "preprocessor_config.json", "processor_config.json",
        "audio_preprocessor/preprocessor_config.json") if (root / name).exists()), None)
    processor = object_at(processor_path) if processor_path else {}
    quant = quantization_descriptors(config.get("quantization", {}))
    quant += quantization_descriptors(config.get("quantization_config", {}))
    jang = object_at(root / "jang_config.json")
    quant += quantization_descriptors({
        key: jang[key] for key in ("quantization", "format", "weight_format", "mxtq_bits") if key in jang
    })
    index = object_at(root / "model.safetensors.index.json").get("weight_map", {})
    dtypes, headers, failures = set(), [], []
    if index and (not isinstance(index, dict) or any(
        not isinstance(name, str) or pathlib.Path(name).name != name or not name.endswith(".safetensors")
        for name in index.values()
    )):
        files = []
        failures.append({"file": str(root / "model.safetensors.index.json"), "error": "invalid shard paths"})
    else:
        files = sorted({root / name for name in index.values()}) if index else sorted(root.glob("*.safetensors"))
    weight_bytes = 0
    for path in files:
        try:
            # The production detector owns admission. This audit records actual
            # storage dtype/header hashes independently from declared quantization.
            size = path.stat().st_size
            weight_bytes += size
            with path.open("rb") as handle:
                prefix = handle.read(8)
                if len(prefix) != 8:
                    raise ValueError("truncated header length")
                length = struct.unpack("<Q", prefix)[0]
                if not 0 < length <= min(64 * 1024 * 1024, size - 8):
                    raise ValueError("invalid header length")
                data = handle.read(length)
            header = json.loads(data)
            if not isinstance(header, dict):
                raise ValueError("header is not an object")
            for key, tensor in header.items():
                if key == "__metadata__":
                    continue
                if not isinstance(tensor, dict) or not isinstance(tensor.get("dtype"), str):
                    raise ValueError("invalid tensor dtype metadata")
                dtypes.add(tensor["dtype"])
            headers.append({"file": path.name, "bytes": size,
                            "header_sha256": hashlib.sha256(data).hexdigest()})
        except (OSError, ValueError, TypeError) as error:
            failures.append({"file": str(path), "error": str(error)})
    contract = {
        "architecture": row["modelType"],
        "vision_architecture": vision.get("model_type") if isinstance(vision, dict) else None,
        "declared_processor_class": processor.get("processor_class"),
        "declared_image_processor_type": processor.get("image_processor_type"),
        "declared_quantization": sorted(set(quant)),
        "actual_tensor_dtypes": sorted(dtypes),
    }
    return {"contract": contract, "weight_bytes": weight_bytes, "headers": headers,
            "processor_file": str(processor_path) if processor_path else None,
            "header_errors": failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--representatives", action="store_true")
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    rows, groups = [], {}
    for installed in inventory:
        row = dict(installed)
        row["runtime_status"] = "not_run"
        row["runtime_selected"] = False
        # Audit every installed bundle, including architectures or config shapes
        # the current capability detector rejects. Rejections must stay visible.
        row.update(metadata(installed))
        key = hashlib.sha256(json.dumps(row["contract"], sort_keys=True).encode()).hexdigest()[:16]
        row["coverage_group"] = key
        if installed["supportsImage"] and not row["header_errors"]:
            groups.setdefault(key, []).append(row)
            row["selection_reason"] = "pending runtime qualification"
        else:
            row["selection_reason"] = "installed evidence did not admit image input; " + installed["reason"]
        rows.append(row)
    for members in groups.values():
        ordered = sorted(members, key=lambda row: (row["weight_bytes"], row["directory"]))
        selected = ordered[:1] if args.representatives else ordered
        for row in selected:
            row["runtime_selected"] = True
            row["selection_reason"] = ("smallest installed weight set in this config/processor/format group"
                                       if args.representatives else "all admitted image bundles selected")
        for row in ordered[len(selected):]:
            row["selection_reason"] = "unexecuted group member; representative results do not qualify this artifact"
    output = {"mode": "representatives" if args.representatives else "all",
              "inventory_count": len(rows), "coverage_group_count": len(groups),
              "selected_count": sum(row["runtime_selected"] for row in rows), "bundles": rows}
    args.out.write_text(json.dumps(output, indent=2) + "\n")
    print(f"{len(rows)} inventoried; {len(groups)} coverage groups; {output['selected_count']} runtime selections")
    # Cover architecture breadth first, then additional formats. Sorting only
    # by model ID can spend the entire first run on one publisher/family.
    by_architecture = collections.defaultdict(list)
    for row in rows:
        if row["runtime_selected"]:
            by_architecture[row["contract"]["architecture"]].append(row)
    queues = [collections.deque(sorted(members, key=lambda row: row["weight_bytes"]))
              for _, members in sorted(by_architecture.items())]
    selected = []
    while any(queues):
        selected.extend(queue.popleft() for queue in queues if queue)
    for row in selected:
        if any(character in row["modelID"] for character in "\r\n\t"):
            raise SystemExit("Model identifier contains a control delimiter")
    args.out.with_suffix(".tsv").write_text("".join(
        f"{index:03d}\t{row['modelID']}\n" for index, row in enumerate(selected)))
    if not selected:
        raise SystemExit("No runtime candidates; empty coverage is not a pass")


if __name__ == "__main__":
    main()
