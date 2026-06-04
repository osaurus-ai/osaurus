# High-Fidelity Output Safety Audit

This audit records the current write path for generated files after the input
fidelity lanes moved workbook reading into core `file_read`.

## Current Write Path

`file_write` remains a UTF-8 text/code tool. It creates parent directories and
writes atomically, but it now refuses `.xlsx`-family workbook targets so an
agent cannot create an invalid OOXML package by writing plain text with a
workbook extension. For tabular text output, agents should write CSV/TSV.

Structured workbook output stays on the document-emitter/plugin path.
`XLSXEmitter` assembles an OOXML ZIP package in memory, validates workbook
bounds before writing, rejects formulas instead of flattening them, rejects
workbooks with no renderable cells, rejects overlong cell text and invalid XML,
and only then writes the package atomically.

Tool exposure stays narrow. Folder plugin hints only bias installed spreadsheet
plugins, preflight injection respects installed plugin ids and per-agent
allowlists, and default-agent `capabilities_load` cannot load plugin tools.
No workbook writer is added to the default schema.

## Coverage Matrix

| Surface | Safety contract | Proof |
| --- | --- | --- |
| `file_write` | Text-only writes; rejects `.xlsx`-family targets before logging or touching the existing file | `FolderToolsResilienceTests.fileWrite_rejectsWorkbookPackagesWithoutTouchingExistingFile` |
| CSV output | Text tabular output remains allowed through `file_write` | `FolderToolsResilienceTests.fileWrite_allowsCSVTextOutput` |
| XLSX emitter | Valid scalar workbooks round-trip through the XLSX adapter | `XLSXEmitterTests.emit_roundTripsScalarWorkbookThroughXLSXAdapter` |
| XLSX formula safety | Formula cells are rejected, while formula-looking strings stay inert shared strings | `XLSXEmitterTests.emit_rejectsFormulaCellsWithoutFlatteningThem`, `XLSXEmitterTests.emit_keepsFormulaLookingTextInert` |
| XLSX bounds | Empty exports, whitespace-only exports, overlong cell text, invalid names/references, non-finite numbers, and ZIP32 overflows are rejected before package write | `XLSXEmitterTests`, `XLSXAdapterTests` |
| Tool exposure | XLSX plugin injection is bias-only, installed-plugin gated, and allowlist-respecting | `PreflightCapabilitySearchTests.folderInjection_*`, `FolderPluginHintsTests` |

## Follow-Up Lanes

1. Add first-party workbook write UI/tooling only when it can call the
   structured emitter directly and surface save/share state as an artifact.
2. Extend the same text-only `file_write` refusal pattern to other structured
   binary families if their output emitters become production-ready.
3. Keep sandbox write parity separate: `sandbox_write_file` has a different
   filesystem boundary and should be audited in its own lane before changing
   behavior.
