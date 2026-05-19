# PR 1147 Old-Library Active-Path Sweep

Timestamp: 2026-05-18 17:28 PDT

Scope: active Osaurus inference/package/user-visible library references after
the switch to consolidated `vmlx-swift`.

## Commands

```sh
sed -n '1,220p' Packages/OsaurusCore/Package.swift
rg -n 'vmlx-swift-lm|swift-transformers|github.com/ml-explore/mlx-swift|github.com/huggingface/swift-transformers|from: "Jinja"|product\(name: "Jinja"|product\(name: "Tokenizers"' \
  . --glob '!Packages/OsaurusCore/.build/**' \
    --glob '!docs/internal/live-gates/pr1147/**' \
    --glob '!**/*.body' \
    --glob '!**/*.request.json'
rg -n '^import (Jinja|Tokenizers|MLX|MLXLLM|MLXVLM|MLXLMCommon|VMLXJinja|VMLXTokenizers|Transformers|Hub|Generation|Models|EventSource|HuggingFace)\b' \
  Packages/OsaurusCore --glob '!Packages/OsaurusCore/.build/**'
python3 scripts/release/generate_acknowledgements.py
python3 -m json.tool App/osaurus/Acknowledgements.json >/dev/null
```

## Findings

| Surface | Finding | Status |
|---|---|---|
| `Packages/OsaurusCore/Package.swift` | Direct inference dependency is `https://github.com/osaurus-ai/vmlx-swift` at `0b85cad0a9d22d69ddeb787d7695b796fd00275b`. Products are `MLX`, `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `VMLXTokenizers`, and test-only `VMLXJinja`, all from `vmlx-swift`. | PASS |
| Direct old package pins | No direct `vmlx-swift-lm`, `mlx-swift`, standalone `Jinja`, or standalone `swift-transformers` pin in `Packages/OsaurusCore/Package.swift`. | PASS |
| Active Swift imports | Runtime imports are consolidated module products (`MLX`, `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `VMLXTokenizers`). Test imports use `VMLXJinja`. No active source imports standalone `Jinja` or `Tokenizers`. | PASS |
| Transitive resolver entries | Workspace resolved files still contain `swift-transformers` from non-inference transitive dependencies such as VecturaKit / swift-embeddings. This is documented as non-inference transitive graph, not an active local inference root. | PARTIAL / expected |
| Historical docs and old PR notes | Older docs still mention `vmlx-swift-lm` as historical provenance. They are not current runtime instructions, but they remain searchable old-context text. | PARTIAL / historical |
| Acknowledgements generated JSON | Pre-sweep generated `App/osaurus/Acknowledgements.json` still listed `mlx-swift-lm` and `mlx-swift` even though the resolved graph no longer includes them. The generator also resolved project root as `scripts/` instead of repo root. | FIXED IN WORKTREE |
| Acknowledgements fallback | `AcknowledgementsView` fallback named `mlx-swift`. It now names `vmlx-swift` instead. | FIXED IN WORKTREE |

## Fixes Landed In Worktree

- `scripts/release/generate_acknowledgements.py` now resolves the repository
  root from `scripts/release/` with `script_dir.parent.parent`.
- `scripts/release/generate_acknowledgements.py` knows `vmlx-swift` as the
  consolidated MIT-licensed runtime package.
- `App/osaurus/Acknowledgements.json` was regenerated from the actual
  `Package.resolved` graph. It now includes `vmlx-swift` and no longer includes
  `mlx-swift-lm` or `mlx-swift`.
- `AcknowledgementsView` fallback now names `vmlx-swift` rather than
  `mlx-swift`.
- `RuntimePolicySourceTests.swift` now asserts that the generated
  acknowledgements, fallback acknowledgements, and generator do not reintroduce
  `mlx-swift-lm` or a standalone `mlx-swift` identity.

## Remaining Boundary

This sweep closes only the active package/import/user-visible acknowledgement
cleanup. It does not close live model production rows. Final old-library sweep
must be rerun after the remaining model fixes, because late UI/runtime changes
could still reintroduce invalid imports, CLI flags, or historical package
instructions.
