#!/usr/bin/env python3
"""Build and open the optional macOS design inspector in an isolated offline profile."""

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path


IDENTITY = "studio.topiary.osaurus-design-integration"
LIBRARY = Path("Packages/OsaurusCore/Models/Theme/DesignLibrary/LibraryResources/design-library.json")


def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def running(binary):
    processes = run("/bin/ps", "-axo", "comm=", capture_output=True, text=True).stdout
    return str(binary) in (line.strip() for line in processes.splitlines())


def configure_bundle(app, work, profile, identity):
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info["CFBundleIdentifier"] != IDENTITY:
        raise ValueError("This must be a dedicated inspector build, with its isolated bundle identity.")
    # Xcode's bundle ID override can reach SwiftPM resource bundles.
    # Give each resource-only bundle its own ID before signing the app.
    for bundle in (app / "Contents/Resources").rglob("*.bundle"):
        for resource_info in (bundle / "Contents/Info.plist", bundle / "Info.plist"):
            if resource_info.is_file():
                resource = plistlib.loads(resource_info.read_bytes())
                if resource.get("CFBundleIdentifier") == IDENTITY and not resource.get("CFBundleExecutable"):
                    suffix = re.sub(r"[^a-zA-Z0-9.-]", "-", bundle.stem).lower()
                    resource["CFBundleIdentifier"] = f"{IDENTITY}.resources.{suffix}"
                    resource_info.write_bytes(plistlib.dumps(resource))
                break
    info.update(
        CFBundleDisplayName="Osaurus Design Inspector",
        CFBundleName="Osaurus Design Inspector",
        DesignInspectorConnectedModels=False,
        DesignInspectorDataRoot=str(profile),
        DesignInspectorWorkspace=str(work),
    )
    info.pop("CFBundleURLTypes", None)
    info.pop("CFBundleDocumentTypes", None)
    info_path.write_bytes(plistlib.dumps(info))
    entitlements = work / "inspector.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.files.bookmarks.app-scope": True}))
    run("/usr/bin/codesign", "--force", "--deep", "--sign", identity, str(app))
    run("/usr/bin/codesign", "--force", "--sign", identity, "--entitlements", str(entitlements), str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))


def launch_policy(profile):
    quote = lambda path: json.dumps(str(path))
    allow_write = [profile, Path(tempfile.gettempdir()).resolve(), Path("/private/tmp")]
    writes = " ".join(f"(subpath {quote(path)})" for path in allow_write)
    protected = (".osaurus", "MLXModels", ".claude", ".codex/auth.json",
                 "Library/Application Support/com.dinoki.osaurus")
    return "\n".join([
        "(version 1)", "(allow default)", "(deny file-write*)",
        f'(allow file-write* {writes} (literal "/dev/null"))',
        "(deny network*)",
        '(allow network* (local ip "localhost:*") (remote ip "localhost:*"))',
        *(f"(deny file-read* (subpath {quote(Path.home() / path)}))" for path in protected),
        "",
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--work-dir", type=Path, default=Path.home() / "Library/Application Support/Osaurus Design Inspector")
    parser.add_argument("--build", action="store_true", help="Build from the selected checkout first")
    parser.add_argument("--prepare-only", action="store_true", help="Build if requested, sign and verify, then exit")
    parser.add_argument("--signing-identity", default="-", help="Optional local Apple Development identity")
    parser.add_argument("--port", type=int, default=14379, help="Loopback port for a new profile")
    parser.add_argument("--cloned-source-packages-dir", type=Path, help="Optional SwiftPM dependency cache")
    args = parser.parse_args()
    repo, work = args.repo.resolve(), args.work_dir.resolve()
    profile = work / "Profile"
    build = work / "Build"
    app = build / "Build/Products/Release/osaurus.app"
    binary = app / "Contents/MacOS/osaurus"
    log = work / "build.log"
    try:
        if not (repo / LIBRARY).is_file():
            raise ValueError("Choose a checkout containing the bundled design library.")
        if running(binary):
            raise ValueError("Quit this design inspector normally before rebuilding or reopening it.")
        if not 1024 <= args.port <= 65535:
            raise ValueError("Choose a port between 1024 and 65535.")
        work.mkdir(parents=True, exist_ok=True)
        if args.build:
            print(f"Building the inspector. Log: {log}", flush=True)
            command = [
                "/usr/bin/xcodebuild", "-workspace", "osaurus.xcworkspace", "-scheme", "osaurus",
                "-configuration", "Release", "-derivedDataPath", str(build),
                "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=NO",
                "SWIFT_COMPILATION_MODE=incremental", "SWIFT_OPTIMIZATION_LEVEL=-Onone",
                "DEBUG_INFORMATION_FORMAT=dwarf", f"PRODUCT_BUNDLE_IDENTIFIER={IDENTITY}", "build",
            ]
            if args.cloned_source_packages_dir:
                command[1:1] = ["-clonedSourcePackagesDirPath", str(args.cloned_source_packages_dir.resolve())]
            with log.open("w") as stream:
                run(*command, cwd=repo, env={**os.environ, "OSAURUS_DESIGN_INSPECTOR_BUILD": "1"},
                    stdout=stream, stderr=subprocess.STDOUT)
        if not binary.is_file():
            raise ValueError("Inspector executable is missing. Run this tool with --build.")
        for sub in ("config", "design-inspector", "logs", "models", "model-cache/hub", "temporary"):
            (profile / sub).mkdir(parents=True, exist_ok=True)
        settings = profile / "config/server.json"
        if not settings.exists():
            settings.write_text(json.dumps(dict(
                port=args.port, exposeToNetwork=False, startAtLogin=False,
                hideDockIcon=False, appearanceMode="dark",
            )) + "\n")
        working = profile / "design-inspector/working.json"
        if not working.exists():
            shutil.copyfile(repo / LIBRARY, working)
        configure_bundle(app, work, profile, args.signing_identity)
        env = {**os.environ, "TMPDIR": str(profile / "temporary") + "/"}
        result = run(str(binary), env={**env, "OSAURUS_SPAWN_CHECK": "1"}, capture_output=True, text=True)
        if "OSAURUS_SPAWN_OK" not in result.stdout:
            raise ValueError("The inspector failed its launch check.")
        if args.prepare_only:
            print(f"Inspector signed and ready at {app}.")
            return
        policy = work / "inspector.sb"
        policy.write_text(launch_policy(profile))
        launch_log = profile / "logs" / f"launch-{datetime.now():%Y%m%d-%H%M%S}.log"
        with launch_log.open("wb") as stream:
            process = subprocess.Popen(
                ["/usr/bin/sandbox-exec", "-f", str(policy), str(binary)],
                env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True,
            )
        print(f"Opened the offline inspector (PID {process.pid}). Working design: {working}")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Inspector launch failed: {exc}\nBuild log, if present: {log}\n")


if __name__ == "__main__":
    main()
