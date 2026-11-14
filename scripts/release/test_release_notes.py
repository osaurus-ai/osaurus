import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location("release_notes", Path(__file__).with_name("release_notes.py"))
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_exact_target_is_selected_across_pages_and_unrelated_drafts_are_preserved(self):
        pages = [[{"tag_name": "future", "draft": True, "body": "wrong"}],
                 [{"tag_name": "1.0.99", "draft": True, "body": "target notes"}]]
        with patch.object(notes, "api", return_value=pages) as api:
            self.assertEqual(notes.release_notes("org/repo", "1.0.99", "a" * 40), "target notes")
        self.assertEqual(api.call_count, 1)
        self.assertEqual(api.call_args.args,
                         ("/repos/org/repo/releases?per_page=100", "--paginate", "--slurp"))

    def test_published_target_notes_are_retained_for_an_artifact_retry(self):
        with patch.object(notes, "api", return_value=[[{"tag_name": "1.0.99", "draft": False,
                                                       "body": "maintainer-edited notes"}]]):
            self.assertEqual(notes.release_notes("org/repo", "1.0.99", "a" * 40),
                             "maintainer-edited notes")

    def test_missing_target_generates_notes_for_exact_commit(self):
        with patch.object(notes, "api", side_effect=[[[{"tag_name": "next", "body": "wrong"}]],
                                                     {"body": "commit-bound notes"}]) as api:
            self.assertEqual(notes.release_notes("org/repo", "1.0.99", "b" * 40, tags=lambda: []), "commit-bound notes")
        self.assertEqual(api.call_args.args, ("--method", "POST", "/repos/org/repo/releases/generate-notes",
                                             "-f", "tag_name=1.0.99", "-f", "target_commitish=" + "b" * 40))

    def test_api_failure_does_not_delete_drafts_or_invent_notes(self):
        with patch.object(notes, "api", side_effect=subprocess.CalledProcessError(1, "gh")) as api:
            with self.assertRaises(subprocess.CalledProcessError):
                notes.release_notes("org/repo", "1.0.99", "a" * 40)
        self.assertEqual(api.call_count, 1)

    def test_duplicate_matches_and_empty_generated_notes_are_errors(self):
        with patch.object(notes, "api", return_value=[[{"tag_name": "1.0.99"}, {"tag_name": "1.0.99"}]]):
            with self.assertRaises(ValueError):
                notes.release_notes("org/repo", "1.0.99", "a" * 40, tags=lambda: [])
        with patch.object(notes, "api", side_effect=[[], {"body": ""}]):
            with self.assertRaises(ValueError):
                notes.release_notes("org/repo", "1.0.99", "a" * 40, tags=lambda: [])

    def test_classic_notes_compare_against_the_previous_classic_tag_and_open_with_the_notice(self):
        tags = ["0.25.33", "1.0.0", "1.0.1"]
        with patch.object(notes, "api", side_effect=[[], {"body": "- Fix a crash"}]) as api:
            body = notes.release_notes("org/repo", "0.25.34", "c" * 40, tags=lambda: tags)
        self.assertEqual(api.call_args.args[-2:], ("-f", "previous_tag_name=0.25.33"))
        self.assertEqual(body, notes.CLASSIC_NOTICE + "\n\n- Fix a crash")

    def test_main_notes_after_a_classic_patch_compare_against_the_previous_main_tag(self):
        with patch.object(notes, "api", side_effect=[[], {"body": "- New feature"}]) as api:
            body = notes.release_notes("org/repo", "1.0.1", "c" * 40, tags=lambda: ["1.0.0", "0.25.34"])
        self.assertEqual(api.call_args.args[-2:], ("-f", "previous_tag_name=1.0.0"))
        self.assertEqual(body, "- New feature")

    def test_hand_written_classic_notes_keep_a_single_notice(self):
        written = notes.CLASSIC_NOTICE + "\n\n- Hand-written fix"
        with patch.object(notes, "api", return_value=[[{"tag_name": "0.25.34", "body": written}]]):
            self.assertEqual(notes.release_notes("org/repo", "0.25.34", "a" * 40), written)
        with patch.object(notes, "api", return_value=[[{"tag_name": "0.25.34", "body": "- Hand-written fix"}]]):
            self.assertEqual(notes.release_notes("org/repo", "0.25.34", "a" * 40), written)

    def test_output_preserves_multiline_body_and_existing_outputs(self):
        body = "# Changes\nEOF\nchangelog=not-an-output\n🦖\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "output"
            path.write_text("existing=value\n")
            notes.write_output(path, body)
            text = path.read_text()
        self.assertTrue(text.startswith("existing=value\nchangelog<<OSAURUS_CHANGELOG_"))
        header, payload = text.split("\n", 2)[1:]
        delimiter = header.split("<<", 1)[1]
        self.assertEqual(payload, body + "\n" + delimiter + "\n")


    def test_shell_entrypoint_reads_exact_notes_without_mutating_drafts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            gh = binary / "gh"
            gh.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['MOCK_CALLS'], 'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
args=sys.argv[1:]
if '--jq' in args:
    print('unrelated draft' if '[0].body' in args[args.index('--jq')+1] else '1001')
