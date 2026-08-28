# High-Fidelity Output Safety Audit

This audit records the current write path for generated files after the input
fidelity lanes moved workbook reading into core `file_read`.

## Current Write Path

`file_write` remains a UTF-8 text/code tool. It can return a dry-run diff and
risk warnings before applying, creates parent directories when explicitly
applied, writes atomically, and refuses structured package targets (`.xlsx`,
`.pdf`, `.pptx` families) so an agent cannot create invalid office/PDF output by
writing plain text with a package extension. For simple tabular text output,
agents can still write CSV/TSV text; structured CSV/TSV conversion/export uses
the explicit document workflow path below.

Structured table output stays on the document-emitter/plugin path.
`CSVTableWorkflowService` previews bounded samples, reports schema/type
metadata, validates export bounds and formula-like spreadsheet prefixes, then
emits CSV/TSV through `CSVEmitter`.

Structured workbook output stays on the document-emitter/plugin path.
`WorkbookWorkflowService` inspects typed workbooks, reports validation issues
and emitter availability, and exports only through a registered document
emitter. `XLSXEmitter` assembles an OOXML ZIP package in memory, validates
workbook bounds before writing, rejects formulas instead of flattening them,
rejects workbooks with no renderable cells, rejects overlong cell text and
invalid XML, and only then writes the package atomically.

PDF/PPTX creation remains diagnostic-only in core. `PDFPPTXWorkflowService`
reports whether a structured emitter is registered for a typed PDF/PPTX
document; on current main it returns `missingEmitter`, keeping fake binary
packages off the text-only `file_write` path.

Business Document Studio is the format-neutral orchestration layer above these
services. It parses through `DocumentFormatRegistry`, returns bounded CSV,
workbook, PDF/PPTX, rich-text, or text previews, reports export availability,
contains explicit export destinations when a caller supplies an allowed
directory, and rejects text-fallback writes to structured package extensions.
It does not add a default agent tool or an arbitrary-path HTTP file endpoint.

Tool exposure stays narrow. Folder plugin hints only bias installed spreadsheet
plugins, preflight injection respects installed plugin ids and per-agent
allowlists, and default-agent `capabilities_load` cannot load plugin tools.
No workbook writer is added to the default schema.

## Coverage Matrix

| Surface | Safety contract | Proof |
| --- | --- | --- |
| `file_write` | Text-only writes; rejects `.xlsx`, `.pdf`, and `.pptx`-family targets before logging or touching the existing file | `FolderToolsResilienceTests.fileWrite_rejectsWorkbookPackagesWithoutTouchingExistingFile`, `FolderToolsResilienceTests.fileWrite_rejectsPDFAndPresentationPackagesWithoutTouchingExistingFile` |
| Dry-run write/edit | `dry_run: true` returns a bounded diff/risk preview, does not mutate files, and does not log fake operations | `FolderToolsResilienceTests.fileWrite_dryRunPreviewsDiffWithoutWritingOrLogging`, `FolderToolsResilienceTests.fileEdit_dryRunPreviewsDiffWithoutMutatingOrLogging` |
| Operation history | Applied file writes/edits are visible through a session-scoped history tool | `FolderToolsResilienceTests.fileWrite_applyLogsInspectableOperationHistory` |
| CSV output | Text tabular output remains allowed through `file_write` | `FolderToolsResilienceTests.fileWrite_allowsCSVTextOutput` |
| CSV/TSV workflow | Explicit table export validates row/cell bounds and formula-like spreadsheet prefixes before writing CSV/TSV through an emitter | `CSVTableWorkflowServiceTests` |
| XLSX emitter | Valid scalar workbooks round-trip through the XLSX adapter | `XLSXEmitterTests.emit_roundTripsScalarWorkbookThroughXLSXAdapter` |
| XLSX formula safety | Formula cells are rejected, while formula-looking strings stay inert shared strings | `XLSXEmitterTests.emit_rejectsFormulaCellsWithoutFlatteningThem`, `XLSXEmitterTests.emit_keepsFormulaLookingTextInert` |
| XLSX bounds | Empty exports, whitespace-only exports, overlong cell text, invalid names/references, non-finite numbers, and ZIP32 overflows are rejected before package write | `XLSXEmitterTests`, `XLSXAdapterTests` |
| PDF/PPTX creation diagnostics | Typed PDF/PPTX workflows report registered emitters or `missingEmitter` and do not route creation through text writes | `PDFPPTXWorkflowServiceTests` |
| Workbook workflow | Workbook inspection reports sheet/cell/formula/merged-range counts, validation reason codes, and missing-emitter state before export | `WorkbookWorkflowServiceTests` |
| Business Document Studio | Unified inspect/export path wraps CSV/TSV, XLSX, PDF/PPTX, rich text, and text fallback workflows without adding default tools or unsafe package-shaped text writes | `BusinessDocumentStudioServiceTests` |
| Tool exposure | XLSX plugin injection is bias-only, installed-plugin gated, and allowlist-respecting | `PreflightCapabilitySearchTests.folderInjection_*`, `FolderPluginHintsTests` |

## Follow-Up Lanes

1. Add first-party workbook write UI/tooling only when it can call
   `WorkbookWorkflowService.export` and surface save/share state as an
   artifact.
2. Keep extending structured creation only through real emitters, artifact
   surfacing, and validation errors; do not add package-shaped text writes.
3. Keep sandbox write parity separate: `sandbox_write_file` has a different
   filesystem boundary and should be audited in its own lane before changing
   behavior.
