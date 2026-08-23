# SSD / prefix-cache coverage matrix

Living document. Every row is either something that was **run live in the dev
app GUI** or is explicitly marked as not run. Nothing here is inferred from
reading code — where a claim rests on a unit test or a source read, it says so.

Rule for editing: never upgrade a status without naming the run that justifies
it. Downgrade freely.

Legend: ✅ proven live · ⚠ partial / caveated · ❌ not run · — n/a

---

## 1. Modality inventory (checkpoint facts, not names)

Derived by scanning each bundle's safetensors index for vision/audio tensors —
`vision_tower`, `visual.`, `vision_model`, `radio`, `embed_vision` and
`embed_audio`, `audio_tower`, `sound_encoder`, `parakeet`, `conformer` — plus
`vision_config` in `config.json`.

**Naming is not a reliable detector, and a narrow scan lies.** A first pass that
only looked for `vision_tower`/`audio_tower` reported Nemotron-Omni as
text-only; it actually ships `sound_encoder` (710 tensors) and `vision_model`
(390). Any future scan must cover every family's naming convention or it will
under-report.

| model_type | bundles | with vision | with audio | note |
| --- | ---: | ---: | ---: | --- |
| `gemma4` | 19 | 18 | **4** | audio only on E2B/E4B; 26B-A4B and 31B ship **no** audio tensors |
| `gemma4_unified` | 2 | 2 | **2** | 12B — encoder-free `embed_audio` raw-frame projection |
| `gemma4_text` | 6 | 0 | 0 | Raptor et al |
| `qwen3_5` | 17 | 17 | 0 | Qwen3.8, Ornith 1.x 9B, Bonsai — vision only |
| `qwen3_5_moe` | 11 | 11 | 0 | Ornith 35B, AgentWorld, Qwen3.6 |
| `muse_glimmer` | 3 | 3 | 0 | vision only |
| `nemotron_h` | 7 | 3 | **3** | Omni = `sound_encoder` + `vision_model`; Lightning is text |
| `nemotron_voicechat` | 3 | 0 | 0 | separate duplex runtime, not the chat media path |
| `lfm2_vl` | 5 | 5 | 0 | |
| `zaya1_vl` / `step3p7` / `deepseek_vl_v2` | 2 / 2 / 1 | all | 0 | |

Consequence for testing: **audio only has three candidate families** —
gemma4 E2B/E4B, gemma4_unified 12B, and nemotron_h Omni. Everything else is
vision-only or text, so an "audio cache" test on them is vacuous by
construction.

---

## 2. What has actually been run

