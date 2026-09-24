#!/usr/bin/env python3
"""Transfer one exact-source Xcode test build between CI jobs."""

import argparse
import io
import json
from pathlib import Path
import platform
import subprocess
import tarfile


def build_identity():
    return {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "tree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip(),
        "workspace": str(Path.cwd().resolve()),
        "home": str(Path.home()),
        "architecture": platform.machine(),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    }


def pack(archive, derived_data, identity):
    runs = list(derived_data.glob("*/Build/Products/OsaurusCoreTests*.xctestrun"))
    if len(runs) != 1:
        raise ValueError(f"Expected one OsaurusCoreTests xctestrun, found {len(runs)}")
    run = runs[0]
    products = run.parent.relative_to(derived_data)
    manifest = dict(identity, products=str(products), xctestrun=str(run.relative_to(derived_data)))
    data = json.dumps(manifest, sort_keys=True).encode()
    archive.parent.mkdir(parents=True, exist_ok=True)
    # A tar preserves executable bits and framework symlinks across artifact
    # upload/download. Only runtime products travel, not object/module caches.
    with tarfile.open(archive, "w:gz", compresslevel=1) as bundle:
        info = tarfile.TarInfo("core-test-build.json")
        info.size = len(data)
        bundle.addfile(info, io.BytesIO(data))
        bundle.add(derived_data / products, arcname=str(products))


def unpack(archive, derived_data, identity):
    with tarfile.open(archive, "r:gz") as bundle:
        manifest = json.load(bundle.extractfile("core-test-build.json"))
        for key, value in identity.items():
            if manifest.get(key) != value:
                raise ValueError(f"Test build identity mismatch: {key}")
        products = Path(manifest["products"])
        run = Path(manifest["xctestrun"])
        if products.is_absolute() or ".." in products.parts or run.parent != products:
            raise ValueError("Invalid test-product paths")
        destination = derived_data / products
        if destination.exists():
            raise ValueError("Refusing to mix restored test products with an existing build")
        members = [member for member in bundle.getmembers() if member.name != "core-test-build.json"]
        for member in members:
            path = Path(member.name)
            if path != products and products not in path.parents:
                raise ValueError("Archive member outside test products")
        derived_data.mkdir(parents=True, exist_ok=True)
        bundle.extractall(derived_data, members=members, filter="data")
    result = derived_data / run
    if not result.is_file():
        raise ValueError("Restored test run is missing")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["pack", "unpack"])
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    identity = build_identity()
    if args.operation == "pack":
        pack(args.archive, derived_data, identity)
    else:
        run = unpack(args.archive, derived_data, identity)
        Path("build/core-test-run.path").write_text(str(run) + "\n")


if __name__ == "__main__":
    main()
