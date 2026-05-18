#!/usr/bin/env python3
"""Unit tests for the PR 1147 live sequence probe helpers."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


def load_probe_module():
    root = Path(__file__).resolve().parents[1]
    path = root / "pr1147_live_sequence_probe.py"
    spec = importlib.util.spec_from_file_location("pr1147_live_sequence_probe", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LiveSequenceProbeTests(unittest.TestCase):
    def test_vlm_turn_plan_preserves_media_boundaries(self) -> None:
        probe = load_probe_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image_a = root / "a.png"
            image_b = root / "b.png"
            video = root / "clip.mp4"
            image_a.write_bytes(b"\x89PNG\r\n\x1a\nimage-a")
            image_b.write_bytes(b"\x89PNG\r\n\x1a\nimage-b")
            video.write_bytes(b"\x00\x00\x00\x18ftypmp42video")

            turns = probe.build_vlm_turn_plan(
                image=image_a,
                different_image=image_b,
                video=video,
                prompt="what color is this?",
            )

            self.assertEqual(
                [turn["label"] for turn in turns],
                [
                    "t1_image_text",
                    "t2_text_only",
                    "t3_different_image",
                    "t4_repeat_image",
                    "t5_video",
                ],
            )
            self.assertEqual([part["kind"] for part in turns[0]["media"]], ["image"])
            self.assertEqual(turns[1]["media"], [])
            self.assertEqual(turns[2]["media"][0]["path"], str(image_b.resolve()))
            self.assertEqual(turns[3]["media"][0]["path"], str(image_a.resolve()))
            self.assertEqual(turns[4]["media"][0]["kind"], "video")

    def test_request_bodies_use_chat_and_responses_media_shapes(self) -> None:
        probe = load_probe_module()
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "a.png"
            image.write_bytes(b"\x89PNG\r\n\x1a\nimage-a")
            turn = probe.build_vlm_turn_plan(image=image, prompt="describe")[0]

            chat = probe.chat_request_body(
                model="qwen-test",
                messages=[],
                turn=turn,
                stream=False,
                max_tokens=64,
            )
            chat_content = chat["messages"][0]["content"]
            self.assertEqual(chat["stream"], False)
            self.assertEqual(chat["max_tokens"], 64)
            self.assertEqual(chat_content[0], {"type": "text", "text": "describe"})
            self.assertEqual(chat_content[1]["type"], "image_url")
            self.assertTrue(chat_content[1]["image_url"]["url"].startswith("data:image/png;base64,"))

            responses = probe.responses_request_body(
                model="qwen-test",
                messages=[],
                turn=turn,
                stream=True,
                max_tokens=64,
            )
            response_content = responses["input"][0]["content"]
            self.assertEqual(responses["stream"], True)
            self.assertEqual(responses["max_output_tokens"], 64)
            self.assertEqual(response_content[0], {"type": "input_text", "text": "describe"})
            self.assertEqual(response_content[1]["type"], "input_image")
            self.assertTrue(response_content[1]["image_url"].startswith("data:image/png;base64,"))

    def test_ps_line_parser_handles_paths_with_spaces(self) -> None:
        probe = load_probe_module()
        row = probe.parse_ps_line(
            "19315     1 132688 /Applications/vMLX.app/Contents/MacOS/vMLX"
        )
        self.assertEqual(row["pid"], 19315)
        self.assertEqual(row["ppid"], 1)
        self.assertEqual(row["rss_kb"], 132688)
        self.assertEqual(row["command"], "/Applications/vMLX.app/Contents/MacOS/vMLX")

    def test_responses_history_keeps_responses_media_shape(self) -> None:
        probe = load_probe_module()
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "a.png"
            image.write_bytes(b"\x89PNG\r\n\x1a\nimage-a")
            turn = probe.build_vlm_turn_plan(image=image, prompt="describe")[0]

            message = probe.user_history_message("responses", turn)
            content = message["content"]
            self.assertEqual(content[0]["type"], "input_text")
            self.assertEqual(content[1]["type"], "input_image")
            self.assertNotIn("image_url", content[1].get("type", ""))


if __name__ == "__main__":
    unittest.main()
