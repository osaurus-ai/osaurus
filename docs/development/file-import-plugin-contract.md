# File Import Plugin Contract

This document defines the native plugin manifest and tool contract for
plugin-backed file importers.

## Manifest

Native plugins can declare importer descriptors in `capabilities.file_importers`:

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
        "output_mode": "normalized_text",
        "output_schema_version": 1
      }
    ]
  }
}
```

## Tool Request

Osaurus invokes the referenced `tool_id` with a JSON payload:

```json
{
  "path": "/absolute/path/to/file.xlsx",
  "filename": "file.xlsx",
  "file_extension": "xlsx",
  "mime_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "max_bytes": 10485760,
  "max_chars": 500000,
  "output_mode": "normalized_text",
  "output_schema_version": 1
}
```

Rules:

- `path` is always a host-local absolute file path.
- Importers must fail closed on unreadable, malformed, or oversized inputs.
- Importers should not shell out unless that behavior is explicitly part of the plugin design and security review.

## Tool Response

Preferred response shape:

```json
{
  "attachments": [
    {
      "filename": "file.xlsx",
      "content": "Normalized text summary here",
      "file_size": 12345
    }
  ]
}
```

Also accepted:

- `{"documents":[...]}`
- `{"content":"Normalized text summary","filename":"file.xlsx","file_size":12345}`
- Raw plain text, which Osaurus wraps into a `.document` attachment

All responses are normalized into the existing chat document attachment path and continue to render as:

```xml
<attached_document name="...">...</attached_document>
```

## Current Host Limits

- Built-in document text is truncated to `500000` characters.
- Built-in PDF image fallback is capped at `20` rendered pages.
- Most built-in host importers are capped at `25 MB`.
- Built-in PDF import is capped at `50 MB`.
