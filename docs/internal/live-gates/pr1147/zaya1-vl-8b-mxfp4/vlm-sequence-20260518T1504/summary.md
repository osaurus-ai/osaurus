# PR 1147 Live Sequence Probe

Model: `zaya1-vl-8b-mxfp4`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_image_text | /v1/chat/completions | 200 | 412 | The image presents a plain red rectangle, devoid of any text, graphics, or discernible features. |
| t1_image_text | /v1/responses | 200 | 483 | The media is like a big group of friends who talk and share stories about the world, so we can learn about different things and people. |
| t2_text_only | /v1/chat/completions | 200 | 461 | The image is a solid red rectangle that lacks any text or images, making it appear as a purely abstract form with no specific content or context. |
| t2_text_only | /v1/responses | 200 | 484 | The media is like a big group of friends who talk and share stories about the world, helping us learn about different things and people. |
| t3_different_image | /v1/chat/completions | 200 | 380 | A red rectangle with no text, graphics or discernible features. |
| t3_different_image | /v1/responses | 200 | 486 | The media is like a big group of friends who talk and share stories about the world, helping us learn about different things and people. |
| t4_repeat_image | /v1/chat/completions | 200 | 358 | Solid red rectangle with nothing inside. |
| t4_repeat_image | /v1/responses | 200 | 486 | The media is like a big group of friends who talk and share stories about the world, helping us learn about different things and people. |
| t5_video | /v1/chat/completions | 500 | 126 |  |
| t5_video | /v1/responses | 200 | 486 | The media is like a big group of friends who talk and share stories about the world, helping us learn about different things and people. |
