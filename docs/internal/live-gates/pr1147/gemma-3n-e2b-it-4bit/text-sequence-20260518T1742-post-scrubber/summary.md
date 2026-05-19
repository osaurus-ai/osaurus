# PR 1147 Live Sequence Probe

Model: `gemma-3n-e2b-it-4bit`
Base URL: `http://127.0.0.1:4242`
Stream: `false`

| Turn | Route | Status | Bytes | Output Tail |
|---|---|---:|---:|---|
| t1_text | /v1/chat/completions | 200 | 329 | 2 + 2 = 4  |
| t1_text | /v1/responses | 200 | 361 | 2 + 2 = 4  |
| t2_text | /v1/chat/completions | 200 | 350 | The sky is a clear blue.     |
| t2_text | /v1/responses | 200 | 382 | The sky is a clear blue.     |
| t3_text | /v1/chat/completions | 200 | 355 | The sky is a clear blue. 🚀     |
| t3_text | /v1/responses | 200 | 611 | Okay, here's a short, silly response including those characters!   **"咯啦啦！ 飞车过家家！ 🌈"**   (Translation: "Clang! Flying car to your house! 🌈")  It's a little rand |
