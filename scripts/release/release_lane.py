"""Map a release version to its lane: Osaurus Classic (0.x) or Osaurus (1.x and later).

Every lane-dependent release step reads this module, so a tag can only
publish to its own feed and only a 1.x stable release becomes Latest.
"""
import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import sys
from typing import Iterable, Optional
import xml.etree.ElementTree as ElementTree

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEEDS = {"classic": "appcast.xml", "main": "appcast-next.xml"}
CLASSIC_NOTICE = (
    "This is a maintenance release for Osaurus Classic. "
    "New users should download Osaurus 1.0 from https://osaurus.ai."
)

_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+)|(-dev))?$")


@dataclass(frozen=True)
class Version:
    major: int
    minor: int
    patch: int
    beta: Optional[int]
    # setup_env.sh names untagged workflow_dispatch builds X.Y.Z-dev.
    dev: bool = False

    @classmethod
    def parse(cls, text):
        match = _VERSION.match(text.strip().removeprefix("v"))
        if not match:
            raise ValueError(f"{text!r} is not a release version (X.Y.Z or X.Y.Z-beta.N)")
        major, minor, patch, beta, dev = match.groups()
        return cls(int(major), int(minor), int(patch), int(beta) if beta is not None else None, dev is not None)

    @property
    def is_prerelease(self):
        return self.beta is not None or self.dev

    def sort_key(self):
        # A stable release sorts after its own betas.
        return (self.major, self.minor, self.patch, not self.is_prerelease, self.beta or 0)

    def __str__(self):
        base = f"{self.major}.{self.minor}.{self.patch}"
        if self.dev:
            return f"{base}-dev"
        return base if self.beta is None else f"{base}-beta.{self.beta}"


def lane_name(major):
    return "classic" if major == 0 else "main"


@dataclass(frozen=True)
class ReleaseLane:
    version: Version

    @classmethod
    def for_version(cls, text):
        return cls(Version.parse(text))

    @property
    def name(self):
        return lane_name(self.version.major)

    @property
    def is_classic(self):
        return self.name == "classic"

    @property
    def is_beta(self):
        return self.version.is_prerelease

    @property
    def appcast_file(self):
        return FEEDS[self.name]

    @property
    def marks_latest(self):
        """Latest drives releases/latest/download/Osaurus.dmg, the website and Homebrew."""
        return not self.is_classic and not self.is_beta

    @property
    def attaches_unversioned_dmg(self):
        return not self.is_classic

    @property
    def builds_full_dmg(self):
        return not self.is_classic

    @property
    def title(self):
        product = "Osaurus Classic" if self.is_classic else "Osaurus"
        suffix = " (Beta)" if self.is_beta else ""
        return f"{product} {self.version}{suffix}"

    def previous_tag(self, tags: Iterable[str]):
        """The newest earlier tag in this lane; betas count only for a beta."""
        candidates = []
        for tag in tags:
            try:
                other = Version.parse(tag)
            except ValueError:
                continue
            if lane_name(other.major) != self.name or other.sort_key() >= self.version.sort_key():
                continue
            if other.dev or (other.beta is not None and not self.is_beta):
                continue
            candidates.append((other.sort_key(), tag))
        return max(candidates)[1] if candidates else None


def feed_item_versions(appcast_text):
    root = ElementTree.fromstring(appcast_text)
    versions = []
    for item in root.iter("item"):
        element = item.find(f"{{{SPARKLE_NAMESPACE}}}version")
        if element is None:
            element = item.find(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
        if element is None or not (element.text or "").strip():
            raise ValueError("appcast item has no sparkle:version")
        versions.append(element.text.strip())
    return versions


def check_feed(lane, feed_file, appcast_text):
    """Refuse to publish when the feed is not this lane's or holds the other lane's items."""
    if feed_file != lane.appcast_file:
        raise ValueError(f"{lane.version} is a {lane.name} release and publishes only to "
                         f"{lane.appcast_file}, not {feed_file}")
    for version in feed_item_versions(appcast_text):
        major = re.match(r"^(\d+)\.", version)
        if not major:
            raise ValueError(f"appcast item version {version!r} has no major version")
        if lane_name(int(major.group(1))) != lane.name:
            raise ValueError(f"{feed_file} would contain {version}, which belongs to the "
                             f"{lane_name(int(major.group(1)))} lane")


def github_env_lines(lane):
    flag = lambda value: "true" if value else "false"
    return [
        f"RELEASE_LANE={lane.name}",
        f"APPCAST_FILE={lane.appcast_file}",
        f"MARKS_LATEST={flag(lane.marks_latest)}",
        f"ATTACH_UNVERSIONED_DMG={flag(lane.attaches_unversioned_dmg)}",
        f"BUILDS_FULL_DMG={flag(lane.builds_full_dmg)}",
        f"RELEASE_TITLE={lane.title}",
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export", help="append the lane settings to GITHUB_ENV and GITHUB_OUTPUT")
    export.add_argument("--version", required=True)
    field = commands.add_parser("field", help="print one lane setting")
    field.add_argument("--version", required=True)
    field.add_argument("name", choices=["name", "appcast_file", "title", "marks_latest"])
    check = commands.add_parser("check-feed", help="fail unless the appcast is safe to publish")
    check.add_argument("--version", required=True)
    check.add_argument("--feed-file", required=True)
    check.add_argument("--appcast", required=True, type=Path)
    arguments = parser.parse_args(argv)

    try:
        lane = ReleaseLane.for_version(arguments.version)
        if arguments.command == "export":
            lines = github_env_lines(lane)
            for line in lines:
                print(line)
            if os.environ.get("GITHUB_ENV"):
                with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as env:
                    env.write("\n".join(lines) + "\n")
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                    output.write(f"lane={lane.name}\nbuilds_full_dmg={str(lane.builds_full_dmg).lower()}\n")
        elif arguments.command == "field":
            value = getattr(lane, arguments.name)
            print(str(value).lower() if isinstance(value, bool) else value)
        else:
            check_feed(lane, arguments.feed_file, arguments.appcast.read_text(encoding="utf-8"))
            print(f"{arguments.feed_file} holds only {lane.name} items")
    except (ValueError, ElementTree.ParseError) as error:
        print(f"release_lane: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