elif 'DELETE' not in args:
    print(json.dumps([[{'id':1001,'tag_name':'future','draft':True,'body':'unrelated draft'}, {'id':1002,'tag_name':'0.25.99','draft':True,'body':'intended tag notes'}]]))
""")
            gh.chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                       GH_TOKEN="fixture-only", GITHUB_REPOSITORY="fixture/repo", VERSION="0.25.99",
                       GITHUB_SHA="a" * 40, GITHUB_OUTPUT=str(root / "output"), MOCK_CALLS=str(root / "calls"))
            subprocess.run(["bash", str(Path(__file__).with_name("get_release_notes.sh"))],
                           cwd=root, env=env, check=True, capture_output=True, text=True)
            output = (root / "output").read_text()
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
        self.assertIn("intended tag notes", output)
        self.assertNotIn("unrelated draft", output)
        self.assertEqual(len(calls), 1)
        self.assertTrue(all("DELETE" not in call and "release" not in call for call in calls))

    def create_release_calls(self, version):
        script = Path(__file__).parents[1] / "build" / "create_release.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            (binary / "git").write_text("#!/bin/sh\nexit 0\n")
            (binary / "git").chmod(0o755)
            (binary / "gh").write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['MOCK_CALLS'],'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
sys.exit(1 if sys.argv[1:3] == ['release', 'view'] else 0)
""")
            (binary / "gh").chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                       GH_TOKEN="fixture-only", PUBLIC_REPO="fixture/repo", VERSION=version,
                       IS_BETA="true" if "-beta." in version else "false", MOCK_CALLS=str(root / "calls"))
            subprocess.run(["bash", str(script)], cwd=root, env=env, check=True, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
        return next(call for call in calls if call[:2] == ["release", "create"])

    def test_classic_release_never_takes_latest_or_the_unversioned_dmg(self):
        create = self.create_release_calls("0.25.34")
        self.assertIn("--latest=false", create)
        self.assertNotIn("--latest", create)
        self.assertEqual(create[create.index("--title") + 1], "Osaurus Classic 0.25.34")
        self.assertIn("build_output/Osaurus-0.25.34.dmg", create)
        self.assertNotIn("build_output/Osaurus.dmg", create)

    def test_main_stable_release_takes_latest_and_the_unversioned_dmg(self):
        create = self.create_release_calls("1.0.0")
        self.assertIn("--latest", create)
        self.assertEqual(create[create.index("--title") + 1], "Osaurus 1.0.0")
        self.assertIn("build_output/Osaurus.dmg", create)
        beta = self.create_release_calls("1.1.0-beta.1")
        self.assertIn("--prerelease", beta)
        self.assertIn("--latest=false", beta)

    def test_workflow_gates_lane_specific_jobs_on_the_resolved_lane(self):
        text = (Path(__file__).parents[2] / ".github" / "workflows" / "build-and-release.yml").read_text()
        self.assertIn("python3 scripts/release/release_lane.py export", text)
        full = text.split("  build_full:", 1)[1].split("    steps:", 1)[0]
        self.assertIn("needs.build.outputs.builds_full_dmg == 'true'", full)
        released = text.split("  mark_released:", 1)[1].split("    steps:", 1)[0]
        self.assertIn("needs.build.outputs.lane == 'main'", released)
        self.assertNotIn("updates/appcast.xml", text)

    def test_retained_target_draft_is_published_by_existing_release_path(self):
        script = Path(__file__).parents[1] / "build" / "create_release.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            (binary / "git").write_text("#!/bin/sh\nexit 0\n")
            (binary / "git").chmod(0o755)
            (binary / "gh").write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['MOCK_CALLS'],'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
""")
            (binary / "gh").chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                       GH_TOKEN="fixture-only", GITHUB_REPOSITORY="fixture/repo", PUBLIC_REPO="fixture/repo",
                       VERSION="0.25.99", IS_BETA="false", MOCK_CALLS=str(root / "calls"))
            subprocess.run(["bash", str(script)], cwd=root, env=env, check=True, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
        edit = next(call for call in calls if call[:2] == ["release", "edit"])
        self.assertIn("--draft=false", edit)
        self.assertIn("--notes-file", edit)
        self.assertFalse(any("delete" in call for call in calls))


    def test_workflow_writes_notes_as_data_including_heredoc_markers(self):
        workflow = Path(__file__).parents[2] / ".github" / "workflows" / "build-and-release.yml"
        text = workflow.read_text()
        step = text.split("- name: Write Release Notes", 1)[1].split("- name: Create Release", 1)[0]
        self.assertIn("RELEASE_NOTES_BODY: ${{ steps.changelog.outputs.changelog }}", step)
        command = step.split("run: ", 1)[1].strip()
        self.assertNotIn("${{", command)
        body = "# Notes\nCHANGELOG_EOF\ntouch UNEXPECTED_EXECUTION\n🦖"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["bash", "-c", command], cwd=root,
                           env=dict(os.environ, RELEASE_NOTES_BODY=body), check=True)
            self.assertEqual((root / "RELEASE_NOTES.md").read_text(), body + "\n")
            self.assertFalse((root / "UNEXPECTED_EXECUTION").exists())


if __name__ == "__main__":
    unittest.main()
