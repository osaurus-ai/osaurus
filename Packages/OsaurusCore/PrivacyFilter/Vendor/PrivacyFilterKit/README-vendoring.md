# Vendored PrivacyFilterKit

Source: https://github.com/kokluch/privacy-filter-swift
Pinned commit: `2bb396cce542155e1923fff1e08520348f1af1c5`

We vendor instead of adding a SwiftPM dependency because upstream pulls
`ml-explore/mlx-swift` and `huggingface/swift-transformers` directly,
while OsaurusCore already brings both surfaces in through
`osaurus-ai/vmlx-swift` (which vendors the same fork). Two copies in the
same Swift graph would conflict on the `Tokenizers` module name and on
MLX target wiring. Vendoring also lets us pin to a specific commit
without waiting on upstream tagging.

## Rewires applied (search "Osaurus-local rewires" in the source)

| File | Original | Rewired to |
|---|---|---|
| `Tokenizer/Tokenizer.swift` | `import Tokenizers` | `import VMLXTokenizers` |
| `Model/PrivacyFilterModel.swift` | `import MLX` + `import MLXNN` + `import MLXFast`, weights at `weights.safetensors` | `import MLX` only; loads `model.safetensors` first (with `weights.safetensors` fallback) to match `mlx-community/openai-privacy-filter-bf16`. Re-add MLXNN/MLXFast when the real forward pass lands. |
| `Model/ModelLoader.swift` | Reads `id2label.json` + `model_config.json` (upstream split layout) | Reads HF-style `config.json` (which embeds both `id2label` and the arch knobs). Transitions now also accept `viterbi_calibration.json` (the bias-overrides sidecar). |
| `Decoder/Label.swift` + transitive | `Label` / `LabelTable` / `LabelTableError` | `BIOESLabel` / `BIOESLabelTable` / `BIOESLabelTableError` — the original names collide with SwiftUI's generic `Label<Title, Icon>` once they share the OsaurusCore module namespace |

## Local-only additions (not in upstream)

| File | Purpose |
|---|---|
| `Decoder/Calibration.swift` | Parses `viterbi_calibration.json` operating-point biases and applies them on top of the BIOES validity mask. Lets us pick up future tuned operating points without a Swift release. |

The Swift API surface of `VMLXTokenizers.Tokenizer` matches
`Tokenizers.Tokenizer` 1:1 for the methods this kit uses
(`encode(text:)`, `decode(tokens:)`, `AutoTokenizer.from(modelFolder:)`).

## Sync protocol

To pull a newer upstream revision:

```bash
git clone --depth 1 https://github.com/kokluch/privacy-filter-swift /tmp/pfk
cp /tmp/pfk/Sources/PrivacyFilterKit/PrivacyFilterKit.swift \
   Packages/OsaurusCore/PrivacyFilter/Vendor/PrivacyFilterKit/
cp /tmp/pfk/Sources/PrivacyFilterKit/Decoder/*.swift \
   Packages/OsaurusCore/PrivacyFilter/Vendor/PrivacyFilterKit/Decoder/
cp /tmp/pfk/Sources/PrivacyFilterKit/Model/*.swift \
   Packages/OsaurusCore/PrivacyFilter/Vendor/PrivacyFilterKit/Model/
cp /tmp/pfk/Sources/PrivacyFilterKit/Tokenizer/*.swift \
   Packages/OsaurusCore/PrivacyFilter/Vendor/PrivacyFilterKit/Tokenizer/
```

Then re-apply the rewires above (greppable by their header comments)
and update the pinned commit hash at the top of this file plus every
vendored file header.
