# PR 1147 Live Sequence Probe

Model: `nemotron-omni-nano-mxfp4-crack`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_text | /v1/chat/completions | 200 | 343 |  2+2 equals 4. |
| t1_text | /v1/responses | 200 | 375 |  2+2 equals 4. |
| t2_text | /v1/chat/completions | 200 | 341 | 2+2 equals 4. |
| t2_text | /v1/responses | 200 | 373 | 2+2 equals 4. |
| t3_text | /v1/chat/completions | 200 | 347 |  café 東京 🚀 |
| t3_text | /v1/responses | 200 | 379 |  café 東京 🚀 |
