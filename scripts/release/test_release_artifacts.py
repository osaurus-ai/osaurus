import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_artifacts", Path(__file__).with_name("release_artifacts.py"))
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class ReleaseArtifactTests(unittest.TestCase):
    def test_checkpoint_preserves_exact_file_identity_for_all_four_artifacts(self):
        names = ["Osaurus-app.zip", "Osaurus-0.25.99.dmg", "Osaurus.dmg", "Osaurus-0.25.99-dSYMs.zip"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in names:
                (root / name).write_bytes((name + "\0fixture\n").encode())
            expected = {name: (root / name).read_bytes() for name in names}
            receipt = artifacts.checkpoint(root, "0.25.99", "a" * 40)
            self.assertEqual(receipt["source"], "a" * 40)
            self.assertEqual(artifacts.verify(root, "0.25.99", "a" * 40), receipt)
            self.assertEqual(receipt, json.loads((root / "release-artifacts.json").read_text()))
            for row in receipt["files"]:
                self.assertEqual(row["sha256"], hashlib.sha256(expected[row["name"]]).hexdigest())
                self.assertEqual(row["bytes"], len(expected[row["name"]]))
                self.assertEqual((root / row["name"]).read_bytes(), expected[row["name"]])

    def test_restore_verification_rejects_tampering_wrong_source_and_unexpected_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["Osaurus-app.zip", "Osaurus-0.25.99.dmg", "Osaurus.dmg", "Osaurus-0.25.99-dSYMs.zip"]:
                (root / name).write_bytes(b"fixture")
            receipt = artifacts.checkpoint(root, "0.25.99", "a" * 40)
            for version, source in [("0.25.98", "a" * 40), ("0.25.99", "b" * 40)]:
                with self.assertRaises(ValueError):
                    artifacts.verify(root, version, source)
            (root / "Osaurus-app.zip").write_bytes(b"tampered")
            with self.assertRaises(ValueError):
                artifacts.verify(root, "0.25.99", "a" * 40)
            receipt["files"][0]["name"] = "../unexpected"
            (root / "release-artifacts.json").write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                artifacts.verify(root, "0.25.99", "a" * 40)

    def test_missing_or_empty_file_cannot_produce_a_partial_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["Osaurus-app.zip", "Osaurus-0.25.99.dmg", "Osaurus.dmg"]:
                (root / name).write_bytes(b"fixture")
            for empty_dsym in (False, True):
                if empty_dsym:
                    (root / "Osaurus-0.25.99-dSYMs.zip").write_bytes(b"")
                with self.assertRaises(ValueError):
                    artifacts.checkpoint(root, "0.25.99", "a" * 40)
                self.assertFalse((root / "release-artifacts.json").exists())

    def test_workflow_uploads_qualified_files_before_external_services(self):
        path = Path(__file__).parents[2] / ".github/workflows/build-and-release.yml"
        workflow = path.read_text()
        markers = ["- name: Verify App Signing", "- name: Verify App Launch", "- name: Notarize DMG (light)",
                   "- name: Package dSYMs", "- name: Record Qualified Artifact Identity",
                   "- name: Preserve Qualified Artifacts", "- name: Upload dSYMs to Sentry",
                   "- name: Register Sentry release", "- name: Create Release in Repository"]
        positions = [workflow.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        step = workflow.split("- name: Preserve Qualified Artifacts", 1)[1].split("- name:", 1)[0]
        for name in ["Osaurus-app.zip", "Osaurus-${{ env.VERSION }}.dmg", "Osaurus.dmg",
                     "Osaurus-${{ env.VERSION }}-dSYMs.zip", "release-artifacts.json"]:
            self.assertIn(name, step)
        self.assertIn("if-no-files-found: error", step)
        self.assertNotIn("continue-on-error", step)
        self.assertIn("sentry-cli debug-files upload", (path.parents[2] / "scripts/build/upload_dsyms_sentry.sh").read_text())
        self.assertIn('  --wait', (path.parents[2] / "scripts/build/upload_dsyms_sentry.sh").read_text())


if __name__ == "__main__":
    unittest.main()
