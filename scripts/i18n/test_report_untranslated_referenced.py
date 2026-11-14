"""Unit tests for report-untranslated-referenced.py (run: python3 -m unittest discover -s scripts/i18n -p 'test_*.py')."""

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


REPORT = _load("report-untranslated-referenced")
SCANNER = _load("check-swift-catalog-keys")


def unit(value: str, state: str = "translated") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


class ReportUntranslatedReferencedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="osaurus-i18n-report-"))
        self.swift_root = self.tmp / "OsaurusCore"
        (self.swift_root / "Views" / "Settings").mkdir(parents=True)
        (self.swift_root / "Views" / "Chat").mkdir(parents=True)
        (self.swift_root / "Views" / "Settings" / "MediaSettingsView.swift").write_text(
            'Text(L("Image generation model"))\n'
            'Text(L("Fully translated"))\n'
            'Text(L("Empty German stub"))\n'
            'Text(L("Verbatim brand"))\n'
            'Text(L("Not in catalog at all"))\n',
            encoding="utf-8",
        )
        (self.swift_root / "Views" / "Chat" / "WelcomeView.swift").write_text(
            'Button(localized: "What can Osaurus do?")\n' 'Text(L("Image generation model"))\n',
            encoding="utf-8",
        )
        self.catalog = {
            "sourceLanguage": "en",
            "strings": {
                # en-only Xcode stub: every locale missing.
                "Image generation model": {"localizations": {"en": unit("Image generation model")}},
                # Complete.
                "Fully translated": {
                    "localizations": {
                        "de": unit("Vollständig"),
                        "zh-Hans": unit("完整"),
                        "ko": unit("완료", "needs_review"),
                        "ru": unit("Готово"),
                    }
                },
                # One locale present but empty.
                "Empty German stub": {
                    "localizations": {
                        "de": unit(""),
                        "zh-Hans": unit("德语为空"),
                        "ko": unit("빈 독일어"),
                        "ru": unit("Пусто"),
                    }
                },
                # shouldTranslate: false is copied verbatim, never reported.
                "Verbatim brand": {"shouldTranslate": False, "localizations": {"en": unit("Verbatim brand")}},
                # Missing one locale only.
                "What can Osaurus do?": {
                    "localizations": {
                        "de": unit("Was kann Osaurus?"),
                        "zh-Hans": unit("Osaurus 能做什么？"),
                        "ru": unit("Что умеет Osaurus?"),
                    }
                },
            },
            "version": "1.1",
        }
        self.locales = ["de", "zh-Hans", "ko", "ru"]

    def findings(self) -> dict:
        refs = SCANNER.referenced_keys(self.swift_root)
        return REPORT.collect_findings(self.catalog, refs, self.locales, self.swift_root, SCANNER.canonical_pattern)

    def test_reports_only_referenced_keys_with_untranslated_locales(self) -> None:
        findings = self.findings()
        all_keys = {key for keys in findings.values() for key in keys}
        self.assertEqual(all_keys, {"Image generation model", "Empty German stub", "What can Osaurus do?"})
        chat, settings = findings["Views/Chat"], findings["Views/Settings"]
        self.assertEqual(set(chat["Image generation model"]["locales"]), set(self.locales))
        self.assertEqual(set(settings["Empty German stub"]["locales"]), {"de"})
        self.assertIn("empty", settings["Empty German stub"]["locales"]["de"])
        self.assertEqual(set(chat["What can Osaurus do?"]["locales"]), {"ko"})
        # Complete, verbatim and absent-from-catalog keys are not findings.
        for absent in ("Fully translated", "Verbatim brand", "Not in catalog at all"):
            self.assertNotIn(absent, all_keys)

    def test_each_key_appears_once_under_its_first_sorted_site_with_all_sites(self) -> None:
        findings = self.findings()
        # Referenced from Views/Chat (sorts first) and Views/Settings: listed
        # once, under Views/Chat, with both sites retained in sorted order.
        self.assertNotIn("Image generation model", findings["Views/Settings"])
        refs = findings["Views/Chat"]["Image generation model"]["refs"]
        self.assertEqual(len(refs), 2)
        self.assertTrue(refs[0].endswith("WelcomeView.swift:2"))
        self.assertTrue(refs[1].endswith("MediaSettingsView.swift:1"))

    def test_references_from_test_sources_are_ignored(self) -> None:
        tests_dir = self.swift_root / "Tests" / "Chat"
        tests_dir.mkdir(parents=True)
        (tests_dir / "SomethingTests.swift").write_text('#expect(L("Only in tests") == "x")\n', encoding="utf-8")
        self.catalog["strings"]["Only in tests"] = {"localizations": {"en": unit("Only in tests")}}
        findings = self.findings()
        self.assertNotIn("Tests/Chat", findings)
        self.assertNotIn("Only in tests", {key for keys in findings.values() for key in keys})

    def test_markdown_has_totals_surfaces_and_sites(self) -> None:
        findings = self.findings()
        md = REPORT.render_markdown(findings, self.locales, total_referenced=7, repo_root=self.tmp, max_keys_per_surface=0)
        self.assertIn("3 of 7 referenced catalog keys fall back to English", md)
        self.assertIn("| `de` | 2 |", md)
        self.assertIn("| `zh-Hans` | 1 |", md)
        self.assertIn("| `ko` | 2 |", md)
        self.assertIn("| `ru` | 1 |", md)
        self.assertIn("| `Views/Chat` | 2 |", md)
        self.assertIn("| `Views/Settings` | 1 |", md)
        self.assertIn("WelcomeView.swift:2 (+1 more site(s))", md)
        self.assertIn("MediaSettingsView.swift:3", md)

    def test_markdown_for_a_clean_catalog(self) -> None:
        md = REPORT.render_markdown({}, self.locales, total_referenced=5, repo_root=self.tmp, max_keys_per_surface=0)
        self.assertIn("All 5 referenced catalog keys have a usable translation", md)

    def test_annotations_are_capped_and_point_at_source(self) -> None:
        findings = self.findings()
        annotations = REPORT.render_annotations(findings, self.tmp, limit=2)
        self.assertEqual(len(annotations), 2)
        self.assertTrue(all(a.startswith("::warning file=") for a in annotations))
        # Largest surface first (Views/Chat), keys alphabetically.
        self.assertIn("WelcomeView.swift,line=2", annotations[0])
        self.assertIn("'Image generation model'", annotations[0])

    def test_cli_exits_zero_and_appends_summary(self) -> None:
        catalog_path = self.tmp / "Localizable.xcstrings"
        catalog_path.write_text(json.dumps(self.catalog), encoding="utf-8")
        summary = self.tmp / "summary.md"
        result = subprocess.run(
            [
                sys.executable,
                str(HERE / "report-untranslated-referenced.py"),
                "--catalog",
                str(catalog_path),
                "--swift-root",
                str(self.swift_root),
                "--summary",
                str(summary),
                "--annotations",
                "1",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 referenced key(s) fall back to English", result.stdout)
        self.assertEqual(result.stdout.count("::warning"), 1)
        self.assertIn("## Untranslated UI strings referenced from Swift", summary.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
