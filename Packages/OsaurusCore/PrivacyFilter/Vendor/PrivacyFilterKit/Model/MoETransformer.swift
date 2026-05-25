//
//  MoETransformer.swift
//  osaurus / PrivacyFilter (vendored sidecar — local addition)
//
//  Forward pass for the `openai_privacy_filter` architecture
//  (GPT-OSS-style sparse-MoE token classifier) implemented directly
//  against the vendored `MLX` module from vmlx-swift. Mirrors the
//  reference `mlx-embeddings` Python implementation that produced the
//  `mlx-community/openai-privacy-filter-bf16` repo.
//
//  Shape / convention notes (all critical to match the reference at
//  https://github.com/openai/privacy-filter/blob/main/opf/_model/model.py):
//    • Attention: bidirectional (no causal mask). 14 query heads, 2 KV
//      heads (GQA, repeat factor 7), head dim 64.
//    • Attention sinks: each layer carries a learned `sinks` vector of
//      shape [num_heads], stored in log-2 space. They participate in
//      the per-token softmax denominator as an extra logit, after
//      conversion to natural log via `* ln(2)` (see reference
//      `sdpa()`: `sink_scores = S * math.log(2.0)`). Skipping this
//      conversion makes the sinks effectively dominate the softmax
//      denominator and pushes real attention weights toward zero —
//      which is what caused our 196-token outputs to come back all-`O`.
//    • RoPE: theta=150000 with YARN NTK-by-parts scaling. The
//      `concentration = 0.1*ln(scaling_factor) + 1 ≈ 1.347` cos/sin
//      multiplier and the partial-frequency interpolation
//      (`bidirectional_left_context=128/right_context=128`-style
//      band, `original_max_position_embeddings=4096`) materially
//      change rotation even for short inputs, so we precompute the
//      modified `inv_freq` and pass it to `MLXFast.RoPE` via
//      `freqs:`, then multiply Q/K by the concentration scalar.
//    • RoPE rotation style: reference uses interleaved-pair rotation
//      (`x[..., ::2]` / `x[..., 1::2]`) → that's `traditional: true`
//      in MLX terminology. The `false` (LLaMA-half-split) variant
//      we previously used silently produces wrong queries/keys.
//    • Sliding window: trained as a bidirectional banded transformer
//      with `bidirectional_left_context=128`, `right_context=128`
//      (band = 257 incl. self). For inputs ≤ 257 tokens — and we
//      truncate well below that — banded attention is identical to
//      full attention, so we don't apply the mask here.
//    • MoE: 128 stacked experts per layer, top-4 routing. Expert
//      weights are stored as a single stacked tensor per projection
//      with shape `[num_experts, out, in]`. We use mlx's `gatherMM`
//      to select per-token expert weights without materializing a
//      per-expert dispatch loop. Activation is the OpenAI gpt-oss
//      SwiGLU variant: `clamp(gate, max=7) * sigmoid(1.702*gate) *
//      (clamp(up, ±7) + 1)` — not the standard `silu(gate)*up`.
//
//  This file is the only place in the privacy-filter pipeline that
//  knows the GPT-OSS model body. Keep all transformer math here so
//  the rest of the kit (loader, tokenizer, decoder) stays generic.
//

import Darwin
import Foundation
import MLX

/// Multi-layer MoE transformer for token classification. Mutating
/// instance methods are pure functions on `MLXArray`; no internal
/// state outside the loaded parameter dict.
struct MoETransformer {
    // MARK: - Architecture (from `config.json`)

    /// Hard-cap on input tokens we feed through `forward(_:)`. Matches
    /// `initial_context_length` in the config — beyond this YARN
    /// scaling would activate and our vanilla-RoPE path produces
    /// incorrect positional embeddings. Callers are expected to
    /// truncate / chunk to this length before calling.
    static let maxSequenceLength = 4096

    let config: ModelConfig
    let weights: [String: MLXArray]
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let numExperts: Int
    let topK: Int
    let numLabels: Int
    let ropeBase: Float
    let rmsEps: Float

    /// Natural-log conversion factor for the sink scalars stored on
    /// disk in log-2 space. See `attention(...)`.
    let sinkLogScale: Float = Float(Darwin.log(2.0))

    // MARK: - YARN RoPE parameters (from `config.json:rope_parameters`)

