"""Unit tests for coverage.py and apply-ko.py --partial (run: python3 -m unittest discover -s scripts/i18n -p 'test_*.py')."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


COVERAGE = _load("coverage")
APPLY = _load("apply-ko")


def unit(value: str, state: str = "translated") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


class CoverageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="osaurus-i18n-coverage-"))
        self.swift_root = self.tmp / "OsaurusCore"
        (self.swift_root / "Views" / "Workflow").mkdir(parents=True)
        (self.swift_root / "Tests").mkdir(parents=True)
        (self.swift_root / "Views" / "Workflow" / "WorkflowView.swift").write_text(
            'Text(L("Done"))\nText(L("Review me"))\nText(L("English only"))\nText(L("Brand"))\n',
            encoding="utf-8",
        )
        (self.swift_root / "Tests" / "FooTests.swift").write_text('Text(L("Test only"))\n', encoding="utf-8")
        self.catalog = {
            "sourceLanguage": "en",
            "strings": {
                "Done": {"localizations": {"de": unit("Fertig"), "es": unit("Hecho")}},
                "Review me": {"localizations": {"de": unit("Prüf mich", "needs_review")}},
                "English only": {"localizations": {"en": unit("English only")}},
                "Brand": {"shouldTranslate": False, "localizations": {}},
                "Test only": {"localizations": {}},
                "Unused stale": {"extractionState": "stale", "localizations": {}},
            },
        }

    def test_counts_only_referenced_translatable_keys(self) -> None:
        refs = COVERAGE.referenced_keys(self.catalog, self.swift_root)
        self.assertEqual(sorted(refs), ["Done", "English only", "Review me"])

    def test_needs_review_counts_as_translated_and_is_reported(self) -> None:
        keys = ["Done", "English only", "Review me"]
        de = COVERAGE.locale_stats(self.catalog, keys, "de")
        self.assertEqual(de["translated"], 2)
        self.assertEqual(de["needs_review"], 1)
        self.assertEqual(de["missing"], ["English only"])
        es = COVERAGE.locale_stats(self.catalog, keys, "es")
        self.assertEqual(es["translated"], 1)
        self.assertEqual(es["needs_review"], 0)

    def test_inject_replaces_between_markers(self) -> None:
        doc = f"intro\n{COVERAGE.START_MARKER}\nold\n{COVERAGE.END_MARKER}\noutro\n"
        out = COVERAGE.inject(doc, "new table\n")
        self.assertIn("new table", out)
        self.assertNotIn("old", out)
        self.assertTrue(out.endswith(f"{COVERAGE.END_MARKER}\noutro\n"))
        with self.assertRaises(ValueError):
            COVERAGE.inject("no markers", "x")


class ApplyPartialTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="osaurus-i18n-apply-"))
        self.catalog_path = self.tmp / "Localizable.xcstrings"
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "Hello": {"localizations": {"de": unit("Hallo"), "zh-Hans": unit("你好")}},
                "%lld files": {"localizations": {"de": unit("%lld Dateien"), "zh-Hans": unit("%lld 个文件")}},
                "Later": {"localizations": {"de": unit("Später"), "zh-Hans": unit("稍后")}},
                "Already": {
                    "localizations": {"de": unit("Schon"), "es": unit("Ya"), "zh-Hans": unit("已经")}
                },
                "Stub": {"localizations": {"de": unit("Stub"), "es": unit(""), "zh-Hans": unit("存根")}},
            },
        }
        self.catalog_path.write_text(APPLY.dump_xcode(catalog), encoding="utf-8")

    def run_apply(self, mapping: dict, *extra: str) -> subprocess.CompletedProcess:
        maps = self.tmp / "es.json"
        maps.write_text(json.dumps(mapping, ensure_ascii=False), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(HERE / "apply-ko.py"), str(self.catalog_path), "--locale", "es",
             "--maps", str(maps), *extra],
            capture_output=True,
            text=True,
        )

    def es(self) -> dict:
        strings = json.loads(self.catalog_path.read_text(encoding="utf-8"))["strings"]
        return {k: e["localizations"].get("es") for k, e in strings.items()}

    def test_partial_writes_only_mapped_keys(self) -> None:
        result = self.run_apply({"Hello": "Hola", "Stub": "Talón", "Already": "Otra vez"}, "--partial")
        self.assertEqual(result.returncode, 0, result.stderr)
        es = self.es()
        self.assertEqual(es["Hello"], unit("Hola"))
        self.assertEqual(es["Stub"], unit("Talón"))
        self.assertEqual(es["Already"], unit("Ya"))
        self.assertIsNone(es["Later"])
        self.assertIn("already has es", result.stderr)

    def test_partial_still_validates_placeholders(self) -> None:
        result = self.run_apply({"%lld files": "archivos"}, "--partial")
        self.assertEqual(result.returncode, 1)
        self.assertIn("placeholder mismatch", result.stderr)
        self.assertIsNone(self.es()["%lld files"])

    def test_without_partial_manifest_is_required(self) -> None:
        result = self.run_apply({"Hello": "Hola"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--manifest is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
