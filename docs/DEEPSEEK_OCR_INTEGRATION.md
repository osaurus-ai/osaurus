# DeepSeek-OCR / Unlimited-OCR osaurus integration (WIP)

Tracks osaurus-side support for the DeepSeek-OCR family (DeepseekOCRForCausalLM,
`model_type: deepseek_vl_v2`) — `deepseek-ai/DeepSeek-OCR` + `baidu/Unlimited-OCR`.

The engine work lives in vmlx-swift PR #89 (the SAM+CLIP DeepEncoder + DeepSeek-V2
MoE decoder + tiling processor). osaurus's VLM detection reads vmlx's
`VLMModelFactory.supportedModelTypes`, so once vmlx registers `deepseek_vl_v2`
the model is recognized as a VLM automatically.

osaurus changes in this PR (land when the vmlx model is functional + merged):
- [ ] repin vmlx to the commit that adds DeepseekOCR (Package.swift + Package.resolved x3)
- [ ] ModelFamilyNames: display name + (if needed) isDeepseekOCR family helper
- [ ] media capabilities: image input for the OCR family
- [ ] live-prove OCR end-to-end on the dev app (read back a known test image),
      watch for incoherence/looping/leaking; RAM-safe (ram_feasibility gated)

Status: blocked on vmlx PR #89 reaching a functional, behaviorally-verified state
(Swift port reproduces mlx-vlm's OCR output on a test image).