    /// `scaling_factor` (HF `factor`): max-context / training-context.
    private let ropeScalingFactor: Float = 32.0
    /// `ntk_alpha`: low-frequency cutoff factor.
    private let ropeNTKAlpha: Float = 1.0
    /// `ntk_beta`: high-frequency cutoff factor.
    private let ropeNTKBeta: Float = 32.0
    /// Training-time context length, before YARN scaling.
    private let ropeInitialContextLength: Float = 4096.0

    /// Pre-computed YARN-modified inverse frequencies of length
    /// `head_dim / 2`. Built once at init and reused for every RoPE
    /// call (positions ride the `offset:` parameter into MLXFast.RoPE).
    private let yarnInvFreq: MLXArray
    /// YARN concentration scalar applied to cos/sin (cos/sin in the
    /// reference are multiplied by this). Since MLX's RoPE doesn't
    /// expose a concentration knob, we equivalently multiply Q and K
    /// by this scalar after RoPE.
    private let yarnConcentration: Float

    /// Cached transposed expert weights. The on-disk layout stores
    /// gate/up/down as `[num_experts, out, in]`; gatherMM wants
    /// `[num_experts, in, out]`, so we transpose once at load and
    /// reuse forever. This avoids per-token transpose ops.
    private let transposedGate: [Int: MLXArray]
    private let transposedUp: [Int: MLXArray]
    private let transposedDown: [Int: MLXArray]

    init(weights: [String: MLXArray], config: ModelConfig) throws {
        self.weights = weights
        self.config = config
        self.hiddenSize = config.hiddenSize
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        // The HF `head_dim` field isn't in our local `ModelConfig`
        // (it's a GPT-OSS-specific knob), so we derive it from the
        // q_proj weight shape: q_proj.weight is [numHeads * headDim, hiddenSize].
        guard let qProj = weights["model.layers.0.self_attn.q_proj.weight"] else {
            throw ModelLoaderError.missingFile("model.layers.0.self_attn.q_proj.weight")
        }
        let qOut = qProj.shape[0]
        self.headDim = qOut / max(self.numHeads, 1)
        self.intermediateSize = Self.deriveIntermediateSize(
            from: weights,
            hiddenSize: config.hiddenSize
        )
        self.numExperts = config.numExperts
        self.topK = config.topK
        self.numLabels = config.numLabels
        self.ropeBase = 150_000
        self.rmsEps = 1e-5

        // Precompute YARN-NTK inv_freq and concentration once. These
        // depend only on architecture constants, never on input.
        let (invFreq, concentration) = Self.computeYarnInvFreq(
            headDim: self.headDim,
            base: self.ropeBase,
            scalingFactor: 32.0,
            initialContextLength: 4096.0,
            ntkAlpha: 1.0,
            ntkBeta: 32.0
        )
        self.yarnInvFreq = invFreq
        self.yarnConcentration = concentration

        // Pre-transpose expert weights for gatherMM. We cache them by
        // layer index so first-forward latency stays low.
        var gateT: [Int: MLXArray] = [:]
        var upT: [Int: MLXArray] = [:]
        var downT: [Int: MLXArray] = [:]
        for layer in 0 ..< config.numLayers {
            if let gw = weights["model.layers.\(layer).mlp.experts.gate_proj.weight"] {
                gateT[layer] = gw.transposed(axes: [0, 2, 1])
            }
            if let uw = weights["model.layers.\(layer).mlp.experts.up_proj.weight"] {
                upT[layer] = uw.transposed(axes: [0, 2, 1])
            }
            if let dw = weights["model.layers.\(layer).mlp.experts.down_proj.weight"] {
                downT[layer] = dw.transposed(axes: [0, 2, 1])
            }
        }
        self.transposedGate = gateT
        self.transposedUp = upT
        self.transposedDown = downT
    }

    private static func deriveIntermediateSize(
        from weights: [String: MLXArray],
        hiddenSize: Int
    ) -> Int {
        // gate_proj.weight is [num_experts, intermediate, hidden].
        if let gw = weights["model.layers.0.mlp.experts.gate_proj.weight"], gw.shape.count == 3 {
            return gw.shape[1]
        }
        // Fall back to config-stated intermediate when shape lookup fails.
        return hiddenSize
    }

    // MARK: - Forward

