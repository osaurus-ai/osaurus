"""Map a release version to its lane: Osaurus Classic (0.x) or Osaurus (1.x and later).

Every lane-dependent release step reads this module, so a tag can only
publish to its own feed and only a 1.x stable release becomes Latest. A 1.x
stable release also replaces the opt-in upgrade offer in Classic's feed.
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
# Classic offers beta-channel items only to users who turned on Beta Updates,
# so the newest stable 1.x sits there as their opt-in upgrade. Sparkle asks
# before installing anything below minimumAutoupdateVersion, even for users
# who chose automatic installs.
UPGRADE_CHANNEL = "beta"
UPGRADE_MINIMUM_AUTOUPDATE_VERSION = "1.0.0"
_ITEM = re.compile(r"[ \t]*<item>.*?</item>[ \t]*\n?", re.DOTALL)
_ITEM_VERSION = re.compile(r"<sparkle:version>\s*([^<\s]+)\s*</sparkle:version>")
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
    def offers_classic_upgrade(self):
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


def feed_items(appcast_text):
    """(version, channel) for every item; channel is None when the item has none."""
    root = ElementTree.fromstring(appcast_text)
    items = []
    for item in root.iter("item"):
        element = item.find(f"{{{SPARKLE_NAMESPACE}}}version")
        if element is None:
            element = item.find(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
        if element is None or not (element.text or "").strip():
            raise ValueError("appcast item has no sparkle:version")
        channel = item.find(f"{{{SPARKLE_NAMESPACE}}}channel")
        items.append((element.text.strip(), (channel.text or "").strip() if channel is not None else None))
    return items


def feed_item_versions(appcast_text):
    return [version for version, _ in feed_items(appcast_text)]


def version_lane(version):
    major = re.match(r"^(\d+)\.", version)
    if not major:
        raise ValueError(f"appcast item version {version!r} has no major version")
    return lane_name(int(major.group(1)))


def check_feed(lane, feed_file, appcast_text):
    """Refuse to publish when the feed is not this lane's or holds the other lane's items.

    The one exception is the Classic upgrade offer: appcast.xml may hold a
    single 1.x item on the beta channel, which a stable 1.x release writes.
    """
    offering_upgrade = feed_file == FEEDS["classic"] and lane.offers_classic_upgrade
    if feed_file != lane.appcast_file and not offering_upgrade:
        raise ValueError(f"{lane.version} is a {lane.name} release and publishes only to "
                         f"{lane.appcast_file}, not {feed_file}")
    feed_lane = "classic" if feed_file == FEEDS["classic"] else "main"
    upgrades = []
    for version, channel in feed_items(appcast_text):
        item_lane = version_lane(version)
        if item_lane == feed_lane:
            continue
        if feed_lane == "classic" and channel == UPGRADE_CHANNEL:
            upgrades.append(version)
            continue
        raise ValueError(f"{feed_file} would contain {version}, which belongs to the {item_lane} lane")
    if len(upgrades) > 1:
        raise ValueError(f"{feed_file} offers more than one upgrade to Osaurus 1.x: {', '.join(upgrades)}")


def upgrade_item(item_text):
    """The 1.x feed item, moved to the beta channel and marked as a major upgrade."""
    item = re.sub(r"\s*<sparkle:(channel|minimumAutoupdateVersion)>[^<]*</sparkle:\1>", "", item_text)
    indent = re.search(r"\n([ \t]+)<", item)
    indent = indent.group(1) if indent else "      "
    extra = (f"{indent}<sparkle:channel>{UPGRADE_CHANNEL}</sparkle:channel>\n"
             f"{indent}<sparkle:minimumAutoupdateVersion>{UPGRADE_MINIMUM_AUTOUPDATE_VERSION}"
             f"</sparkle:minimumAutoupdateVersion>\n")
    closing = item.rindex("</item>")
    line_start = item.rfind("\n", 0, closing) + 1
    return item[:line_start] + extra + item[line_start:]


def with_classic_upgrade(lane, classic_text, new_items_text):
    """appcast.xml with its 1.x upgrade offer replaced by this release; Classic items are untouched."""
    if not lane.offers_classic_upgrade:
        raise ValueError(f"{lane.version} does not offer a Classic upgrade; only stable 1.x releases do")
    current = [item for item in _ITEM.findall(new_items_text) if _version_of(item) == str(lane.version)]
    if len(current) != 1:
        raise ValueError(f"expected one feed item for {lane.version}, found {len(current)}")
    stripped = _ITEM.sub(lambda match: "" if version_lane(_version_of(match.group(0))) == "main"
                         else match.group(0), classic_text)
    offer = upgrade_item(current[0])
    if not offer.endswith("\n"):
        offer += "\n"
    first_item = _ITEM.search(stripped)
    if first_item:
        insert_at = first_item.start()
    else:
        insert_at = stripped.rfind("\n", 0, stripped.rindex("</channel>")) + 1
    updated = stripped[:insert_at] + offer + stripped[insert_at:]
    check_feed(lane, FEEDS["classic"], updated)
    return updated


def _version_of(item_text):
    match = _ITEM_VERSION.search(item_text)
    if not match:
        raise ValueError("appcast item has no sparkle:version")
    return match.group(1)


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
    field.add_argument("name", choices=["name", "appcast_file", "title", "marks_latest", "offers_classic_upgrade"])
    check = commands.add_parser("check-feed", help="fail unless the appcast is safe to publish")
    check.add_argument("--version", required=True)
    check.add_argument("--feed-file", required=True)
    check.add_argument("--appcast", required=True, type=Path)
    offer = commands.add_parser("offer-upgrade", help="write appcast.xml with this release as the Classic beta upgrade")
    offer.add_argument("--version", required=True)
    offer.add_argument("--items", required=True, type=Path, help="this release's generated feed items")
    offer.add_argument("--appcast", required=True, type=Path, help="the current appcast.xml")
    offer.add_argument("--output", required=True, type=Path)
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
        elif arguments.command == "offer-upgrade":
            updated = with_classic_upgrade(lane, arguments.appcast.read_text(encoding="utf-8"),
                                           arguments.items.read_text(encoding="utf-8"))
            arguments.output.write_text(updated, encoding="utf-8")
            print(f"{FEEDS['classic']} offers {lane.version} to Classic users with Beta Updates on")
        else:
            check_feed(lane, arguments.feed_file, arguments.appcast.read_text(encoding="utf-8"))
            print(f"{arguments.feed_file} is safe to publish for {lane.version}")
    except (ValueError, ElementTree.ParseError) as error:
        print(f"release_lane: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
