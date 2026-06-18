# Osaurus Image API live proof - 2026-06-18

Branch:

```text
feat/image-generation-vmlxflux
06920034f79273b5cbbf973e908d959a4ac947cd
```

vMLX pin:

```text
d725c63f035650f9182648580e98d7776544648a
```

Host:

```text
erics-m5-max.local
Erics-M5-Max.lan
hw.memsize=137438953472
```

Build:

```text
/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/build/DerivedData-image-live-nosign/Build/Products/Release/osaurus.app
scripts/live-proof/build-keychain-free-osaurus.sh /tmp/osaurus-image-live-proof-20260618-osaurus-image-live/build/DerivedData-image-live-nosign
```

Runtime:

```text
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1
OSAURUS_TEST_ROOT=/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/runtime-root
OSU_MODELS_DIR=/Users/eric/.mlxstudio/models
http://127.0.0.1:17837
```

Artifacts:

```text
/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/runtime-root/proof/api-matrix/summary.json
/tmp/osaurus-image-live-proof-20260618-osaurus-image-live/runtime-root/generated-images/
/tmp/osaurus-image-live-proof-20260618-local/osaurus-image-api-contact-sheet.png
```

Rows:

| Row | Endpoint | Result | Elapsed | App RSS |
| --- | --- | --- | --- | --- |
| `zimage_gen` | `/v1/images/generations` | HTTP 200 | 5s | 6,055,870,464 bytes |
| `flux_gen` | `/v1/images/generations` | HTTP 200 | 4s | 15,451,013,120 bytes |
| `qwen_image_gen` | `/v1/images/generations` | HTTP 200 | 12s | 44,091,604,992 bytes |
| `ideogram_gen` | `/v1/images/generations` | HTTP 200 | 72s | 6,914,867,200 bytes |
| `qwen_edit_q8_single` | `/v1/images/edits` | HTTP 200 | 32s | 24,291,950,592 bytes |
| `qwen_edit_q8_multi` | `/v1/images/edits` | HTTP 200 | 52s | 22,411,886,592 bytes |
| `gen_only_edit_reject` | `/v1/images/edits` | HTTP 400 | 1s | 22,410,641,408 bytes |
| `qwen_edit_mask_reject` | `/v1/images/edits` | HTTP 501 | 0s | 22,411,968,512 bytes |

Post-run health:

```text
status=healthy
http_inflight=0
loaded=[]
local_model_scan.status=finished
```

Visual notes:

- Z-Image Turbo, Flux Schnell, Qwen Image, and Qwen Image Edit q8 rows produced valid visible PNGs.
- Qwen edit q8 single preserved the source apple scene and changed it into a translucent green glass apple.
- Qwen edit q8 multi produced a combined apple and teapot scene.
- Ideogram generated a poster-like image but still has the known text/poster artifact; treat as API-live with quality caveat, not production-clean text rendering.

Remaining gates:

- Foreground SwiftUI chat workflow.
- HTTP cancellation while denoise is in flight.
- Unload/reload/generate-again behavior.