    /// Forward pass producing per-token logits over the BIOES label
    /// space. `inputIds` must already be tokenized and ≤ 4096 entries.
    func forward(inputIds: [Int]) throws -> [[Float]] {
        let seqLen = inputIds.count
        guard seqLen > 0 else { return [] }
        precondition(
            seqLen <= Self.maxSequenceLength,
            "MoETransformer.forward called with seqLen \(seqLen) > maxSequenceLength \(Self.maxSequenceLength)"
        )

        // 1. Token embeddings: indexed gather into the embedding table.
        guard let embedTable = weights["model.embed_tokens.weight"] else {
            throw ModelLoaderError.missingFile("model.embed_tokens.weight")
        }
        let ids = MLXArray(inputIds.map { Int32($0) }, [seqLen])
        var x = embedTable[ids]  // [seq, hidden]

        // 2. Transformer layers.
        for layer in 0 ..< config.numLayers {
            x = try transformerBlock(layer: layer, x: x)
        }

        // 3. Final RMSNorm.
        guard let finalNorm = weights["model.norm.weight"] else {
            throw ModelLoaderError.missingFile("model.norm.weight")
        }
        let normed = MLXFast.rmsNorm(x, weight: finalNorm, eps: rmsEps)

        // 4. Classification head.
        guard
            let scoreW = weights["score.weight"],  // [numLabels, hidden]
            let scoreB = weights["score.bias"]
        else {
            throw ModelLoaderError.missingFile("score.weight or score.bias")
        }
        let logits = matmul(normed, scoreW.transposed(axes: [1, 0])) + scoreB

        // 5. Materialize to Swift. Cast to float32 first so the
        // returned values are stable regardless of whether the model
        // ran in BF16 or FP16.
        let finalLogits = logits.asType(DType.float32)
        finalLogits.eval()
        let flat: [Float] = finalLogits.asArray(Float.self)
        precondition(flat.count == seqLen * numLabels)
        var rows: [[Float]] = []
        rows.reserveCapacity(seqLen)
        for t in 0 ..< seqLen {
            let start = t * numLabels
            rows.append(Array(flat[start ..< (start + numLabels)]))
        }
        return rows
    }

    // MARK: - Transformer block

    private func transformerBlock(layer i: Int, x: MLXArray) throws -> MLXArray {
        let prefix = "model.layers.\(i)"
        guard
            let inputLN = weights["\(prefix).input_layernorm.weight"],
            let postLN = weights["\(prefix).post_attention_layernorm.weight"]
        else {
            throw ModelLoaderError.missingFile("\(prefix) layernorm weights")
        }

        // Pre-attention RMSNorm
        let normedAttnIn = MLXFast.rmsNorm(x, weight: inputLN, eps: rmsEps)
        let attnOut = try attention(layer: i, x: normedAttnIn)
        let postAttn = x + attnOut

        // Pre-FFN RMSNorm
        let normedFFNIn = MLXFast.rmsNorm(postAttn, weight: postLN, eps: rmsEps)
        let moeOut = try moeFFN(layer: i, x: normedFFNIn)
        return postAttn + moeOut
    }

    // MARK: - Attention (GQA + sinks, bidirectional)

