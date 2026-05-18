# PR 1147 Live Sequence Probe

Model: `zaya1-vl-8b-mxfp4`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_image_text | /v1/chat/completions | 200 | 369 | The image features a blue square with a black shadow. |
| t1_image_text | /v1/responses | 200 | 421 | The image predominantly features blue, with no additional colors present. |
| t2_text_only | /v1/chat/completions | 200 | 414 | The blue square, contrasting against the black shadow, is the most dominant element in this image. |
| t2_text_only | /v1/responses | 200 | 490 | The image appears to be a plain blue background with no visible objects or text, suggesting it might be a placeholder or an ungenerated image. |
| t4_repeat_image | /v1/chat/completions | 200 | 393 | A blue square with a black shadow is the main and only element in the image. |
| t4_repeat_image | /v1/responses | 200 | 428 | The image is a blue rectangle without any distinguishable features or content. |
