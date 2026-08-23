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
| T8 | **Restart survival — kill app, replay identical prompt** | does L2 actually persist | ⚠ **contradicted by §9 and not reproduced** — the recorded 17.11s → 0.41s cannot be obtained by replaying a prompt in a new chat; five later legs show no reuse. See §14 |
| T9 | SSD budget stress past the % cap | LRU eviction breaking live chains | ✅ **against a live chain** — 512 MB cap held to the megabyte while a 6-turn conversation ran; every turn still correct. See §11 |
| T10 | Multiple images in different turns | the bunching bug | ✅ **live on 3 families** — LFM2.5-VL and Muse Glimmer both return `4, 5, 4, 7` and then `4,5,7`. Zaya is unstable but shows no bunching. See §10 |
| T11 | Cold-vs-warm answer exactness at `%256 ≠ 0` | silent divergence | ✅ **3 lengths, zero divergence** — cold and cache-served answers byte-identical while TTFT collapsed 6–15×. See §12 |
| T12a | **Audio on `gemma4_unified` 12B** (raw-waveform path, not mel+conformer) | the second audio family | ⚠ **audio reaches and informs the model** — "what animal is mentioned?" → **"Elephant"**, correct. Asked to transcribe verbatim it answered *"The quick brown fox jumps over the lazy dog."* — a **confabulated pangram**. See §5 |
| T12b | Audio on Nemotron-Omni (`sound_encoder` + Parakeet) | the third audio family | ✅ Nemotron-3-Nano-Omni-30B-A3B-JANG_4M — 4/4 content answers correct (`elephant` / `purple` / `7` / `violet`), TTFT 1.61s → 0.41/0.43/0.42s, 118–130 tok/s, kv_v2 604 MB, RSS 19.9 GB. **Reuse not discriminated at this size** — see §6 |
| T13 | Muse Glimmer / Zaya / LFM2.5-VL / Step-3.7 media reuse | per-family media paths | ⚠ **3 of 4 run and passing** — see §8. Step-3.7-Flash **attempted and aborted by a RAM guard** at 0.4 GB free; see §13 |
| T14 | **Growing conversation on a media prefix** (0.6k → 27k → 54k) | reuse at a depth where it is worth seconds; decode sag | ✅ Nemotron-Omni — reuse holds (1.44s at 27k, 1.87s at 54k vs 11.1s to prefill the same span); decode 124 → 51 → 64 → 54 → 63 tok/s. **Answer quality collapses at 27k for BOTH audio and text** — see §6 |

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

---

## 6. T14: what a growing conversation on Nemotron-Omni actually shows

Model: `OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANG_4M` (`nemotron_h`,
`sound_encoder` + Parakeet), neutral agent, tools off, isolated proof root.
Turn 1 carries the audio clip *"The purple elephant counted seven violet
umbrellas."*; the even turns append ~26k tokens of repetitive depot-log filler
so a re-prefill is worth seconds rather than noise.

