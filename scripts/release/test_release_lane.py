import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location("release_lane", Path(__file__).with_name("release_lane.py"))
lanes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lanes)


def appcast(*versions):
    items = "".join(f"<item><sparkle:version>{version}</sparkle:version></item>" for version in versions)
    return ('<?xml version="1.0" encoding="utf-8"?><rss version="2.0" '
            'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f"<channel><title>Osaurus</title>{items}</channel></rss>")


def feed_item(version, channel=None):
    channel_line = f"      <sparkle:channel>{channel}</sparkle:channel>\n" if channel else ""
    return (f"    <item>\n      <title>{version}</title>\n      <sparkle:version>{version}</sparkle:version>\n"
            f"{channel_line}      <enclosure url=\"Osaurus-{version}.dmg\" sparkle:edSignature=\"sig-{version}\"/>\n"
            "    </item>\n")


def generated_feed(*items):
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n    <title>Osaurus</title>\n" + "".join(items) + "  </channel>\n</rss>\n")


class ReleaseLaneTests(unittest.TestCase):
    def test_classic_tags_publish_to_appcast_and_never_take_latest(self):
        for version in ("0.25.34", "0.25.34-beta.1", "v0.26.0"):
            lane = lanes.ReleaseLane.for_version(version)
            self.assertEqual(lane.name, "classic")
            self.assertEqual(lane.appcast_file, "appcast.xml")
            self.assertFalse(lane.marks_latest)
            self.assertFalse(lane.attaches_unversioned_dmg)
            self.assertFalse(lane.builds_full_dmg)
        self.assertEqual(lanes.ReleaseLane.for_version("0.25.34").title, "Osaurus Classic 0.25.34")

    def test_main_tags_publish_to_appcast_next_and_stable_takes_latest(self):
        stable = lanes.ReleaseLane.for_version("1.0.0")
        self.assertEqual((stable.name, stable.appcast_file, stable.title), ("main", "appcast-next.xml", "Osaurus 1.0.0"))
        self.assertTrue(stable.marks_latest)
        self.assertTrue(stable.attaches_unversioned_dmg)
        self.assertTrue(stable.builds_full_dmg)
        beta = lanes.ReleaseLane.for_version("1.1.0-beta.2")
        self.assertEqual(beta.appcast_file, "appcast-next.xml")
        self.assertFalse(beta.marks_latest)
        self.assertEqual(beta.title, "Osaurus 1.1.0-beta.2 (Beta)")
        self.assertEqual(lanes.ReleaseLane.for_version("2.0.0").name, "main")

    def test_untagged_dispatch_builds_resolve_without_taking_latest(self):
        lane = lanes.ReleaseLane.for_version("1.0.0-dev")
        self.assertEqual(lane.appcast_file, "appcast-next.xml")
        self.assertFalse(lane.marks_latest)

    def test_unrecognized_versions_are_rejected(self):
        for version in ("1.0", "1.0.0-internal.3", "1.0.0-rc.1", "latest", ""):
            with self.assertRaises(ValueError):
                lanes.ReleaseLane.for_version(version)

    def test_previous_tag_stays_in_lane_and_skips_betas_for_stable(self):
        tags = ["0.25.32", "0.25.33", "0.25.34-beta.1", "1.0.0", "1.0.1-beta.1", "1.0.0-internal.9", "0.25.40"]
        self.assertEqual(lanes.ReleaseLane.for_version("0.25.34").previous_tag(tags), "0.25.33")
        self.assertEqual(lanes.ReleaseLane.for_version("0.25.34-beta.2").previous_tag(tags), "0.25.34-beta.1")
        self.assertEqual(lanes.ReleaseLane.for_version("1.0.1").previous_tag(tags), "1.0.0")
        self.assertEqual(lanes.ReleaseLane.for_version("1.0.1-beta.2").previous_tag(tags), "1.0.1-beta.1")
        self.assertIsNone(lanes.ReleaseLane.for_version("1.0.0").previous_tag(tags))

    def test_feed_check_accepts_own_lane_items(self):
        lanes.check_feed(lanes.ReleaseLane.for_version("0.25.34"), "appcast.xml", appcast("0.25.33", "0.0.9"))
        lanes.check_feed(lanes.ReleaseLane.for_version("1.0.1"), "appcast-next.xml", appcast())
        lanes.check_feed(lanes.ReleaseLane.for_version("1.0.1"), "appcast-next.xml", appcast("1.0.0", "1.0.1-beta.1"))

    def test_feed_check_refuses_the_other_lanes_feed_or_items(self):
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("1.0.0-beta.1"), "appcast.xml", appcast("0.25.33"))
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("1.0.0"), "appcast.xml", appcast("0.25.33", "1.0.0"))
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("0.25.34"), "appcast-next.xml", appcast())
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("0.25.34"), "appcast.xml", appcast("0.25.33", "1.0.0"))
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("1.0.1"), "appcast-next.xml", appcast("1.0.0", "0.25.34"))

    def test_classic_feed_accepts_one_beta_channel_upgrade_offer(self):
        classic = generated_feed(feed_item("1.0.0", "beta"), feed_item("0.25.33", "release"))
        lanes.check_feed(lanes.ReleaseLane.for_version("0.25.34"), "appcast.xml", classic)
        lanes.check_feed(lanes.ReleaseLane.for_version("1.0.1"), "appcast.xml", classic)

    def test_classic_feed_refuses_an_upgrade_every_classic_user_would_see(self):
        classic = lanes.ReleaseLane.for_version("0.25.34")
        for channel in ("release", None):
            with self.assertRaises(ValueError):
                lanes.check_feed(classic, "appcast.xml", generated_feed(feed_item("1.0.0", channel)))
        with self.assertRaises(ValueError):
            lanes.check_feed(classic, "appcast.xml",
                             generated_feed(feed_item("1.0.1", "beta"), feed_item("1.0.0", "beta")))
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("1.0.1"), "appcast-next.xml",
                             generated_feed(feed_item("0.25.33", "beta")))

    def test_only_a_stable_main_release_may_write_the_classic_feed(self):
        classic = generated_feed(feed_item("0.25.33"))
        for version in ("1.0.1-beta.1", "1.0.1-dev"):
            with self.assertRaises(ValueError):
                lanes.check_feed(lanes.ReleaseLane.for_version(version), "appcast.xml", classic)
        self.assertTrue(lanes.ReleaseLane.for_version("1.0.0").offers_classic_upgrade)
        self.assertFalse(lanes.ReleaseLane.for_version("1.0.1-beta.1").offers_classic_upgrade)
        self.assertFalse(lanes.ReleaseLane.for_version("0.25.34").offers_classic_upgrade)

    def test_upgrade_offer_replaces_the_previous_one_and_leaves_classic_items_alone(self):
        classic_items = [feed_item("0.25.34-beta.1", "beta"), feed_item("0.25.33", "release")]
        classic = generated_feed(feed_item("1.0.0", "beta"), *classic_items)
        release = generated_feed(feed_item("1.0.1", "release"))
        updated = lanes.with_classic_upgrade(lanes.ReleaseLane.for_version("1.0.1"), classic, release)

        self.assertEqual(lanes.feed_items(updated),
                         [("1.0.1", "beta"), ("0.25.34-beta.1", "beta"), ("0.25.33", "release")])
        for item in classic_items:
            self.assertIn(item, updated)
        offer = updated[updated.index("<item>"):updated.index("</item>")]
        self.assertEqual(offer.count("<sparkle:channel>"), 1)
        self.assertIn("<sparkle:minimumAutoupdateVersion>1.0.0</sparkle:minimumAutoupdateVersion>", offer)
        self.assertIn('sparkle:edSignature="sig-1.0.1"', offer)

    def test_upgrade_offer_into_a_feed_with_no_items(self):
        updated = lanes.with_classic_upgrade(lanes.ReleaseLane.for_version("1.0.0"), generated_feed(),
                                             generated_feed(feed_item("1.0.0")))
        self.assertEqual(lanes.feed_items(updated), [("1.0.0", "beta")])

    def test_upgrade_offer_refuses_betas_classic_and_missing_items(self):
        classic = generated_feed(feed_item("0.25.33"))
        with self.assertRaises(ValueError):
            lanes.with_classic_upgrade(lanes.ReleaseLane.for_version("1.0.1-beta.1"), classic,
                                       generated_feed(feed_item("1.0.1-beta.1")))
        with self.assertRaises(ValueError):
            lanes.with_classic_upgrade(lanes.ReleaseLane.for_version("0.25.34"), classic,
                                       generated_feed(feed_item("0.25.34")))
        with self.assertRaises(ValueError):
            lanes.with_classic_upgrade(lanes.ReleaseLane.for_version("1.0.1"), classic,
                                       generated_feed(feed_item("1.0.0")))

    def test_feed_check_refuses_items_without_a_version(self):
        broken = appcast("1.0.0").replace("<sparkle:version>1.0.0</sparkle:version>", "")
        with self.assertRaises(ValueError):
            lanes.check_feed(lanes.ReleaseLane.for_version("1.0.1"), "appcast-next.xml", broken)

    def test_check_feed_command_exits_nonzero_on_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "appcast.xml"
            path.write_text(appcast("0.25.33"))
            with patch("sys.stderr"):
                self.assertEqual(lanes.main(["check-feed", "--version", "1.0.0-beta.1", "--feed-file", "appcast.xml",
                                             "--appcast", str(path)]), 1)
            with patch("sys.stdout"):
                self.assertEqual(lanes.main(["check-feed", "--version", "0.25.34", "--feed-file", "appcast.xml",
                                             "--appcast", str(path)]), 0)

    def test_export_writes_github_env_and_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            env_path, output_path = Path(directory) / "env", Path(directory) / "output"
            with patch.dict(os.environ, {"GITHUB_ENV": str(env_path), "GITHUB_OUTPUT": str(output_path)}), \
                    patch("sys.stdout"):
                self.assertEqual(lanes.main(["export", "--version", "0.25.34"]), 0)
            env = env_path.read_text().splitlines()
            output = output_path.read_text().splitlines()
        self.assertIn("RELEASE_LANE=classic", env)
        self.assertIn("APPCAST_FILE=appcast.xml", env)
        self.assertIn("MARKS_LATEST=false", env)
        self.assertIn("ATTACH_UNVERSIONED_DMG=false", env)
        self.assertIn("RELEASE_TITLE=Osaurus Classic 0.25.34", env)
        self.assertEqual(output, ["lane=classic", "builds_full_dmg=false"])


if __name__ == "__main__":
    unittest.main()
