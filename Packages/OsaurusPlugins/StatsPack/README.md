# Osaurus Stats Pack

First-party statistics/data-science format pack for the in-process v1
`FormatAdapter` ABI.

## Supported

- CSV with an optional JSON `.csvschema` sidecar. The sidecar may be either
  `data.csvschema` or `data.csv.csvschema`, and should contain
  `{ "columns": [{ "name": "field", "type": "string" }] }`.
- TSV as UTF-8 tab-delimited rows, with the same optional schema behavior via
  `.tsvschema` sidecars.
- Delimited rows stream without buffering the full file. Records include
  path-free metadata for delimiter, schema columns, header rows, line number,
  and column count.
- JSONL as one JSON value per line. Object records stream fields in sorted-key
  order; arrays and scalars stream positionally.
- SQLite read-only for `.sqlite`, `.sqlite3`, and `.db` files. The adapter uses
  Osaurus's existing vendored SQLCipher/SQLite surface and opens user-supplied
  databases read-only without applying a key, so it reads plaintext SQLite
  files directly. (A user-supplied SQLCipher-encrypted file would not be
  readable through this path; that is out of scope for the stats pack reader.)

## Deliberately Not Supported In v1

- CSV writes or workbook writes.
- Multiline quoted CSV fields in the stats pack reader. Core's structured CSV
  adapter remains the richer parser for high-fidelity document attachments.
- Parquet, Arrow, DuckDB, or TabularData.
- Python, JVM, or new parser runtime dependencies.