    private func attention(layer i: Int, x: MLXArray) throws -> MLXArray {
        let prefix = "model.layers.\(i).self_attn"
        guard
            let qW = weights["\(prefix).q_proj.weight"],
            let qB = weights["\(prefix).q_proj.bias"],
            let kW = weights["\(prefix).k_proj.weight"],
            let kB = weights["\(prefix).k_proj.bias"],
            let vW = weights["\(prefix).v_proj.weight"],
            let vB = weights["\(prefix).v_proj.bias"],
            let oW = weights["\(prefix).o_proj.weight"],
            let oB = weights["\(prefix).o_proj.bias"],
            let sinks = weights["\(prefix).sinks"]
        else {
            throw ModelLoaderError.missingFile("\(prefix) projection weights")
        }

        let seqLen = x.shape[0]

        // Projections. weight shape is [out, in] so we transpose.
        let q = matmul(x, qW.transposed(axes: [1, 0])) + qB  // [seq, nH*hd]
        let k = matmul(x, kW.transposed(axes: [1, 0])) + kB  // [seq, nKV*hd]
        let v = matmul(x, vW.transposed(axes: [1, 0])) + vB  // [seq, nKV*hd]

        // Reshape into heads. Final layout [nHeads, seq, hd] needed
        // by scaledDotProductAttention.
        let qH = q.reshaped([seqLen, numHeads, headDim]).transposed(axes: [1, 0, 2])
        let kH = k.reshaped([seqLen, numKVHeads, headDim]).transposed(axes: [1, 0, 2])
        let vH = v.reshaped([seqLen, numKVHeads, headDim]).transposed(axes: [1, 0, 2])

        // Apply RoPE on Q and K using YARN-NTK-by-parts inv_freq
        // precomputed at init. `traditional: true` selects the
        // interleaved-pair rotation (`(x_0,x_1), (x_2,x_3), …`) used
        // by the reference impl. `base` is nil because we supply
        // `freqs` ourselves. We then multiply by the YARN cos/sin
        // concentration — MLX's RoPE doesn't apply it, but it's
        // equivalent to scale Q/K post-RoPE.
        let qRopeRaw = MLXFast.RoPE(
            qH,
            dimensions: headDim,
            traditional: true,
            base: nil,
            scale: 1.0,
            offset: 0,
            freqs: yarnInvFreq
        )
        let kRopeRaw = MLXFast.RoPE(
            kH,
            dimensions: headDim,
            traditional: true,
            base: nil,
            scale: 1.0,
            offset: 0,
            freqs: yarnInvFreq
        )
        let qR = yarnConcentration == 1.0 ? qRopeRaw : qRopeRaw * yarnConcentration
        let kR = yarnConcentration == 1.0 ? kRopeRaw : kRopeRaw * yarnConcentration

        // Repeat KV heads to match Q heads (GQA).
        let repeats = numHeads / numKVHeads
        let kRepeated = broadcast(
            kR.reshaped([numKVHeads, 1, seqLen, headDim]),
            to: [numKVHeads, repeats, seqLen, headDim]
        ).reshaped([numHeads, seqLen, headDim])
        // V doesn't get RoPE; just GQA-replicate it.
        let vRepeated = broadcast(
            vH.reshaped([numKVHeads, 1, seqLen, headDim]),
            to: [numKVHeads, repeats, seqLen, headDim]
        ).reshaped([numHeads, seqLen, headDim])

        // Attention scores: [nH, seq, seq]. Cast to float32 before
        // softmax for numerical stability.
        let scale: Float = 1.0 / Float(headDim).squareRoot()
        let scoresRaw = matmul(qR, kRepeated.transposed(axes: [0, 2, 1])) * scale
        let scores = scoresRaw.asType(DType.float32)

        // Append sink logit as an extra column per head: shape
        // [nH, seq, seq+1]. On-disk sinks are stored as [nH] in
        // log-2 space; reference converts to natural log via `* ln(2)`
        // before placing them alongside scaled scores. Skipping this
        // conversion makes sinks effectively dominate the softmax
        // denominator (which is what was happening before).
        let sinksScaled = sinks.asType(DType.float32) * sinkLogScale
        let sinkColumn = broadcast(
            sinksScaled.reshaped([numHeads, 1, 1]),
            to: [numHeads, seqLen, 1]
        )
        let scoresWithSink = concatenated([scores, sinkColumn], axis: -1)

        // Softmax over keys + sink.
        let probsWithSink = softmax(scoresWithSink, axis: -1)
        // Drop the sink column — its only job is to absorb probability
        // mass into the denominator. The remaining columns are the
        // attention weights over real keys.
        let probs = probsWithSink[MLXEllipsisIndex.ellipsis, 0 ..< seqLen]
        let probsCast = probs.asType(vRepeated.dtype)

        let attn = matmul(probsCast, vRepeated)  // [nH, seq, hd]

        // Merge heads: [seq, nH*hd]
        let merged = attn.transposed(axes: [1, 0, 2]).reshaped([seqLen, numHeads * headDim])

        // Output projection.
        return matmul(merged, oW.transposed(axes: [1, 0])) + oB
    }

    // MARK: - MoE FFN (top-k routed SwiGLU experts)

