# Business Document I/O Workbench

The Business Document Workbench is the user-visible surface for importing,
previewing, extracting, and exporting business documents without routing the
file through chat.

## Import and Preview

- Imports flow through `BusinessDocumentStudioService`, which selects registered
  document adapters and applies the same high-fidelity parser limits used by the
  document/file-read stack.
- CSV and TSV files surface delimited-table previews with inferred columns and
  sampled rows.
- XLSX files surface workbook summaries, sheet samples, formula counts, merged
  ranges, validation findings, and XLSX emitter availability.
- PDF files surface typed page previews, extracted text, detected tables, and
  explicit creation availability.
- PPTX and POTX files surface slide previews, hidden-slide and speaker-note
  counts, table samples, and explicit creation availability.

Unsupported extensions stay in an unsupported import state. Malformed files stay
in an extraction-failure state with the adapter error surfaced to the user.

## Business Extraction Summary

The workbench now derives a format-neutral business summary from the parsed
representation:

- Field summaries list CSV columns, workbook header cells, slide text sections,
  and rich-text blocks with source labels, filled/empty counts, value kinds, and
  bounded samples.
- Table summaries list CSV files, worksheets, detected PDF tables, and slide
  tables with row/column/cell counts and a first sampled row where available.
- PDF and slide preview sections include sampled table rows, not just table
  counts, so users can verify extracted structure before exporting.
- Workspace attachment handoff is surfaced through the existing
  `Attachment.structuredDocument(_:)` API. The workbench reports whether a text
  fallback is available and can create an attachment that carries structured
  document metadata without touching workspace routing code. Empty text
  fallbacks are reported as unavailable and attachment creation fails with a
  typed workbench error instead of creating a misleading empty attachment.

## Export and Artifacts

Export actions are explicit and format-aware:

- CSV and TSV exports use `CSVTableWorkflowService`.
- XLSX exports use `WorkbookWorkflowService` and require a registered workbook
  emitter plus validation success.
- PDF and PPTX creation is reported as unavailable until a structured emitter is
  registered. The workbench must not fake binary package output through text
  writes.
- Text fallback export is allowed only to text-shaped targets and is capped by
  `BusinessDocumentStudioExportPolicy.maxTextExportUTF8Bytes`.

Existing destinations require overwrite consent before the presenter calls the
service with `allowOverwrite: true`. The artifact status list records created,
blocked, failed, and consent-required states so the UI can show whether a file
was actually written.

## Safety Rules

- Do not write text fallback data to `.xlsx`, `.pdf`, `.pptx`, or related
  package-shaped extensions.
- Do not report PDF/PPTX creation as available without a registered structured
  emitter.
- Do not inspect destination existence outside the allowed export directory.
- Keep blocked and failed export states visible as artifact status rows rather
  than silently dropping them.
