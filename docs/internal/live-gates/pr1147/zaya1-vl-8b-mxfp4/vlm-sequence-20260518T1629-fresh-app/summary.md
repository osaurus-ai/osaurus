# PR 1147 Live Sequence Probe

Model: `zaya1-vl-8b-mxfp4`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_image_text | /v1/chat/completions | 200 | 346 | Red square dominates the image. |
| t1_image_text | /v1/responses | 200 | 441 | The image features a striking red circle at the center, set against a stark white background. |
| t2_text_only | /v1/chat/completions | 200 | 408 | The red square stands out against the background of the image, creating a striking contrast. |
| t2_text_only | /v1/responses | 200 | 599 | The red circle appears to be partially obscured by a shadow or possibly an overlay of some kind of overlay, which might be obscuring it or adding depth to the i |
| t3_different_image | /v1/chat/completions | 200 | 376 | The red square is the dominant color and shape in the image. |
| t3_different_image | /v1/responses | 200 | 434 | The image features a red circle at the center, set against a stark white background. |
| t4_repeat_image | /v1/chat/completions | 200 | 364 | A red square is the only element in the image. |
| t4_repeat_image | /v1/responses | 200 | 413 | A red circle on a white background, with a blue bar at the top. |
