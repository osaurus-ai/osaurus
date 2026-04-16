# Development Docs

This directory is the canonical home for long-lived development contracts,
roadmaps, and review templates that do not belong in the repo root.

Start here for the file-management roadmap:

1. [FILE_MANAGEMENT_ARCHITECTURE_REVIEW_AND_PR0.md](./FILE_MANAGEMENT_ARCHITECTURE_REVIEW_AND_PR0.md)
   - architecture review, placement policy, and the `PR0` rationale
2. [file-import-plugin-contract.md](./file-import-plugin-contract.md)
   - canonical importer manifest, request, response, and failure contract
3. [file-generator-export-contract.md](./file-generator-export-contract.md)
   - canonical generator/export manifest, request, response, and artifact rules
4. [file-management-dependency-review-template.md](./file-management-dependency-review-template.md)
   - dependency review checklist for core, native-plugin, and sandbox-plugin additions
5. [file-import-phased-pr-plan.md](./file-import-phased-pr-plan.md)
   - reviewable PR chain for `PR0` and the format packs that follow it

Working rules for this directory:

- Keep `OsaurusCore` conservative and fast.
- Prefer plugin-first capability growth for heavy or dependency-rich formats.
- Use one public PR per initiative.
- Do not mix substrate work, format packs, and unrelated build fixes in one branch.
- Keep terminology neutral in code and user-facing strings.
