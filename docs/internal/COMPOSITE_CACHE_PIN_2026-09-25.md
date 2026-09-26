# Composite and recurrent cache boundary pin

Consume engine2f973dc63d14eaf85adfcb99ce76e4f60f9068a6 (vmlx-swift#517). It validates composite leaf offsets, restores all-recurrent boundary counts, routes nested typed state to disk restoration, and advances Falcon-H1 recurrent offsets. Engine proof: Release build and23/23 targeted tests, including tiny production Falcon-H1 safetensors roundtrip and continuation-logit parity. No pretrained Falcon quality or speed claim.

This pin also includes intervening main changes: Linux portability/CI, CPU embedder precision selection, and KDA short-convolution decode. App source proof must name the new pin; prior app6827ef11 receipts do not prove this dependency update. No sampler/quantization defaults are changed here.

Status: app build, native UI and affected local full-eval proof PENDING. Prior completed UI/file fixes2893/2894 are preserved. No release or tag. Evidence will be recorded under /Users/eric/vmlx-private-evidence/required-followups-2026-09-25/cache-pin.