    private func moeFFN(layer i: Int, x: MLXArray) throws -> MLXArray {
        let prefix = "model.layers.\(i).mlp"
        guard
            let routerW = weights["\(prefix).router.weight"],  // [numExperts, hidden]
            let routerB = weights["\(prefix).router.bias"],
            let gateW = transposedGate[i],  // [numExperts, hidden, intermediate]
            let upW = transposedUp[i],
            let downW = transposedDown[i],
            let gateB = weights["\(prefix).experts.gate_proj.bias"],  // [numExperts, intermediate]
            let upB = weights["\(prefix).experts.up_proj.bias"],
            let downB = weights["\(prefix).experts.down_proj.bias"]  // [numExperts, hidden]
        else {
            throw ModelLoaderError.missingFile("\(prefix) MoE weights")
        }

        let seqLen = x.shape[0]
        let k = topK
        let inter = intermediateSize

        // 1. Router logits + top-k.
        let routerLogits = matmul(x, routerW.transposed(axes: [1, 0])) + routerB
        let topVals: MLXArray
        let topIdx: MLXArray
        (topVals, topIdx) = Self.topKAlongLast(routerLogits, k: k)
        let topWeights = softmax(topVals.asType(DType.float32), axis: -1)  // [seq, k]

        // 2. Per-(token, slot) expert dispatch via gatherMM. We
        // reshape x to [seq, 1, hidden] so the M axis is 1 (one
        // "matrix row" per token), then broadcast across `k` so each
        // slot sees the same input and can pick its own expert.
        let xExpanded = broadcast(
            x.reshaped([seqLen, 1, hiddenSize]),
            to: [seqLen, k, hiddenSize]
        )
        let xFlat = xExpanded.reshaped([seqLen * k, 1, hiddenSize])

        // Expert indices flattened, used to gather rows of the expert
        // weight cube (axis 0).
        let expertIdsFlat = topIdx.reshaped([seqLen * k]).asType(DType.int32)
        let lhsIdxArr: [Int32] = (0 ..< Int32(seqLen * k)).map { $0 }
        let lhsIdx = MLXArray(lhsIdxArr)

        // 3. gate / up projections — both produce [seq*k, 1, inter].
        let gatedFlat = gatherMM(
            xFlat,
            gateW,
            lhsIndices: lhsIdx,
            rhsIndices: expertIdsFlat
        )
        let gateBiasFlat = gateB[expertIdsFlat]  // [seq*k, inter]
        let gated = (gatedFlat.reshaped([seqLen * k, inter]) + gateBiasFlat)
            .reshaped([seqLen, k, inter])

        let upFlat = gatherMM(
            xFlat,
            upW,
            lhsIndices: lhsIdx,
            rhsIndices: expertIdsFlat
        )
        let upBiasFlat = upB[expertIdsFlat]  // [seq*k, inter]
        let upped = (upFlat.reshaped([seqLen * k, inter]) + upBiasFlat)
            .reshaped([seqLen, k, inter])

        // 4. SwiGLU activation, OpenAI gpt-oss variant. Reference:
        //    out_glu = gate.clamp(max=7) * sigmoid(1.702 * gate)
        //    out_lin = up.clamp(-7, 7) + 1
        //    activation = out_glu * out_lin
        // The `+1` bias on the linear half and the `alpha=1.702` swish
        // are unique to this architecture; plain `silu(gate)*up`
        // (what we had before) produces values an order of magnitude
        // off, which is why every layer's residual was effectively
        // an identity for non-trivial inputs.
        let activated = Self.oaiSwiGLU(gate: gated, up: upped)  // [seq, k, inter]

        // 5. Down projection back to hidden.
        let activatedFlat = activated.reshaped([seqLen * k, 1, inter])
        let downFlat = gatherMM(
            activatedFlat,
            downW,
            lhsIndices: lhsIdx,
            rhsIndices: expertIdsFlat
        )
        let downBiasFlat = downB[expertIdsFlat]  // [seq*k, hidden]
        let downOut = (downFlat.reshaped([seqLen * k, hiddenSize]) + downBiasFlat)
            .reshaped([seqLen, k, hiddenSize])

        // 6. Weighted sum across slots: out[seq] = sum_s(w[seq, s] * downOut[seq, s])
        let weighted = downOut * topWeights.asType(downOut.dtype).reshaped([seqLen, k, 1])
        return weighted.sum(axis: 1)
    }

    // MARK: - Helpers

    /// Top-k along the last axis. Returns `(values, indices)` with
    /// shapes `[..., k]` each. Implemented via descending argSort
    /// because MLX-swift doesn't expose a direct `topk`.
    private static func topKAlongLast(_ array: MLXArray, k: Int) -> (MLXArray, MLXArray) {
        let lastAxis = array.shape.count - 1
        // argSort returns ascending order; flip to descending by
        // negating before sorting, then re-negate the gathered values.
        let neg = -array
        let sortedIdx = argSort(neg, axis: lastAxis).asType(DType.int32)
        let topIdx = sortedIdx[MLXEllipsisIndex.ellipsis, 0 ..< k]
        let topValsNeg = takeAlong(neg, topIdx, axis: lastAxis)
        let topVals = -topValsNeg
        return (topVals, topIdx)
    }

