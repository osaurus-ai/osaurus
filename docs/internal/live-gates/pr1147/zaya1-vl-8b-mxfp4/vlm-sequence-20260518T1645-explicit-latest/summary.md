# PR 1147 Live Sequence Probe

Model: `zaya1-vl-8b-mxfp4`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_image_text | /v1/chat/completions | 200 | 388 | The image features a vibrant red square as its dominant color and shape. |
| t1_image_text | /v1/responses | 200 | 385 | A giant red donut dominates the image. |
| t2_text_only | /v1/chat/completions | 200 | 452 | In the image, a red square with a unique feature - a small blue dot in the top left corner - is surrounded by an intriguing blue border. |
| t2_text_only | /v1/responses | 200 | 500 | The red color of the tomato-like fruit stands out against the pale green background, drawing the viewer's attention to its unique shape and vibrant hue. |
| t3_different_image | /v1/chat/completions | 200 | 397 | The image features a dominant blue triangle shape with a red square background. |
| t3_different_image | /v1/responses | 200 | 432 | The image displays a blue rectangle with a unique red stripe diagonally across it. |
| t4_repeat_image | /v1/chat/completions | 200 | 395 | A red square with a blue circle in the upper left corner dominates the image. |
| t4_repeat_image | /v1/responses | 200 | 416 | A red square dominates the image, with a blue rectangle inside it. |
