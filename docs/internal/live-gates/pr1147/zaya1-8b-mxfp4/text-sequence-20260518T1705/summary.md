# PR 1147 Live Sequence Probe

Model: `zaya1-8b-mxfp4`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_text | /v1/chat/completions | 200 | 325 | 2+2 equals 4. |
| t1_text | /v1/responses | 200 | 357 | 2+2 equals 4. |
| t2_text | /v1/chat/completions | 200 | 321 | 2+2 is 4. |
| t2_text | /v1/responses | 200 | 353 | 2+2 is 4. |
| t3_text | /v1/chat/completions | 200 | 533 | Certainly! Here is the requested UTF-8 string: café 東京 🚀. Note that I will not add any extra characters or whitespace beyond what was requested. If there is any |
| t3_text | /v1/responses | 200 | 507 | 《咖蓝》》📅    (Note: This is a direct representation of the requested UTF-8 string "カフェ東京 🚀" without any additional formatting or text.) |
