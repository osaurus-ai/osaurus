# Integration with upstream

This merge preview applies to the October 28 handoff. The [final Beta 40 handoff](FINAL-BETA40.md) uses a newer base.

Checked 28 October 2026 against `osaurus-ai/osaurus-workflows`.

- Original beta baseline: `834c7a437ef31626115545794bf3583296542640`.
- This branch: `design/ux-library-handoff-oct28`.
- Latest fetched `workflows`: `766e1e275065b706f811895c4d033334a4c62e09` (52 commits beyond the baseline).
- Latest fetched `main`: `bd9e55cff8c1a412b60c9b06856fdedfc7270a83`.

This package preserves the version Neesh has been designing against. It has not been rebased onto the newer app changes. A Git merge preview found 23 conflicting files. The list below is a mechanical conflict report, not a determination of which implementation should win.

## Suggested integration

1. Check out this branch to review the delivered UX and saved styles in isolation.
2. Create a separate integration branch from your current app branch.
3. Merge this branch there. Resolve conflicts by retaining new upstream behavior alongside the delivered shared components, token assignments and UX. Do not replace an entire conflicted file with one side.
4. Review chat/composer, workflows, model selection and settings paths affected by conflict resolution. Use the bundled design-library tests as a quick regression check.
5. Review with Neesh before publishing the design update.

## Conflicts from the preview

```text
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Managers/Chat/ChatWindowManager.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Models/Configuration/ManagementTab.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Agent/ShareAgentSheet.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/ChatSessionSidebar.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/ChatView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/ClarifyPromptOverlay.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/ComputerUseConfirmOverlay.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/HostedRunNotice.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/NativeBlockViews.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/NativeDispatchBadgeRow.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Chat/NativeMessageCellView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Common/SharedHeaderComponents.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Credits/CreditsView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Identity/IdentityView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Model/ModelDownloadView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Model/ModelPickerView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Plugin/PluginsView.swift
CONFLICT (modify/delete): Packages/OsaurusCore/Views/Settings/OsaurusConnectView.swift deleted in upstream/workflows and modified in HEAD.  Version HEAD of Packages/OsaurusCore/Views/Settings/OsaurusConnectView.swift left in tree.
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Theme/ShareThemeSheet.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Workspaces/WorkspaceDetailView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Workspaces/WorkspacePoolActivityView.swift
CONFLICT (content): Merge conflict in Packages/OsaurusCore/Views/Workspaces/WorkspaceSheets.swift
```