    /// OpenAI gpt-oss SwiGLU variant. The Python reference
    /// (`opf/_model/model.py:swiglu`) does:
    ///
    /// ```python
    /// x_glu, x_linear = x.chunk(2, dim=-1)
    /// x_glu = x_glu.clamp(min=None, max=limit)
    /// x_linear = x_linear.clamp(min=-limit, max=limit)
    /// out_glu = x_glu * torch.sigmoid(alpha * x_glu)
    /// return out_glu * (x_linear + 1)
    /// ```
    ///
    /// where `alpha=1.702` and `limit=7.0`. The HF safetensors split
    /// the fused `mlp1_weight` into `gate_proj` (= x_glu) and
    /// `up_proj` (= x_linear), so we apply the activation between
    /// our `gate` and `up` arrays after their respective projections.
    private static func oaiSwiGLU(gate: MLXArray, up: MLXArray) -> MLXArray {
        let alpha: Float = 1.702
        let limit: Float = 7.0
        let gateClamped = clip(gate, min: -Float.infinity, max: limit)
        let upClamped = clip(up, min: -limit, max: limit)
        let outGlu = gateClamped * sigmoid(alpha * gateClamped)
        return outGlu * (upClamped + 1)
    }

    /// Build the YARN-NTK-by-parts inverse-frequency vector of length
    /// `head_dim / 2`. Mirrors `RotaryEmbedding._compute_concentration_and_inv_freq`
    /// in the reference implementation.
    ///
    /// For the privacy-filter checkpoint (head_dim=64, base=150000,
    /// initial_context_length=4096, scaling_factor=32, ntk_alpha=1,
    /// ntk_beta=32) the cutoffs land at low≈8.09 and high≈17.40 along
    /// the 32 frequency bins, so:
    ///   • bins 0..7  → extrapolation (1/freq, vanilla)
    ///   • bins 8..17 → blended (NTK ramp)
    ///   • bins 18..31 → full interpolation (1/(scale·freq), damped)
    ///
    /// The concentration scalar is also returned; the caller applies
    /// it as a post-RoPE multiplier since MLX's `fast.rope` does not
    /// expose a separate cos/sin scale.
    private static func computeYarnInvFreq(
        headDim: Int,
        base: Float,
        scalingFactor: Float,
        initialContextLength: Float,
        ntkAlpha: Float,
        ntkBeta: Float
    ) -> (MLXArray, Float) {
        let dHalf = headDim / 2
        // Baseline RoPE frequencies: freq[i] = base ^ (2i / head_dim).
        // inv_freq is therefore 1 / freq[i].
        var freq = [Float](repeating: 0, count: dHalf)
        for i in 0 ..< dHalf {
            freq[i] = powf(base, Float(2 * i) / Float(headDim))
        }
        guard scalingFactor > 1.0 else {
            // No YARN scaling: vanilla RoPE.
            let inv = freq.map { 1.0 / $0 }
            return (MLXArray(inv), 1.0)
        }
        let concentration = 0.1 * Float(Darwin.log(Double(scalingFactor))) + 1.0
        let logBase = Float(Darwin.log(Double(base)))
        let twoPi: Float = 2.0 * .pi
        // NTK-by-parts cutoffs (cf. YaRN, arXiv:2309.00071).
        let low =
            Float(dHalf)
            * Float(
                Darwin.log(
                    Double(initialContextLength / (ntkBeta * twoPi))
                )
            ) / logBase
        let high =
            Float(dHalf)
            * Float(
                Darwin.log(
                    Double(initialContextLength / (ntkAlpha * twoPi))
                )
            ) / logBase
        // High-frequency bins extrapolate (full freq); low-frequency
        // bins interpolate (compressed freq). A linear ramp blends
        // between them between `low` and `high`.
        var invFreq = [Float](repeating: 0, count: dHalf)
        for i in 0 ..< dHalf {
            let interpolation = 1.0 / (scalingFactor * freq[i])
            let extrapolation = 1.0 / freq[i]
            let rampRaw = (Float(i) - low) / max(high - low, 1e-9)
            let ramp = max(0, min(1, rampRaw))
            let mask = 1.0 - ramp
            invFreq[i] = interpolation * (1.0 - mask) + extrapolation * mask
        }
        return (MLXArray(invFreq), concentration)
    }
}
