# File Generator And Export Contract

This document defines the canonical manifest and tool contract for
plugin-backed generators and exporters.

Related documents:

- [Development Docs Index](./README.md)
- [File Management Architecture Review And PR0](./FILE_MANAGEMENT_ARCHITECTURE_REVIEW_AND_PR0.md)
- [File Import Plugin Contract](./file-import-plugin-contract.md)
- [Plugin Authoring Guide](../PLUGIN_AUTHORING.md)

## Manifest

Native plugins declare generator descriptors in `capabilities.file_generators`:

```json
{
  "plugin_id": "com.example.office",
  "capabilities": {
    "tools": [
      {
        "id": "export_pptx",
        "description": "Generate a PowerPoint deck from structured input",
        "parameters": {
          "type": "object"
        }
      }
    ],
    "file_generators": [
      {
        "id": "pptx",
        "tool_id": "export_pptx",
        "output_extensions": ["pptx"],
        "output_media_types": ["application/vnd.openxmlformats-officedocument.presentationml.presentation"],
        "accepted_input_schemas": ["structured_extraction_v1", "normalized_document_v1"],
        "template_support": "optional",
        "output_schema_version": 1,
        "share_artifact_required": true,
        "preferred_placement": "native_plugin"
      }
    ]
  }
}
```

Descriptor rules:

- `id` must be stable and unique within the plugin.
- `tool_id` must reference a declared tool.
- `accepted_input_schemas` should name the logical shapes the generator accepts.
- `share_artifact_required` should remain `true` for user-visible outputs.
- `preferred_placement` must match the placement matrix in the architecture doc.

## Tool Request

Osaurus invokes the referenced `tool_id` with a JSON payload:

```json
{
  "format": "pptx",
  "output_directory": "/absolute/path/to/job-output",
  "destination_basename": "quarterly-review",
  "accepted_input_schema": "structured_extraction_v1",
  "input": {
    "title": "Quarterly Review"
  },
  "template": {
    "id": "default-corporate"
  },
  "metadata": {
    "requested_by": "work_mode"
  },
  "output_schema_version": 1
}
```

Request rules:

- `output_directory` is the only directory the generator may write into.
- Generators must fail closed on unsupported schema versions, invalid templates,
  unsafe paths, or oversized output attempts.
- Generators should emit deterministic artifacts; hidden mutable state should be
  avoided unless the plugin documents it explicitly.

## Preferred Tool Response

New generators should return the canonical shape:

```json
{
  "artifacts": [
    {
      "filename": "quarterly-review.pptx",
      "path": "/absolute/path/to/job-output/quarterly-review.pptx",
      "media_type": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "byte_size": 42210,
      "role": "primary"
    }
  ],
  "provenance": {
    "generator_id": "pptx",
    "plugin_id": "com.example.office",
    "output_schema_version": 1
  },
  "warnings": []
}
```

Response rules:

- Every returned path must be inside `output_directory`.
- User-visible artifacts must still flow through the existing `share_artifact`
  path before the task is considered complete.
- Generators should return enough metadata for provenance, indexing, and
  post-generation sharing to be deterministic.

## Deterministic Failure Shape

Generators should prefer a typed failure envelope:

```json
{
  "error": {
    "code": "unsupported_output",
    "message": "The plugin cannot generate the requested format.",
    "retryable": false
  }
}
```

Recommended codes:

- `unsupported_output`
- `unsupported_input_schema`
- `invalid_template`
- `oversized_output`
- `unsafe_path`
- `internal_failure`

## Provenance Requirements

Generators should be able to report:

- generator identifier
- plugin identifier
- accepted input schema
- output schema version
- warnings that materially affected the output
- every emitted artifact path, media type, and size
