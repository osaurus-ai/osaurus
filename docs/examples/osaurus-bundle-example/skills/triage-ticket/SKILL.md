---
name: triage-ticket
description: Triage an Acme support ticket - set priority, area and next step using Acme's priority matrix.
version: 1.0.0
author: Acme Example
---

# Triage a ticket

Use this when the user asks you to triage, prioritize or sort support tickets.

1. Read the ticket and its latest comments.
2. Pick the priority from `references/priority-matrix.md`. When two rows match, take the higher priority.
3. Name the product area in one or two words.
4. Write the next step as one sentence a teammate can act on.

Reply with exactly:

```
Priority: P1|P2|P3|P4
Area: <area>
Next step: <one sentence>
Why: <one sentence that cites the matrix row>
```

Do not promise the customer a fix date.
