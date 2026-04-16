# File Import Plugin Contract

This document defines the canonical manifest and tool contract for
plugin-backed file importers.

Related documents:

- [Development Docs Index](./README.md)
- [File Management Architecture Review And PR0](./FILE_MANAGEMENT_ARCHITECTURE_REVIEW_AND_PR0.md)
- [Generator And Export Contract](./file-generator-export-contract.md)
- [File Import Phased PR Plan](./file-import-phased-pr-plan.md)
- [Plugin Authoring Guide](../PLUGIN_AUTHORING.md)

## Manifest

Native plugins declare importer descriptors in `capabilities.file_importers`:

```json
{
  "plugin_id": "com.example.office",
  "capabilities": {
    "tools": [
      {
        "id": "import_xlsx",
        "description": "Normalize spreadsheet content to text",
        "parameters": {
          "type": "object"
        }
      }
    ],
    "file_importers": [
      {
        "id": "xlsx",
        "tool_id": "import_xlsx",
        "extensions": ["xlsx", "xls"],
        "ut_types": ["org.openxmlformats.spreadsheetml.sheet"],
        "mime_types": ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
        "max_bytes": 10485760,
        "max_chars": 500000,
        "output_mode": "normalized_text",
        "output_schema_version": 1,
        "preferred_placement": "native_plugin"
      }
    ]
  }
}
```

Descriptor rules:

- `id` must be stable and unique within the plugin.
- `tool_id` must reference a declared tool.
- `preferred_placement` must match the placement matrix in the architecture doc.
- `max_bytes` and `max_chars` must declare hard limits, not suggestions.
- `output_schema_version` must change when the canonical output shape changes.

## Tool Request

Osaurus invokes the referenced `tool_id` with a JSON payload:

```json
{
  "path": "/absolute/path/to/file.xlsx",
  "filename": "file.xlsx",
  "file_extension": "xlsx",
  "mime_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "content_hash": "sha256:...",
  "max_bytes": 10485760,
  "max_chars": 500000,
  "output_mode": "normalized_text",
  "output_schema_version": 1
}
```

Request rules:

- `path` is always a host-local absolute file path.
- Importers must fail closed on unreadable, malformed, oversized, or unsupported inputs.
- Importers must not write outside their allowed working directory.
- Core import behavior must not be emulated by shelling out from plugins without explicit review.

## Preferred Tool Response

New importers should return the canonical shape:

```json
{
  "documents": [
    {
      "filename": "file.xlsx",
      "content": "Normalized text summary here",
      "byte_size": 12345,
      "media_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }
  ],
  "structured_extraction": {
    "schema": "structured_extraction_v1"
  },
  "provenance": {
    "importer_id": "xlsx",
    "plugin_id": "com.example.office",
    "output_schema_version": 1
  },
  "warnings": [],
  "truncated": false,
  "partial": false
}
```

Compatibility note:

- The host may continue to normalize legacy shapes such as `attachments`,
  single-document payloads, or raw text.
- New importers should use the canonical `documents` response so future
  provenance and catalog features have a stable base.

## Provenance Requirements

Importers should be able to report:

- importer identifier
- plugin identifier
- output schema version
- truncation or partial-extraction flags
- warnings that materially affected the result

## Deterministic Failure Shape

Importers should prefer a typed failure envelope:

```json
{
  "error": {
    "code": "oversized_input",
    "message": "The file exceeds the importer byte limit.",
    "retryable": false
  }
}
```

Recommended codes:

- `unsupported_type`
- `malformed_input`
- `oversized_input`
- `unsafe_path`
- `permission_denied`
- `internal_failure`

## Current Host Limits

- Built-in document text is truncated to `500000` characters.
- Built-in PDF image fallback is capped at `20` rendered pages.
- Most built-in host importers are capped at `25 MB`.
- Built-in PDF import is capped at `50 MB`.
