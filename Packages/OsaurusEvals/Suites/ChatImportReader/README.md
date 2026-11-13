# Chat Import Reader Eval Suite

Real-world shapes of pasted setup instructions, run through chat import's
fast paths, the isolated reader (`report_import`), and the verifier with no
network and no install (`ChatImportEvalHarness`). Each `documents` entry
stands in for a downloaded page (`d1`, `d2`, … in order); the case `query`
is the user's message, which values may also be grounded in.

Scoring is per item: a row of the expected `kind` whose name contains
`name` (found, survived verification, correct kind). `forbidden` values
(an injected or invented URL, a secret) must not appear in any row. Rows
the fast paths handle report "reader not needed"; every reader row records
tok/s. Add a fixture whenever a pasted format imports wrongly.
