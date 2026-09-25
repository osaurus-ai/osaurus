import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("products", Path(__file__).with_name("core-test-products.py"))
products = importlib.util.module_from_spec(spec)
spec.loader.exec_module(products)


class CoreTestProductsTests(unittest.TestCase):
    def fixture(self, root):
        source = root / "source"
        directory = source / "workspace-hash/Build/Products"
        directory.mkdir(parents=True)
        (directory / "OsaurusCoreTests_macosx-arm64.xctestrun").write_bytes(b"test-run")
        executable = directory / "Debug/Framework.framework/Versions/A/Framework"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"executable-fixture")
        executable.chmod(0o755)
        (executable.parents[2] / "Framework").symlink_to("Versions/A/Framework")
        archive = root / "products.tar.gz"
        identity = {"commit": "exact-head", "tree": "exact-tree", "xcode": "same-toolchain"}
        products.pack(archive, source, identity)
        return archive, identity

    def test_round_trip_preserves_contents_executable_and_framework_link(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive, identity = self.fixture(root)
            run = products.unpack(archive, root / "restored", identity)
            self.assertEqual(run.read_bytes(), b"test-run")
            framework = run.parent / "Debug/Framework.framework/Framework"
            self.assertTrue(framework.is_symlink())
            self.assertEqual(framework.read_bytes(), b"executable-fixture")
            self.assertEqual(framework.stat().st_mode & 0o111, 0o111)
            with self.assertRaisesRegex(ValueError, "existing build"):
                products.unpack(archive, root / "restored", identity)

    def test_rejects_different_source_before_extracting(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive, identity = self.fixture(root)
            with self.assertRaisesRegex(ValueError, "identity mismatch: commit"):
                products.unpack(archive, root / "restored", dict(identity, commit="different"))
            self.assertFalse((root / "restored").exists())


if __name__ == "__main__":
    unittest.main()