| # | test | what it catches | status |
| --- | --- | --- | --- |
| T1 | Text multiturn continuity | basic reuse, evaporated hits | ✅ Ornith-1.5-9B, gemma-4 E4B |
| T2 | Image mid-conversation, then text follow-ups | media prefix reuse | ✅ Ornith-1.5-9B (0.56s cold → 0.21/0.23/0.23s) |
| T3 | **Video then image across turns** | the feature-order swap | ✅ Qwen3.8-27B — pre-fix "digit 9 … orange/amber" (video's last frame) vs post-fix "digit 4 … indigo" |
| T4 | Image + video in ONE turn | — | ✅ ran, but **proves nothing**: within one message the generator emits image before video, so rows and pads already agree. Passes on the broken build too. |
| T5 | **Audio mid-conversation + follow-ups** | audio prefix reuse | ✅ gemma-4 E4B — "The purple elephant counted seven violet umbrellas." then "Seven" / "Elephant" at 0.21/0.24s vs 0.46s cold; disk cache 391 MB → 717 MB |
| T6 | Audio attach gating | capability gates | ✅ picker A/B ("image supported" + greyed `.wav` → "image + audio supported" + selectable) and send gate (`audios=0` → `audios=1` at the engine boundary) |
| T7 | Long-context (~30–48k) follow-ups | boundary publication value | ✅ run — **negative result**, see §3 |
| T8 | **Restart survival — kill app, replay identical prompt** | does L2 actually persist | ✅ Ornith-1.5-9B — **17.11s → 0.41s (~42×)** across a real process restart on the same root; cache 3.5 → 4.4 GB |
| T9 | SSD budget stress past the % cap | LRU eviction breaking live chains | ⚠ eviction proven at a share (1638 MB → 408 MB under a 762 MB cap) but not against a live chain |
| T10 | Multiple images in different turns | the bunching bug | ⚠ unit-tested only |
| T11 | Cold-vs-warm answer exactness at `%256 ≠ 0` | silent divergence | ❌ never run |
| T12a | **Audio on `gemma4_unified` 12B** (raw-waveform path, not mel+conformer) | the second audio family | ⚠ **audio reaches and informs the model** — "what animal is mentioned?" → **"Elephant"**, correct. Asked to transcribe verbatim it answered *"The quick brown fox jumps over the lazy dog."* — a **confabulated pangram**. See §5 |
| T12b | Audio on Nemotron-Omni (`sound_encoder`) | the third audio family | ❌ never run |
| T13 | Muse Glimmer / Qwen3.6-35B / Zaya / Step-3.7 media reuse | per-family media paths | ❌ never run |

---

## 3. Negative result: media-path cache boundaries

The VL processor's media branch publishes no `cachePrefixTokenCounts`. I added
an expander so boundaries past an image could validate, and **measured it live
as no-benefit and slightly harmful**, so it was removed from vmlx #298 rather
than shipped.

Ornith-1.5-9B, image turn then text follow-ups, settled box, PhysMem per leg,
leg order reversed to rule out launch effects:

| context | control | with expander |
| --- | --- | --- |
| ~1k | 0.21 / 0.23 / 0.23 | 0.23 / 0.23 / 0.24 |
| ~30k | 0.41 / 0.73 / **0.73** | 0.72 / 1.04 / **1.04** |

**Why:** after a 16.5s cold turn the CONTROL's follow-ups already run at
0.4–0.7s. Same-session continuation is served by the in-memory KV cache, so a
published boundary has nothing left to improve.

**T8 has now run and closes this question against the change.** On the shipping
build, an identical long prompt replayed after a real process restart went
**17.11s → 0.41s**, so disk L2 already serves the cross-session case too. There
is no remaining window where the expander was needed: warm same-session is
served by the in-memory cache, cold-after-restart by L2. The removal stands.

---

## 4. Harness traps hit while producing the rows above

Each of these produced a plausible-but-wrong reading before it was caught.

- **Attach can silently no-op.** A turn ran with no image and the model
  answered "I don't see any image attached" — read as a product finding until a
  screenshot showed an empty composer. The gate now counts the chip's own
  `AXButton desc="Close"`; counting `AXImage` reported FAIL on a turn that WAS
  attached.
- **Plural-only TTFT regex.** Turns answering with **1 token** didn't match
  `[0-9]+ tokens`, so the scraper reported the PREVIOUS turn's line — three
  different prompts came back byte-identical. Identical metrics across
  different prompts is a harness bug, never a result.
- **A shape too small to discriminate.** At ~1k tokens a full re-prefill costs
  ~0.2s, so "resumed" and "re-prefilled" are indistinguishable. §3 only became
  visible at 30k.
- **Ambiguous probe values.** The first cross-turn probe used a red "3" image
  after a video whose frame 2 was also red-3 — a correct answer and a leak look
  identical. A purple "4" (in no frame) made it decisive.
- **Memory pressure fabricates deltas.** One control leg ran at 2.2 GB free
  with the image silently unattached; it was discarded, not reported.


---

## 5. T12a: a fluent wrong transcript on gemma4_unified 12B

Ground truth clip: *"The purple elephant counted seven violet umbrellas."*

| model | audio path | transcribe verbatim | content question |
| --- | --- | --- | --- |
| gemma-4 E4B-it-8bit | mel + conformer `audio_tower` | **exact match** | "Seven" / "Elephant" — correct |
| gemma-4 12B-it-MXFP8 | `Gemma4UnifiedAudioFeatureExtractor` raw-waveform | *"The quick brown fox jumps over the lazy dog."* — **confabulated** | **"Elephant"** — correct |

The plumbing is NOT broken on 12B: a content question is answered correctly from
the audio, which is only possible if the waveform reached the model. Verbatim
transcription specifically is what fails — it emits a canonical pangram.

**Why this shapes how these tests are written.** That wrong answer is fluent,
confident, and shaped exactly like success. A word-list assertion, a "did it
return a sentence" check, or a human skim all PASS it. Only scoring against the
exact known sentence catches it — which is why the probe says "purple elephant /
seven violet umbrellas" rather than anything a model might plausibly guess.

Corollary: **prefer a content question over "transcribe this"** when the
question is merely whether audio arrived. "What animal is mentioned?" cannot be
answered by reciting a pangram.
