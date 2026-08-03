# Osaurus Cloud Media API

Status: client contract. Cloud media must remain hidden when the deployed
router returns `404` for catalog discovery.

All endpoints use the existing Osaurus Router request-signing contract. JSON
bodies are canonical-encoded before signing. Mutating generation requests also
carry the same UUIDv4 value in `Idempotency-Key` and `idempotency_key`.

## Catalog

`GET /v1/media/models`

```json
{
  "version": "2026-08-02",
  "models": [{
    "id": "provider/model",
    "display_name": "Model",
    "operation": "image",
    "constraints": {
      "aspectRatios": ["1:1", "16:9"],
      "resolutions": ["1K", "2K"],
      "durations": [],
      "supportsAudio": false,
      "audioConfigurable": false
    },
    "pricing": {
      "generation": {"usd": 0.04, "diem": null},
      "resolutions": {},
      "quality": {}
    },
    "privacy": "transient",
    "offline": false
  }]
}
```

`operation` is one of `image`, `text_to_video`, or `image_to_video`.
Unknown operations and unknown model fields are ignored by the client. A `404`
means Cloud media is unsupported; the client must not fall back to direct
Venice or expose stale Cloud choices.

## Images

`POST /v1/media/images/generations`

The request accepts `model`, `prompt`, optional `negative_prompt`, `width`,
`height`, `aspect_ratio`, `resolution`, `quality`, `steps`, `guidance`, `seed`,
`count`, and `format`. Fields not advertised by the selected model are omitted.

```json
{
  "idempotency_key": "uuid",
  "model": "provider/model",
  "prompt": "A lighthouse",
  "count": 1,
  "format": "webp"
}
```

The response contains base64 image payloads and settled billing:

```json
{
  "images": ["..."],
  "billing": {
    "exact_cost_micro_usd": "40000",
    "balance_after_micro_usd": "9960000",
    "usage_id": "usage-id"
  }
}
```

An idempotency replay returns the original bytes and billing record and never
creates a second upstream generation.

## Video quote and job

`POST /v1/media/videos/quote`

Accepts `model`, `duration`, and optional `aspect_ratio`, `resolution`, and
`audio`.

```json
{
  "quote_micro_usd": "800000",
  "quote_id": "quote-id",
  "expires_at": "2026-08-03T07:10:00Z"
}
```

`POST /v1/media/videos/jobs`

Requires a current `quote_id`, `idempotency_key`, model, prompt, duration, and
the quoted optional fields. Image-to-video also requires `image_url` as an
HTTPS URL or data URL. The server rejects a changed/expired quote rather than
silently charging a different amount.

```json
{
  "job_id": "job-id",
  "status": "QUEUED",
  "eta_seconds": 90,
  "billing": {
    "exact_cost_micro_usd": "800000",
    "balance_after_micro_usd": "9200000",
    "usage_id": "usage-id"
  }
}
```

`GET /v1/media/videos/jobs/{job_id}` returns the same envelope with status
`QUEUED`, `RUNNING`, `COMPLETED`, or `FAILED`.

`GET /v1/media/videos/jobs/{job_id}/content` returns `video/mp4` only after
completion. `DELETE /v1/media/videos/jobs/{job_id}/content` revokes and deletes
the transient output after the client has atomically persisted it.

Jobs and idempotency records survive client disconnect and app relaunch.
Generation input is retained only as long as required by the upstream job.
Completed output expires within 24 hours unless deleted sooner. Billing and
idempotency records may be retained for accounting without retaining prompts,
source images, or generated media.

## Errors

Errors use the Router envelope:

```json
{"error":{"code":"INSUFFICIENT_FUNDS","message":"Add balance to continue."}}
```

Required codes:

- `UNAUTHORIZED`, `INVALID_SIGNATURE`
- `INSUFFICIENT_FUNDS`, `ACCOUNT_FROZEN`
- `INVALID_REQUEST`, `MODEL_UNAVAILABLE`, `UNSUPPORTED_OPERATION`
- `QUOTE_EXPIRED`, `QUOTE_MISMATCH`
- `IDEMPOTENCY_CONFLICT`
- `CONTENT_POLICY`, `REGION_RESTRICTED`
- `RATE_LIMITED`, `UPSTREAM_CAPACITY`, `UPSTREAM_FAILURE`
- `JOB_NOT_FOUND`, `OUTPUT_EXPIRED`

`429` and capacity/5xx errors include `Retry-After` when known. The server must
settle or release billing holds before returning a terminal failure, and the
job/status response must expose the exact settled cost.
