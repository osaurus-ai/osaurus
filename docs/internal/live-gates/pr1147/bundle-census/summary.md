# PR 1147 Bundle Census

This is file-level evidence only. It does not prove runtime coherency,
cache hits, UI defaults, HTTP behavior, or parser separation.

| Label | Exists | VLM evidence | MTP auto-enable | MTP reason | Generation defaults |
|---|---:|---|---:|---|---|
| JANGQ/DeepSeek-V4-Flash-JANGTQ-K | true | none | false | no native MTP evidence | eos_token_id=[1, 128803], temperature=1.0, top_p=1.0 |
| JANGQ/DeepSeek-V4-Flash-JANGTQ2 | true | none | false | mtp tensors exist but tuning is missing or not validated | eos_token_id=[1, 128803], temperature=1.0, top_p=1.0 |
| JANGQ/Qwen3.6-27B-JANG_4M-MTP | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | true | real mtp tensors plus validated vmlx_mtp_tuning.json | eos_token_id=[248046, 248046], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| JANGQ/Qwen3.6-27B-MXFP4-MTP | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | true | real mtp tensors plus validated vmlx_mtp_tuning.json | eos_token_id=[248046], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| JANGQ/Qwen3.6-27B-MXFP8-MTP | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | true | real mtp tensors plus validated vmlx_mtp_tuning.json | eos_token_id=[248046, 248044], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | true | real mtp tensors plus validated vmlx_mtp_tuning.json | eos_token_id=[248046, 248044], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| JANGQ/Qwen3.6-35B-A3B-MXFP8-MTP | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | true | real mtp tensors plus validated vmlx_mtp_tuning.json | eos_token_id=[248046, 248044], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| JANGQ/Qwen3.6-35B-A3B-JANG_2K-MTP | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | false | vmlx_mtp_tuning.json blocks native MTP | eos_token_id=[248046, 248046], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| dealign.ai/Qwen3.6-27B-JANG_4M-CRACK | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | false | no native MTP evidence | eos_token_id=[248046, 248046], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| dealign.ai/Qwen3.6-27B-MXFP4-CRACK | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | false | no native MTP evidence | eos_token_id=[248046, 248044], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK | true | vision_config, image_tokens, video_tokens, preprocessor, video_preprocessor | false | no native MTP evidence | eos_token_id=[248046, 248044], pad_token_id=248044, temperature=1.0, top_k=20, top_p=0.95 |
| dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK | true | vision_config, image_tokens, video_tokens | false | no native MTP evidence | eos_token_id=[1, 106, 50], pad_token_id=0, temperature=1.0, top_k=64, top_p=0.95 |
| mlx-community/gemma-3n-E2B-it-4bit | true | vision_config, audio_config, image_tokens, preprocessor | false | no native MTP evidence | eos_token_id=[1, 106], pad_token_id=0, top_k=64, top_p=0.95 |
| JANGQ/ZAYA1-8B-JANGTQ4 | true | none | false | no native MTP evidence | eos_token_id=106, pad_token_id=0 |
| JANGQ/ZAYA1-8B-JANGTQ_K | true | none | false | no native MTP evidence | eos_token_id=1, pad_token_id=0 |
| JANGQ/ZAYA1-VL-8B-JANGTQ4 | true | vision_config, image_tokens, preprocessor | false | no native MTP evidence | eos_token_id=262143, pad_token_id=0 |
| JANGQ/ZAYA1-VL-8B-JANGTQ_K | true | vision_config, image_tokens, preprocessor | false | no native MTP evidence | eos_token_id=262143, pad_token_id=0 |
| Osaurus/ZAYA1-8B-MXFP4 | true | none | false | no native MTP evidence | eos_token_id=106, pad_token_id=0 |
| Osaurus/ZAYA1-VL-8B-MXFP4 | true | vision_config, image_tokens, preprocessor | false | no native MTP evidence | eos_token_id=262143, pad_token_id=0 |
| dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK | true | preprocessor | false | no native MTP evidence | eos_token_id=[2, 11], max_new_tokens=16384, pad_token_id=0, repetition_penalty=1.0, temperature=0.6, top_p=0.95 |
| dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK | true | preprocessor | false | no native MTP evidence | eos_token_id=[2, 11], max_new_tokens=16384, pad_token_id=0, repetition_penalty=1.0, temperature=0.6, top_p=0.95 |
| dealign.ai/Nemotron-Omni-Nano-MXFP4-CRACK | true | preprocessor | false | no native MTP evidence | eos_token_id=[2, 11], max_new_tokens=16384, pad_token_id=0, repetition_penalty=1.0, temperature=0.6, top_p=0.95 |
| dealign.ai/MiniMax-M2.7-JANGTQ_K-CRACK | true | none | false | no native MTP evidence | eos_token_id=200020, temperature=1.0, top_k=40, top_p=0.95 |
| dealign.ai/MiniMax-M2.7-JANG_K-CRACK | true | none | false | no native MTP evidence | eos_token_id=200020, temperature=1.0, top_k=40, top_p=0.95 |
| JANGQ/MiniMax-M2.7-Small-JANGTQ | true | none | false | no native MTP evidence | eos_token_id=200020, temperature=1.0, top_k=40, top_p=0.95 |
| dealign.ai/Ling-2.6-flash-JANGTQ2-CRACK | true | none | false | no native MTP evidence | eos_token_id=[156892, 156895], pad_token_id=156892 |
| dealign.ai/Ling-2.6-flash-MXFP4-CRACK | true | none | false | no native MTP evidence | eos_token_id=[156892, 156895], pad_token_id=156892 |
| JANGQ/Hy3-preview-JANGTQ | true | none | false | config metadata mentions MTP, but no mtp tensor evidence was found | eos_token_id=120025, pad_token_id=120002, temperature=0.9, top_k=-1, top_p=1 |
| JANGQ/Hy3-preview-JANGTQ_K | true | none | false | config metadata mentions MTP, but no mtp tensor evidence was found | eos_token_id=120025, pad_token_id=120002, temperature=0.9, top_k=-1, top_p=1 |