| turn | context after | TTFT | decode | kv_v2 | question | answer |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| 1 audio | ~0.6k | 1.59s | 124.0 | 149 MB | what animal? | **elephant** ✅ |
| 2 +26k | ~27k | 25.16s | 50.9 | 595 MB | what colour is the animal? | **blue** ❌ (purple) |
| 3 short | ~27k | **1.44s** | 64.1 | 1043 MB | how many umbrellas? | **31** ❌ (seven) |
| 4 +26k | ~54k | 28.28s | 54.1 | 1788 MB | seal code for corridor 4? | **66** ❌ (31 — it answered corridor 9's code, from the filler in that same message) |
| 5 short | ~54k | **1.87s** | 63.1 | 2534 MB | what colour were the umbrellas? | **blue** ❌ (violet) |

**Reuse is proven here, and this is the shape that proves it.** Turns 3 and 5
answer in 1.4–1.9s at 27k and 54k, where prefilling that span costs 11.1s
(measured below). The short T12b leg could not show this: at ~650 tokens a full
re-prefill costs about the same as a resume, so its 0.4s follow-ups were
compatible with either.

### The wrong answers are NOT ours

Two controls, both on the same build and model:

| leg | shape | 27k answer |
| --- | --- | --- |
| A | audio turn, then +26k (reuse path) | **blue** / **31** |
| B | audio + 26k filler + question in ONE cold turn (no reuse at all) | **blue** |
| C | ground truth as **text**, then +26k (reuse path) | **blue** / **31** |

Cold reproduces it, and text reproduces it. So the property separating pass
from fail is neither modality nor cache — it is depth with distractor text
present. At ~27k this bundle answers from the filler instead of from the fact
it was given, and "31" is literally the seal code in the filler. That is a
model-quality limit of this checkpoint, recorded here so the next person does
not spend a day on the cache.

**Rule this produces: a long-context media test must carry a text control at
the same depth.** Without leg C, leg A reads exactly like an audio-in-cache
corruption bug — fluent, wrong, and pointed straight at code we own.

### A 2.2x "media prefill penalty" that did not survive replication

Leg A's turn 2 appended ~26k onto an audio-carrying prefix in **25.16s**, while
the same append on a text prefix (leg C) took **11.30s** and a cold 27k prefill
(leg B) took **11.62s**. Read alone that says a conversation containing media
prefills its later text at ~45% speed — a real product problem if true.

It is not true. Alternating the two legs, fresh app and fresh root per leg,
PhysMem logged per leg:

| run | A (audio prefix) | C (text prefix) |
| --- | ---: | ---: |
| 1 | 11.11s | 11.16s |
| 2 | 11.13s | 11.16s |
| 3 | 11.13s | 11.15s |

Medians 11.13s vs 11.16s — 0.3% apart, i.e. nothing. ~26k in 11.1s is about
2,340 tok/s. The 25.16s came from the first large prefill after a model load
and **stays UNEXPLAINED**; what is settled is that it is not caused by media in
the prefix. One sample in A-then-B order proposed a 2.2x regression that six
samples in ABAB order erased — the same failure mode that once fabricated a 29%
DSV4 regression on this box.

---

## 7. The model chip advertised vision but never audio

Found while capturing T12b: the selected-model chip renders `eye` for
`option.isVLM` and had no audio glyph at all. So Nemotron-Omni — a bundle whose
headline capability is audio — described itself as vision-only on the one
surface a user reads before typing, while the composer directly beneath it was
already accepting `.wav`.

| build | chip badges |
| --- | --- |
| control | ● name · brain · **eye** · 30B |
| fixed | ● name · brain · **eye** · **waveform** · 30B |

The badge reads the same `mediaCapabilities` the attach button reads, so the
two surfaces cannot drift apart. Affects every audio family: Nemotron-Omni,
Gemma-4 E2B/E4B, Gemma-4 12B unified. No new localization keys — it reuses the
existing `Audio Input` catalog entry.

---

## 8. T13: does every vision family actually reuse across a media prefix?

Same growing shape as §6, with an image instead of audio, one fresh app per
family. Turn 2 adds ~13k tokens of filler (13k, not 26k — several of these
ship shorter windows than Nemotron-Omni, and a filler that overflows the window
measures the truncation policy rather than the cache). Turn 3 is the test:
if it is not seconds faster than turn 2, that family is not reusing.

| family | `model_type` | t1 image | t2 +13k | **t3 short** | t4 +13k | **t5 short** | decode 1k → 20k | kv_v2 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| ZAYA1-VL 8B JANGTQ4 | `zaya1_vl` | 1.65s | 4.99s | **0.38s** | 5.62s | **0.64s** | 51.5 → 29.3 | 101 → 4707 MB |
| Muse Glimmer 30B JANG_4M | `muse_glimmer` | 1.62s | 11.92s | **1.05s** | 17.67s | **0.70s** | 30.7 → 18.7 | 266 → 3494 MB |
| LFM2.5-VL 3B MXFP8 | `lfm2_vl` | 0.41s | 1.42s | **0.19s** | 1.73s | **0.24s** | 157.7 → 170.7 | 31 → 1953 MB |
| Step-3.7-Flash | `step3p7` | — | — | — | — | — | — | not run: ~82 GB bundle, no free RAM |

All three reuse across an image prefix, at both 10k and 20k. Answers were
correct at both ends of every conversation — digit `4` on turn 1 and again on
turn 5, and the filler's `17` in between — so the media survives to 20k here.

**That is the useful contrast with §6.** Muse Glimmer still had the image at
20k while Nemotron-Omni had lost the audio by 27k, on the same machine, through
the same cache. A pipeline defect would not be so selective, which is more
evidence that §6 is the checkpoint and not the code.

**Decode sag is family-specific, not universal.** Zaya loses 43% and Muse 39%
between 1k and 20k, while LFM2.5-VL loses nothing at all (157.7 → 170.7 tok/s).
Any future claim that "decode sags with depth" has to name the family.

### A probe question that was ambiguous

Turn 1 asked "what digit is shown and what colour is it?" of a white `4` on a
purple field. Zaya and Muse answered **purple** (the field); LFM2.5-VL answered
**white** (the glyph). Both readings are correct, and each model stayed
consistent with itself at 20k, which is the property being tested — but the
question cannot score colour. Ask about the field explicitly next time.

---

## 9. T11 attempt: prefix reuse is scoped to ONE conversation

T11 wants a cold answer and a cache-restored answer compared at a prefix length
that is not a round number. Building it turned up something that has to be
recorded first, because it changes what T11 can even be built out of.

**A byte-identical prompt in a different chat reuses nothing.** Not across a
restart, and not even inside one process:

| shape | model | cold | second run | verdict |
| --- | --- | ---: | ---: | --- |
| new chat after app restart, same root | LFM2.5-VL 3B, ~21k | 7.12s | 6.57s | no reuse |
| new chat after app restart, same root | LFM2.5-VL 3B, ~28k | 14.18s | 8.94s | no reuse |
| new chat after app restart, same root | Ornith-1.5-9B, ~5.7k | 6.63s | 5.94s | no reuse |
| **new chat in the SAME process** | LFM2.5-VL 3B, ~21k | **7.13s** | **7.16s** | **no reuse** |

The last row is the decisive one: same process, same loaded weights, the same
21k prompt sent twice into two chats, and the second is 0.03s slower. The disk
cache had the block too — `kv_v2` grew 441 → 882 → 1764 MB across these runs,
so every leg WROTE a block and none of them read one.

So reuse is per-conversation. T8's 42x restart win (17.11s → 0.41s) was a
conversation being continued, not a prefix being recognised.

**This is worth a product decision, not a unilateral change.** Pasting the same
document, system prompt, or codebase into a fresh chat is an ordinary thing to
do, and today it pays full prefill every time. Whether cross-chat sharing is
wanted — and under what scoping — is Eric's call; the salt itself is only
`reasoning=on/off` plus a media fingerprint, so nothing in the key forces the
current behaviour.

**T11 itself stays ❌.** Its question — does a restored cache produce the same
answer at `cached_tokens % 256 != 0` — can only be asked inside one
conversation, which means driving the history sidebar to reopen a chat after a
restart. The sidebar rows are `AXStaticText` inside an `AXOpaqueProviderGroup`
with no pressable row element, and a pid-targeted click on the row did not
select it. That is the next thing to solve for this row.

### Two model-accuracy notes from the same runs, so they are not mistaken for cache bugs later

- LFM2.5-VL answered `103` and `123` for a seal code that was stated as `1259`
  in the prompt — wrong, but **identically wrong** cold and warm. Retrieval
  accuracy at 21–28k, not cache divergence.
- Ornith-1.5-9B at 44k spent its whole output budget thinking and returned the
  max-tokens notice instead of an answer. A reasoning model needs its budget
  raised (or thinking off) before it can be used as a cache probe at all.

---

## 10. T10: three images, three separate turns

The bunching failure — features from one turn landing on another turn's
placeholders — cannot be seen by asking only about the newest image, because
the newest one is right even when the older ones have been displaced. So every
turn asks about a different one, including going back to the first:

1. attach purple `4` → which digit?
2. attach green `5` → which digit in the new image?
3. **no attachment** → which digit was in the FIRST image?  ← the test
4. attach blue `7` → which digit?
5. **no attachment** → list all three in order

| family | t1 | t2 | **t3 (first image)** | t4 | t5 (in order) |
| --- | --- | --- | --- | --- | --- |
| LFM2.5-VL 3B MXFP8 | 4 ✅ | 5 ✅ | **4 ✅** | 7 ✅ | `4, 5, 7` ✅ |
| Muse Glimmer 30B JANG_4M | 4 ✅ | 5 ✅ | **4 ✅** | 7 ✅ | `4,5,7` ✅ |
| ZAYA1-VL 8B JANGTQ4 | 4 ✅ | 5 ✅ | 5 ❌ | 3 ❌ | `5, 3, 2` ❌ |

**The pipeline keeps per-turn images distinct.** Two families answer every
question correctly, including recalling the first image after two more have
arrived, and reconstructing the full ordered list.

### Zaya is not evidence of bunching, and it took a second run to know that

The first Zaya run looked like the bunching bug. It was not:

- Re-run with neutral wording — "the very first image of this conversation"
  instead of "the FIRST image I sent" — Zaya answered **4**, correctly. The
  earlier `5` was wording sensitivity, not a displaced feature.
- Its `3` for the third image came from a prompt that said "this **THIRD**
  image". Suspicious on its own — but LFM and Muse answered `7` to that exact
  wording, so the wording is not sufficient to cause it.
- On the neutral re-run Zaya also emitted tool-flavoured prose ("you can use
  the osaurus_agent command…") on an agent with tools DISABLED, which is its
  known template priming echo, not a media problem.

So: Zaya1-VL gives unstable answers on multi-image conversations and is a poor
probe model. `Zaya1VL.mergeImageFeatures` is a flat masked scatter that
*throws* when the image-token count and feature-row count disagree, so a silent
misplacement would require mis-ordered feature rows — not something the two
passing families are consistent with.

**Harness rule this reinforces:** when one family fails a probe that two others
pass, re-run the failing one with the wording varied before believing it. A
single family's wrong answer is a hypothesis, not a finding.

---

## 11. T9: eviction while the conversation is still running

Eviction was already proven in isolation. The case that actually hurts is the
cap being reached mid-chain, so the blocks being thrown away belong to the
conversation still in progress.

LFM2.5-VL 3B, image turn then five turns each adding ~13k tokens, every one
asking again about the image sent at the start. Cap set to 512 MB.

| turn | capped kv_v2 | capped TTFT | uncapped kv_v2 | uncapped TTFT | answer |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 30 MB | 0.53s | 30 MB | 1.42s | 4 ✅ |
| 2 | 308 MB | 2.19s | 308 MB | 1.93s | 4 ✅ |
| 3 | **263 MB** ← evicted | 2.61s | 833 MB | 2.22s | 4 ✅ |
| 4 | 387 MB | 3.01s | 1607 MB | 2.29s | 4 ✅ |
| 5 | **511 MB** | 3.84s | 2628 MB | 2.83s | 4 ✅ |
| 6 | **511 MB** | 3.73s | 3897 MB | 3.28s | 4 ✅ |

**The cap holds to the megabyte** (511 of 512) and the drop at turn 3 is
eviction happening *between* turns of a live conversation — not at startup, not
on a timer. **Every turn still answered correctly**, including recalling the
image after five intervening blocks of filler, so eviction does not break a
running chain.

The cost is small here and the reason is §3: same-session continuation is
served by the in-memory KV cache, so throwing away disk blocks costs the live
conversation almost nothing. Caveat on the comparison — the uncapped column is
one run of the same script taken while the machine was under heavier memory
pressure (5–12 GB free vs 8–13 GB), so treat the TTFT columns as "the same
shape", not as a controlled delta.

### The knob that does nothing

The first run of this test set `cache.blockDisk.maxSizeGB = 0.5` and watched the
cache grow to **3897 MB — 7.6x the cap**. That looks exactly like an unenforced
user limit, and it is not:

    resolveDiskCacheMaxGB(percent:legacyGB:directory:)
      if let percent, percent > 0 { return capacity * percent / 100 }   // wins
      if let legacyGB, legacyGB > 0 { return legacyGB }                 // dead

**`maxSizeGB` is only consulted when `maxSizePercent` is nil or zero, and the
app writes `maxSizePercent: 10` by default.** So a GB figure written into the
config has no effect at all — 10% of this 3.7 TB volume is ~372 GB, which is
what was actually enforced. Setting the percent to 0.01343% produced the 512 MB
cap used above, and it held exactly.

Worth knowing because the failure is silent in the reassuring direction for
anyone hand-editing a config: the field is accepted, persisted, and ignored.

---

## 12. T11: the same question, answered cold and then from cache

§9 left this row blocked: reuse is per-conversation, killing the app to drop the
in-memory cache also drops the chat, and the history sidebar's rows have no
pressable AX element (a hover-then-click posted to the pid did not select one
either).

**`power.deepSleepAfterSeconds` gets around it.** Auto-sleep releases the
model — and the live KV with it — after an idle period, `wakeOnRequest` brings
it back, and the chat stays open the whole time. So the same conversation can
be asked the identical question twice: once cold, once served from cache.

LFM2.5-VL 3B, three manifest lengths chosen to be arbitrary rather than round:

| manifest | cold TTFT | cold answer | second ask | answer | |
| ---: | ---: | --- | ---: | --- | --- |
| 400 lines | 1.84s | `1259` | **0.31s** | `1259` | identical, and correct |
| 613 lines | 3.10s | `124` | **0.21s** | `124` | identical |
| 887 lines | 4.17s | `1000` | **0.28s** | `1000` | identical |

**Zero divergence at any length.** The 6–15x TTFT collapse is what makes the
comparison mean something: the second ask was served from a cache rather than
re-prefilled, so a padding/offset defect in that path would have had to show up
in the output. It did not.

The 613 and 887 legs answer `124` and `1000` where the manifest says `1259` —
LFM2.5-VL's retrieval accuracy at 12–17k, **identically wrong both times**. A
cache defect does not produce the same wrong answer twice from two different
code paths; a model that cannot find the line does.

### The gate had a fail-open, and it fired

The first attempt ran Ornith-1.5-9B, whose turn 1 spent its output budget
thinking and returned the max-tokens notice. The gate compared that notice
against turn 2's `1259` and reported **DIVERGED** — a cache-corruption verdict
manufactured out of a turn that never answered. The gate now treats the
max-tokens notice, and an empty answer, as INVALID rather than as data.

Same lesson as §6 in the opposite direction: a harness that cannot tell
"no answer" from "different answer" will invent the most alarming reading
available.

---

## 13. Step-3.7-Flash: attempted, and stopped by a guard rather than by an estimate

The §8 row said Step-3.7 was skipped because the bundle is ~74–82 GB. That was
an estimate, so it was worth actually trying.

Run with a supervisor (`ramguard.sh`) polling free memory every 10s and killing
the app below a 3 GB floor. Started at 57 GB free; during the weight load free
memory fell to **0.4 GB** and the guard stopped the app. The machine recovered
to 30 GB free with no panic, and the probe never reached its first turn.

Polling afterwards for a window big enough to retry, free memory over ten
minutes went: 3, 44, 74, 20, 8, 41, 29, 35, 49, 84, 5, 1 GB. The box is being
cycled by other model work, so there is no stable window for a bundle this
size — and a run that survives only until the next background load would
measure paging, not the cache.

**So this row is not "skipped", it is "measured as not runnable here".** The
difference matters: the guard produced a number (0.4 GB free at load), and the
polling produced a distribution. Both are evidence. Retrying needs the machine
mostly to itself, which is a scheduling question rather than a testing one.

The guard is worth keeping regardless. Three VL models in one process once left
this machine with 15 MB free and triggered a watchdog panic; a supervised probe
turns that into a clean abort.

---

## 14. T8 no longer holds as written

T8 recorded "kill app, replay identical prompt → **17.11s → 0.41s (~42x)**" and
was the evidence that disk L2 serves the cross-session case. §9 measured the
opposite five times, and the T8 shape itself did not reproduce:

| leg | model | cold | replay after restart |
| --- | --- | ---: | ---: |
| new chat, same root | Ornith-1.5-9B ~5.7k | 6.63s | 5.94s |
| new chat, same root | **Ornith-1.5-9B ~17k** | **22.30s** | **23.73s** |
| new chat, same root | LFM2.5-VL ~21k | 7.12s | 6.57s |
| new chat, same root | LFM2.5-VL ~28k | 14.18s | 8.94s |
| new chat, same process | LFM2.5-VL ~21k | 7.13s | 7.16s |

Ornith at 17k is the closest match to T8's own conditions — same family, same
order of magnitude — and it got *slower* on the replay.

**What T8 probably measured.** A relaunched app opens a NEW chat (verified: the
window comes up with an empty composer and a ~657-token context), so the replay
could not have continued the original conversation. That leaves the model load
itself: a first launch pays a cold read of the weights, and the second launch
finds them in the OS page cache. A TTFT that includes weight loading would show
exactly this shape, and it has nothing to do with the KV cache.

**The run that separates the two has already happened.** §9's last row is
exactly it: one process, weights hot for both legs, the identical 21k prompt
sent into two chats — **7.13s then 7.16s**. With weight loading taken out of
the comparison, the second identical prompt saves nothing. So a 42x gap cannot
be KV reuse in a new chat, and weight loading is the only term left that a
restart changes.

The original run is still not reconstructable — it happened in an earlier
session and only the numbers survive — so the row is downgraded rather than
re-explained with a cause it cannot support.

The §12 result stands on its own regardless: a cache-served turn answers
identically to a cold one. That was established by deep-sleeping a live
conversation, not by restarting the app.
