#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def read(rel):
    return (root / rel).read_text()

chat = read("Packages/OsaurusCore/Views/Chat/ChatView.swift")
floating = read("Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift")
picker = read("Packages/OsaurusCore/Models/Configuration/ModelPickerItem.swift")

checks = [
    ("ModelPickerItem carries image capabilities", "let imageCapabilities: ImageModelCapabilities?" in picker),
    ("ModelPickerItem carries image kind", "let imageKind: String?" in picker),
    ("ModelPickerItem carries image defaults", "let imageDefaultSteps: Int?" in picker and "let imageDefaultGuidance: Float?" in picker),
    ("Chat session owns image composer settings", "@Published var imageComposerSettings" in chat),
    ("Chat sends image generation options", "ImageGenerationParameters(" in chat and "negativePrompt: settings.normalizedNegativePrompt" in chat),
    ("Chat sends image edit options", "ImageEditParameters(" in chat and "sourceImages: sourceImages" in chat and "strength: settings.clampedStrength" in chat),
    ("Floating input accepts image settings binding", "@Binding var imageComposerSettings: ImageComposerSettings" in floating),
    ("Floating input shows image controls", "private var imageComposerControls" in floating),
    ("Floating input passes negative prompt", "private var negativePrompt: Binding<String>" in floating and "imageComposerSettings.negativePrompt" in floating),
    ("Floating input exposes steps and guidance", "imageComposerSettings.steps" in floating and "imageComposerSettings.guidance" in floating),
]

failed = [name for name, ok in checks if not ok]
if failed:
    for name in failed:
        print(f"FAIL: {name}", file=sys.stderr)
    sys.exit(1)

print("image UI wiring source contract passed")
PY
