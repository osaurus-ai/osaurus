# Chat Document Intake

Chat uses one document intake path for the composer picker, file drops, and
clipboard file attachments. A selected document is parsed and inspected before
it is added to the pending attachment list.

## Intake Contract

- The source must be a regular file and remain unchanged for the full parse and
  inspection operation.
- Intake rejects oversized sources before hashing. The ceiling is the smaller
  of the format-specific `DocumentLimits` value and the chat parser's 10 MB
  limit (for example, plain text remains limited to 5 MB).
- The preview is bounded by the existing business document policies and shows
  parsed samples, truncation state, security findings, and export availability.
- Attach is explicit. Cancel does not add the document to the chat.
- Active content is reported but never executed. Chat receives only the parsed
  text fallback.
- Persisted provenance contains source and parsed-content SHA-256 digests,
  source trust, inspection and source modification times, and a path-free stable
  source identifier. It never contains the source path.
- Persisted document text is digest-verified before later-turn reinjection. A
  missing, corrupt, oversized, or mismatched blob is omitted rather than sent to
  the model.
- Image-only PDF pages use the same provenance contract. Their rendered bytes
  are digest-verified before multimodal model input or ZIP export.
- Clipboard file chips remain available until intake succeeds and the user
  attaches the preview; failed, canceled, or dismissed intake can be retried.

## Conversion And Export

Available conversions use `BusinessDocumentStudioService`. Missing emitters and
validation failures remain visible as unavailable actions. Existing destinations
require explicit overwrite consent. Every export is written to a private sibling
temporary file first. No-overwrite publication uses an atomic create-new
operation, while approved replacement uses an atomic rename, so cancellation or
emitter failure cannot leave a partial destination.

Chat ZIP exports include `provenance.json`. The manifest records basename-only
labels, exported attachment names, availability or integrity status, and the
path-free provenance sidecar. Missing or corrupt payloads are represented in the
manifest and are not silently exported.
