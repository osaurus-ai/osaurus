# High-Fidelity Read File Audit

This audit records the current document-input path after the maintainer
direction to improve `file_read` and folder-context behavior before adding new
default tools.

## Current read path

`file_read` is the default document ingress surface for selected folders. It
keeps text and CSV on the raw line-numbered path, routes text-extractable PDF,
PowerPoint, rich text, HTML, and Word-like files through `DocumentParser`, and
uses the XLSX adapter for bounded workbook previews with optional sheet and row
selection.

`sandbox_read_file` is not part of this high-fidelity path today. It remains a
raw sandbox file reader, so any future claim that "read file handles documents"
must name the folder-context `file_read` surface unless the sandbox reader is
explicitly upgraded.

Folder-context plugin hints stay bias-only. The scanner detects `.xlsx`,
`.pptx`, and `.csv` so installed spreadsheet/presentation plugins can be
preloaded by preflight, but PDF and Word-like documents do not add tool-surface
weight because core `file_read` already owns their read path.

## Coverage Matrix

| Format | Current surface | Proof |
| --- | --- | --- |
| CSV/TSV | Raw line-numbered `file_read`; structured adapter and table workflow previews remain available for explicit document parsing/export paths | `FileReadDocumentFormatsTests.fileReadCSVStaysRawLineNumbered`, `CSVAdapterTests`, `CSVTableWorkflowServiceTests` |
| XLSX | Bounded workbook preview through `file_read`, with sheet, row, row-cap, column-cap, formula, merged-range, and security summary controls | `FileReadWorkbookTests`, `XLSXAdapterTests` |
| PPTX | Text extraction through `file_read` and the in-tree PPTX adapter; typed workflow previews expose slide, hidden-slide, notes, and table metadata | `FileReadDocumentFormatsTests.fileReadExtractsPPTXSlideText`, `PPTXAdapterTests`, `PDFPPTXWorkflowServiceTests` |
| PDF | Text-layer extraction through `file_read` and the in-tree PDF adapter; typed workflow previews expose page, text-layer table, cell, and bounding-box metadata | `FileReadDocumentFormatsTests.fileReadExtractsPDFTextLayerPages`, `PDFAdapterTests`, `PDFPPTXWorkflowServiceTests` |
| Images / scanned PDF | Refused by `file_read` with a pivot to attachment, OCR, or vision workflow | `FileReadDocumentFormatsTests.fileReadRefusesImagesWithImagePivot`, `PDFAdapterTests.parse_throwsEmptyContentForPDFWithNoTextLayer` |

## Follow-Up Lanes

1. `T-P1-HF-XLSX-READ-FILE-PREVIEW`: improve workbook preview metadata only if
   current UX evidence shows sheet/range/formula/security summaries are not
   enough.
2. `T-P1-HF-PPTX-PDF-INPUT-FIDELITY`: improve slide/table extraction where
   fixture tests show specific misses, without adding default tools.
3. `T-P2-HF-OUTPUT-SAFETY`: handle export/write safety after input fidelity is
   green, split by file family when acceptance criteria are complete.
4. Decide whether `sandbox_read_file` should remain a raw sandbox utility or
   gain the same document-adapter path as folder `file_read`. That choice
   changes sandbox expectations and should be a separate, explicit lane.
5. `T-P1-HF-FILE-READ-RAW-BOUNDS`: cap raw text/CSV reads before loading the
   whole file so output truncation is not the first memory/performance bound.
