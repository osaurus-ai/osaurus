# PR 1147 Live Sequence Probe

Model: `zaya1-vl-8b-mxfp4`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_image_text | /v1/chat/completions | 200 | 489 | The image displays a vibrant red rectangle against a stark white background, devoid of any additional elements or text, creating a minimalist and visually strik |
| t1_image_text | /v1/responses | 200 | 501 | The media are the people and technology that tell us about the world through stories, pictures, and news so we can understand what's happening around us. |
| t2_text_only | /v1/chat/completions | 200 | 438 | In the image, the red rectangle stands out distinctly against the white background, indicating a clean, minimalist design. |
| t2_text_only | /v1/responses | 400 | 92 |  |
| t3_different_image | /v1/chat/completions | 200 | 370 | The red rectangle is set against a white background. |
| t3_different_image | /v1/responses | 400 | 92 |  |
| t4_repeat_image | /v1/chat/completions | 200 | 377 | The image shows a red rectangle against a white background. |
| t4_repeat_image | /v1/responses | 400 | 92 |  |
| t5_video | /v1/chat/completions | 500 | 126 |  |
| t5_video | /v1/responses | 400 | 92 |  |
