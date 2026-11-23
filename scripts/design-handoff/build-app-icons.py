#!/usr/bin/env python3
"""Generate the existing macOS AppIcon slots and an opaque iOS master from a 1024 px PNG."""

import argparse
import json
import shutil
import tempfile
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    raise SystemExit("Install Pillow in your Python environment to generate icon files.")


def build_mac(source, master, catalog, profile):
    slots = json.loads((catalog / "Contents.json").read_text())["images"]
    with tempfile.TemporaryDirectory(prefix="osaurus-appicon-", dir=catalog.parent) as temp:
        rendered = []
        for item in slots:
            if item.get("idiom") != "mac":
                raise ValueError("The target must be a Mac-only AppIcon catalog.")
            filename = item["filename"]
            if Path(filename).name != filename:
                raise ValueError(f"Invalid asset filename: {filename}")
            scale = int(item["scale"].removesuffix("x"))
            size = tuple(int(n) * scale for n in item["size"].split("x"))
            output = Path(temp) / filename
            if size == master.size:
                shutil.copyfile(source, output)
            else:
                master.resize(size, Image.Resampling.LANCZOS).save(output, icc_profile=profile, optimize=True)
            with Image.open(output) as check:
                if check.size != size:
                    raise ValueError(f"Unexpected size for {filename}: {check.size}")
            rendered.append(output)
        for output in rendered:
            output.replace(catalog / output.name)
    print(f"Updated {len(slots)} macOS icon slots in {catalog}.")


def build_ios(master, output, profile):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="osaurus-ios-icon-", dir=output.parent) as temp:
        staged = Path(temp) / "AppIcon.png"
        master.convert("RGB").save(staged, icc_profile=profile, optimize=True)
        with Image.open(staged) as check:
            if check.mode != "RGB" or check.size != master.size:
                raise ValueError("The iOS export must be a 1024 px RGB PNG.")
        staged.replace(output)
    print(f"Exported the opaque iOS icon to {output}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("master", type=Path)
    parser.add_argument("--mac-catalog", type=Path)
    parser.add_argument("--ios-out", type=Path)
    args = parser.parse_args()
    if not (args.mac_catalog or args.ios_out):
        parser.error("Provide --mac-catalog, --ios-out, or both.")
    try:
        with Image.open(args.master) as master:
            if master.format != "PNG" or master.size != (1024, 1024):
                raise ValueError("The master must be a 1024 × 1024 PNG.")
            profile = master.info.get("icc_profile")
            if args.ios_out and master.convert("RGBA").getchannel("A").getextrema() != (255, 255):
                raise ValueError("The iOS default icon needs a fully opaque, full-square background.")
            if args.mac_catalog:
                build_mac(args.master, master, args.mac_catalog, profile)
            if args.ios_out:
                build_ios(master, args.ios_out, profile)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, f"Icon generation failed: {exc}\n")


if __name__ == "__main__":
    main()
