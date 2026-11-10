import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("generate_and_deploy_appcast.sh")


def feed(*versions):
    items = "".join(
        f"    <item>\n      <title>{version}</title>\n      <sparkle:version>{version}</sparkle:version>\n    </item>\n"
        for version in versions)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            f"  <channel>\n    <title>Osaurus</title>\n{items}  </channel>\n</rss>\n")


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class AppcastLaneTests(unittest.TestCase):
    """Runs the real deploy script with Sparkle, curl, git and sleep replaced."""

    def deploy(self, version, appcast, appcast_next):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        fixture = root / "fixture-repo" / "docs"
        fixture.mkdir(parents=True)
        (fixture / "appcast.xml").write_text(appcast)
        (fixture / "appcast-next.xml").write_text(appcast_next)

        sparkle = root / "sparkle-src" / "bin"
        sparkle.mkdir(parents=True)
        executable(sparkle / "generate_appcast", f"""#!/bin/sh
cat > updates/appcast-arm64.xml <<'EOF'
{feed(version).replace("</sparkle:version>", '</sparkle:version><enclosure url="Osaurus-' + version + '.dmg" sparkle:edSignature="sig"/>')}EOF
""")
        executable(sparkle / "sign_update", "#!/bin/sh\nexit 1\n")
        with tarfile.open(root / "sparkle.tar.xz", "w:xz") as archive:
            archive.add(sparkle, arcname="bin")

        binary = root / "bin"
        binary.mkdir()
        executable(binary / "sleep", "#!/bin/sh\nexit 0\n")
        executable(binary / "curl", f"""#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    case "$2" in
      sparkle.tar.xz) cp "{root}/sparkle.tar.xz" "$2" ;;
      *) : > "$2" ;;
    esac
    exit 0
  fi
  shift
done
exit 22
""")
        executable(binary / "git", f"""#!/bin/sh
echo "$*" >> "{root}/git-calls"
case "$1" in
  clone) cp -R "{root}/fixture-repo" "$3" ;;
  push) cp docs/* "{root}/pushed/" ;;
esac
exit 0
""")
        (root / "pushed").mkdir()
        work = root / "work"
        work.mkdir()
        env = dict(os.environ, PATH=f"{binary}{os.pathsep}{os.environ['PATH']}", SPARKLE_PRIVATE_KEY="fixture",
                   GH_TOKEN="fixture", PUBLIC_REPO="fixture/repo", VERSION=version, SPARKLE_CHANNEL="release")
        result = subprocess.run(["bash", str(SCRIPT)], cwd=work, env=env, capture_output=True, text=True)
        calls = (root / "git-calls").read_text() if (root / "git-calls").exists() else ""
        return result, root / "pushed", calls

    def test_classic_patch_writes_only_appcast_xml(self):
        result, pushed, calls = self.deploy("0.25.34", feed("0.25.33"), feed())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("add docs/appcast.xml", calls)
        self.assertNotIn("appcast-next.xml", calls)
        classic = (pushed / "appcast.xml").read_text()
        self.assertIn("<sparkle:version>0.25.34</sparkle:version>", classic)
        self.assertIn("<sparkle:version>0.25.33</sparkle:version>", classic)
        self.assertEqual((pushed / "appcast-next.xml").read_text(), feed())

    def test_main_release_writes_only_appcast_next_xml(self):
        result, pushed, calls = self.deploy("1.0.1", feed("0.25.33"), feed("1.0.0"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("add docs/appcast-next.xml", calls)
        self.assertNotIn("add docs/appcast.xml", calls)
        main = (pushed / "appcast-next.xml").read_text()
        self.assertIn("<sparkle:version>1.0.1</sparkle:version>", main)
        self.assertIn("<sparkle:version>1.0.0</sparkle:version>", main)
        self.assertEqual((pushed / "appcast.xml").read_text(), feed("0.25.33"))

    def test_a_feed_holding_the_other_lanes_items_is_not_published(self):
        result, _, calls = self.deploy("1.0.1", feed("0.25.33"), feed("1.0.0", "0.25.30"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0.25.30", result.stderr)
        self.assertNotIn("push", calls)


if __name__ == "__main__":
    unittest.main()
