#!/usr/bin/env python3
"""Collect PR 1147 bundle census artifacts without loading model weights.

This helper is intentionally conservative. It reports what is present in the
bundle files and safetensors index; it does not infer MTP, VLM, parser, or cache
support from a model name.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_MODEL_RELATIVE_PATHS = [
    "JANGQ/DeepSeek-V4-Flash-JANGTQ-K",
    "JANGQ/DeepSeek-V4-Flash-JANGTQ2",
    "JANGQ/Qwen3.6-27B-JANG_4M-MTP",
    "JANGQ/Qwen3.6-27B-MXFP4-MTP",
    "JANGQ/Qwen3.6-27B-MXFP8-MTP",
    "JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP",
    "JANGQ/Qwen3.6-35B-A3B-MXFP8-MTP",
    "JANGQ/Qwen3.6-35B-A3B-JANG_2K-MTP",
    "dealign.ai/Qwen3.6-27B-JANG_4M-CRACK",
    "dealign.ai/Qwen3.6-27B-MXFP4-CRACK",
    "dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK",
    "dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK",
    "mlx-community/gemma-3n-E2B-it-4bit",
    "JANGQ/ZAYA1-8B-JANGTQ4",
    "JANGQ/ZAYA1-8B-JANGTQ_K",
    "JANGQ/ZAYA1-VL-8B-JANGTQ4",
    "JANGQ/ZAYA1-VL-8B-JANGTQ_K",
    "Osaurus/ZAYA1-8B-MXFP4",
    "Osaurus/ZAYA1-VL-8B-MXFP4",
    "dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK",
    "dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK",
    "dealign.ai/Nemotron-Omni-Nano-MXFP4-CRACK",
    "dealign.ai/MiniMax-M2.7-JANGTQ_K-CRACK",
    "dealign.ai/MiniMax-M2.7-JANG_K-CRACK",
    "JANGQ/MiniMax-M2.7-Small-JANGTQ",
    "dealign.ai/Ling-2.6-flash-JANGTQ2-CRACK",
    "dealign.ai/Ling-2.6-flash-MXFP4-CRACK",
    "JANGQ/Hy3-preview-JANGTQ",
    "JANGQ/Hy3-preview-JANGTQ_K",
]

KEY_FILES = [
    "config.json",
    "generation_config.json",
    "tokenizer_config.json",
    "chat_template.jinja",
    "jang_config.json",
    "vmlx_mtp_tuning.json",
    "preprocessor_config.json",
    "video_preprocessor_config.json",
    "model.safetensors.index.json",
]


@dataclass(frozen=True)
class BundleTarget:
    label: str
    path: Path


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return {"_json_error": str(exc)}


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip("/"))
    return slug.strip("_") or "bundle"


def nested_get(data: dict[str, Any], *keys: str) -> Any:
    cursor: Any = data
    for key in keys:
        if not isinstance(cursor, dict) or key not in cursor:
            return None
        cursor = cursor[key]
    return cursor


def compact_generation(generation: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "temperature",
        "top_p",
        "top_k",
        "min_p",
        "repetition_penalty",
        "max_new_tokens",
        "max_length",
        "eos_token_id",
        "pad_token_id",
    ]
    return {key: generation[key] for key in keys if key in generation}


def compact_config(config: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "model_type",
        "architectures",
        "use_cache",
        "sliding_window",
        "max_position_embeddings",
        "mtp_num_hidden_layers",
        "mtp_use_dedicated_embeddings",
        "video_token_id",
        "image_token_id",
        "audio_token_id",
        "vision_start_token_id",
        "vision_end_token_id",
    ]
    summary = {key: config[key] for key in keys if key in config}
    for nested in ["text_config", "vision_config", "audio_config"]:
        if isinstance(config.get(nested), dict):
            summary[nested] = {
                key: config[nested][key]
                for key in ["model_type", "architectures", "use_cache", "sliding_window"]
                if key in config[nested]
            }
    return summary


def compact_jang(jang: dict[str, Any]) -> dict[str, Any]:
    if not jang:
        return {}
    runtime = jang.get("runtime") if isinstance(jang.get("runtime"), dict) else {}
    summary: dict[str, Any] = {}
    for source in [jang, runtime]:
        for key in [
            "format",
            "cache_subtype",
            "has_vision",
            "has_audio",
            "has_video",
            "drop_mtp",
            "bundle_has_mtp",
            "mtp_layers",
            "mtp_mode",
            "reasoning_parser",
            "tool_parser",
            "supports_tools",
            "modality",
            "cache_type",
            "native_cache_schema",
            "chat_template_source",
        ]:
            if key in source and key not in summary:
                summary[key] = source[key]
    return summary


def inspect_safetensors_index(path: Path) -> dict[str, Any]:
    index_path = path / "model.safetensors.index.json"
    index = read_json(index_path)
    weight_map = index.get("weight_map") if isinstance(index.get("weight_map"), dict) else {}
    keys = list(weight_map.keys())
    mtp_keys = [
        key
        for key in keys
        if key.startswith("mtp.") or ".mtp." in key or key.startswith("model.mtp")
    ]
    vision_keys = [
        key
        for key in keys
        if key.startswith("vision_tower.")
        or key.startswith("visual.")
        or ".vision_tower." in key
        or ".vision_model." in key
    ]
    audio_keys = [key for key in keys if key.startswith("audio.") or ".audio." in key]
    return {
        "present": index_path.exists(),
        "tensor_count": len(keys),
        "total_size": nested_get(index, "metadata", "total_size"),
        "mtp_tensor_count": len(mtp_keys),
        "mtp_tensor_examples": mtp_keys[:8],
        "vision_tensor_count": len(vision_keys),
        "vision_tensor_examples": vision_keys[:8],
        "audio_tensor_count": len(audio_keys),
        "audio_tensor_examples": audio_keys[:8],
    }


def inspect_mtp(
    path: Path,
    config: dict[str, Any],
    jang: dict[str, Any],
    tuning: dict[str, Any],
    safetensors: dict[str, Any],
) -> dict[str, Any]:
    native_tuning = tuning.get("native_mtp") if isinstance(tuning.get("native_mtp"), dict) else {}
    has_tensor_evidence = safetensors.get("mtp_tensor_count", 0) > 0
    config_layers = config.get("mtp_num_hidden_layers")
    jang_bundle_has_mtp = bool(jang.get("bundle_has_mtp")) or bool(
        nested_get(jang, "runtime", "bundle_has_mtp")
    )
    tuning_validated = bool(native_tuning.get("validated"))
    tuning_blocked = bool(native_tuning.get("blocked"))
    best_depth = native_tuning.get("best_depth")
    auto_enable = bool(has_tensor_evidence and tuning_validated and not tuning_blocked)

    if auto_enable:
        reason = "real mtp tensors plus validated vmlx_mtp_tuning.json"
    elif tuning_blocked:
        reason = "vmlx_mtp_tuning.json blocks native MTP"
    elif has_tensor_evidence and not tuning_validated:
        reason = "mtp tensors exist but tuning is missing or not validated"
    elif config_layers or jang_bundle_has_mtp:
        reason = "config metadata mentions MTP, but no mtp tensor evidence was found"
    else:
        reason = "no native MTP evidence"

    return {
        "has_tensor_evidence": has_tensor_evidence,
        "config_mtp_num_hidden_layers": config_layers,
        "jang_bundle_has_mtp": jang_bundle_has_mtp,
        "tuning_present": (path / "vmlx_mtp_tuning.json").exists(),
        "tuning_validated": tuning_validated,
        "tuning_blocked": tuning_blocked,
        "best_depth": best_depth,
        "cache_mode": native_tuning.get("cache_mode"),
        "baseline_tok_s": native_tuning.get("baseline_tok_s"),
        "best_tok_s": native_tuning.get("best_tok_s"),
        "speedup_vs_baseline": native_tuning.get("speedup_vs_baseline"),
        "artifact": native_tuning.get("artifact"),
        "auto_enable": auto_enable,
        "reason": reason,
    }


def inspect_bundle(target: BundleTarget) -> dict[str, Any]:
    path = target.path
    files = {name: (path / name).exists() for name in KEY_FILES}
    config = read_json(path / "config.json")
    generation = read_json(path / "generation_config.json")
    jang = read_json(path / "jang_config.json")
    tuning = read_json(path / "vmlx_mtp_tuning.json")
    safetensors = inspect_safetensors_index(path)
    has_vision_config = isinstance(config.get("vision_config"), dict)
    has_audio_config = isinstance(config.get("audio_config"), dict)
    has_video_token = "video_token_id" in config
    has_image_token = "image_token_id" in config or "vision_start_token_id" in config
    return {
        "label": target.label,
        "path": str(path),
        "exists": path.exists(),
        "files": files,
        "config": compact_config(config),
        "generation_defaults": compact_generation(generation),
        "jang": compact_jang(jang),
        "safetensors_index": safetensors,
        "capability_evidence": {
            "vision_config": has_vision_config,
            "audio_config": has_audio_config,
            "image_tokens": has_image_token,
            "video_tokens": has_video_token,
            "preprocessor_config": files["preprocessor_config.json"],
            "video_preprocessor_config": files["video_preprocessor_config.json"],
        },
        "mtp": inspect_mtp(path, config, jang, tuning, safetensors),
    }


def write_summary(out_dir: Path, rows: list[dict[str, Any]]) -> None:
    lines = [
        "# PR 1147 Bundle Census",
        "",
        "This is file-level evidence only. It does not prove runtime coherency,",
        "cache hits, UI defaults, HTTP behavior, or parser separation.",
        "",
        "| Label | Exists | VLM evidence | MTP auto-enable | MTP reason | Generation defaults |",
        "|---|---:|---|---:|---|---|",
    ]
    for row in rows:
        caps = row["capability_evidence"]
        vlm_parts = [
            name
            for name, present in [
                ("vision_config", caps["vision_config"]),
                ("audio_config", caps["audio_config"]),
                ("image_tokens", caps["image_tokens"]),
                ("video_tokens", caps["video_tokens"]),
                ("preprocessor", caps["preprocessor_config"]),
                ("video_preprocessor", caps["video_preprocessor_config"]),
            ]
            if present
        ]
        generation = row["generation_defaults"]
        generation_text = ", ".join(f"{key}={generation[key]}" for key in sorted(generation))
        lines.append(
            "| {label} | {exists} | {vlm} | {mtp_enable} | {mtp_reason} | {generation} |".format(
                label=row["label"],
                exists=str(row["exists"]).lower(),
                vlm=", ".join(vlm_parts) or "none",
                mtp_enable=str(row["mtp"]["auto_enable"]).lower(),
                mtp_reason=row["mtp"]["reason"],
                generation=generation_text or "none",
            )
        )
    lines.append("")
    out_dir.joinpath("summary.md").write_text("\n".join(lines), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--models-root",
        default=str(Path.home() / "models"),
        help="Root containing local model folders. Default: ~/models",
    )
    parser.add_argument(
        "--output-dir",
        default="docs/internal/live-gates/pr1147/bundle-census",
        help="Directory for bundle_census.json and per-bundle artifacts.",
    )
    parser.add_argument(
        "--model",
        action="append",
        default=[],
        help="Specific model path to inspect. May be absolute or relative to --models-root.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.models_root).expanduser()
    model_args = args.model or DEFAULT_MODEL_RELATIVE_PATHS
    targets: list[BundleTarget] = []
    for item in model_args:
        path = Path(item).expanduser()
        if not path.is_absolute():
            path = root / path
        label = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
        targets.append(BundleTarget(label=label, path=path))

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = [inspect_bundle(target) for target in targets]
    out_dir.joinpath("bundle_census.json").write_text(
        json.dumps({"models_root": str(root), "rows": rows}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    for row in rows:
        bundle_dir = out_dir / slugify(row["label"])
        bundle_dir.mkdir(parents=True, exist_ok=True)
        bundle_dir.joinpath("bundle_census.json").write_text(
            json.dumps(row, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    write_summary(out_dir, rows)
    print(f"wrote {len(rows)} bundle rows to {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
