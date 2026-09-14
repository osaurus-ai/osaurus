# Embedding request identity: issue #2759

Issue: https://github.com/osaurus-ai/osaurus/issues/2759

At main `ad4de6abd`, `EmbeddingRequest` decodes the requested model but
`HTTPHandler.handleEmbeddings` calls the shared `EmbeddingService` without
checking that model. The service has one Model2Vec backend, Potion base 4M,
with 128 dimensions. The API therefore silently returns a different model's
vectors for requests naming mxbai-embed-large-v1 or bge-small-en-v1.5.

A local isolated Release baseline built from `e82c6e61b` reproduced both
requests: HTTP 200, response model `potion-base-4M`, two 128-dimensional vectors.
The handler/service implementation is unchanged between that baseline and
`ad4de6abd`. Raw responses and source/binary receipts are retained under
`/Users/eric/vmlx-private-evidence/embedding-model-2026-09-14/`.

The correction accepts the backend's public ID `potion-base-4M` and publisher
ID `minishlab/potion-base-4M`. Every other requested identity gets HTTP 400
before embedding initialization. OpenAI routes return an
`invalid_request_error` with `param: model` and
`code: unsupported_embedding_model`; Ollama routes return their string error
shape. Caller-controlled IDs are JSON encoded, including quotes and newlines.
Successful responses retain the canonical backend ID.

This prevents silent model substitution. It does **not** implement arbitrary
BERT/BGE/mxbai backend loading. The internal retrieval indexes remain on their
existing model and dimension; changing them would require separate migration
and runtime qualification. Requested dimensions/encoding formats are also
outside this model-selection correction.

Validation is pending for the new source: focused service and real NIO endpoint
tests, followed by a fresh isolated Release API/UI run. No fixed/merged status
is claimed here until those artifacts are recorded.
