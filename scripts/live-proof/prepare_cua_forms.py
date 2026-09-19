#!/usr/bin/env python3
"""Developer-only safe conversion and independent upstream FP32 goldens.

No downloads, device control, secrets, or unrestricted pickle. Install torch
and safetensors in an isolated environment; supply a clean pinned trycua/cua
checkout and the separately obtained model. The app itself never runs Python.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

UPSTREAM = "83f142c4290a0f7d9ed545ae8532858c6e4f8145"
MODEL_REVISION = "4171435d90e7fd78d6d3f0e78b1c4e4cca896706"
MODEL_SHA256 = "f5077f0c9baf6b5fc10f21512e1aa15207a395598416a6ffdd95f0d3dd5ab8df"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New directory; never overwritten")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(args.upstream), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(args.upstream), "status", "--porcelain"], text=True)
    if head != UPSTREAM or dirty:
        parser.error("Reference checkout must be clean at the pinned upstream commit")
    if args.output.exists():
        parser.error("Output already exists; choose a fresh directory")
    if args.checkpoint.is_symlink() or args.checkpoint.stat().st_size != 2_840_436:
        parser.error("Expected the separately obtained, regular published checkpoint")
    checkpoint_hash = hashlib.file_digest(args.checkpoint.open("rb"), "sha256").hexdigest()
    if checkpoint_hash != MODEL_SHA256:
        parser.error("Checkpoint SHA256 does not match the pinned model revision")
    sys.path.insert(0, str(args.upstream / "libs/cua-s1/python/src"))
    import torch
    from cua_s1.checkpoint import save_checkpoint_files
    from cua_s1.model import ChoiceExample, load_checkpoint
    from cua_s1.schema import Element, Entity, render_context, render_options
    from safetensors.torch import load_file

    torch.set_num_threads(2)
    payload = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    args.output.mkdir(parents=True, mode=0o700)
    model_dir = args.output / "scorer"
    save_checkpoint_files(model_dir, payload["state_dict"], payload["config"], {
        "source_repository": "cua-ai/cua-s1-forms", "source_revision": MODEL_REVISION,
        "source_sha256": MODEL_SHA256, "reference_revision": UPSTREAM,
    })
    restored = load_file(str(model_dir / "model.safetensors"))
    original = payload["state_dict"]
    assert set(original) == set(restored)
    assert all(torch.equal(original[key], restored[key]) for key in original)
    model, collator, config = load_checkpoint(model_dir, "cpu")
    entities = [Entity("Full name", "Avery Stone"), Entity("Email", "avery@example.test"),
                Entity("Phone", "503-555-0142"), Entity("Address", "123 Test Lane"),
                Entity("City", "Portland"), Entity("State", "Oregon"),
                Entity("ZIP", "97201"), Entity("Emergency phone", "503-555-0188")]
    options = render_options(entities)
    contexts = []
    schema_rows = []
    for title in ["New Patient Registration", "Contact Information", ""]:
        for role, label, value, checked, placeholder in [
            ("Edit", "Full name", "", None, "Your name"),
            ("Edit", "Email address", "", None, ""),
            ("Edit", "Phone number", "", None, ""),
            ("Edit", "Street address", "", None, ""),
            ("Edit", "City", "", None, ""),
            ("Edit", "State", "", None, ""),
            ("Edit", "ZIP code", "", None, ""),
            ("Edit", "Emergency contact phone", "", None, ""),
            ("Edit", "Email address", "avery@example.test", None, ""),
            ("Edit", "Unknown reference", "", None, ""),
            ("CheckBox", "I agree to the terms", "", False, ""),
            ("CheckBox", "I agree to the terms", "", True, ""),
            ("Button", "Submit", "", None, ""),
            ("Button", "Cancel", "", None, ""),
            ("ComboBox", "State", "", None, ""),
        ]:
            element = Element(role, label, value, checked=checked)
            context = render_context(title, element, placeholder)
            contexts.append(context)
            schema_rows.append(dict(title=title, role=role, label=label, value=value,
                                    checked=checked, placeholder=placeholder, context=context))
    contexts += ["", "x", "é" * 150, "a" * 223 + "é", "漢字" * 100, "a" * 400,
                 "TASK fill the form from the document, then submit\nFORM " + "e\u0301" * 100]

    cases = []
    for case_name, case_contexts, case_options in [
        ("published-form-and-byte-boundaries", contexts, options),
        ("short-options-and-empty-padding", ["", "x", contexts[0]], ["", "check", "skip"]),
        ("unicode-and-truncated-options", [contexts[0], contexts[1], ""],
         ["fill Full name: Avéry 石", "fill Email: " + "x" * 120, "fill ZIP: 97201", "check", "click", "skip"]),
    ]:
        rows = [ChoiceExample(context, tuple(case_options), 0) for context in case_contexts]
        batch = collator(rows)
        start = time.perf_counter()
        with torch.inference_mode():
            probabilities = model(batch).softmax(-1).tolist()
        elapsed = time.perf_counter() - start
        cases.append(dict(name=case_name, contexts=case_contexts, options=case_options,
                          probabilities=probabilities, seconds=elapsed))
    evidence = dict(upstream=UPSTREAM, model_revision=MODEL_REVISION, checkpoint_sha256=checkpoint_hash,
                    torch_version=torch.__version__, tensor_count=len(original),
                    parameter_count=sum(t.numel() for t in original.values()),
                    bit_identical=True, device="cpu", dtype="float32", config=config,
                    schema=schema_rows, cases=cases)
    (args.output / "goldens.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({k: v for k, v in evidence.items() if k not in ("schema", "cases")}, indent=2))
    print(f"Reference goldens: {args.output / 'goldens.json'}")
    print(f"App import folder: {model_dir}")


if __name__ == "__main__":
    main()
