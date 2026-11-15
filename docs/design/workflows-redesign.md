# Workflows redesign: implementation spec

Status: approved direction, ready to implement in phases.
Written against `main` at `aace5d0` (2026-11-15). File and type names below were read from that commit. Confirm each one still exists before relying on it.

The mockups live next to this file in `docs/design/workflows-redesign/`:

| File | Screen |
| --- | --- |
| `1-home.png` | Home |
| `2-workflow-detail.png` | Workflow detail with inline automations |
| `3-automate-popover.png` | Automate from the sidebar, plus the empty state of a manual workflow |
| `4-activity.png` | Activity |
| `5-share.png` | Share sheet |
| `sidebar.png` | The sidebar shared by every Workflows screen |

The screenshots are the source of truth for layout and hierarchy. This document is the source of truth for behavior, data, copy and scope. Where they disagree, this document wins.

## 1. Why

The audience is non-technical. Today the Workflows destination is a flat list, and automations live in a separate place (Settings, Automations) with a technical editor (When, Only When, Do, Queue, Reply). A person who wants "run Morning Brief every weekday" has to leave Workflows, find Automations, pick a trigger type and wire the workflow in.

The redesign makes one change in the mental model:

> An automation is something a workflow has, written as a sentence. It is not a separate place.

Everything else follows from that.

## 2. What does not change

Read this before writing code. The redesign is a new surface over existing systems.

- **No new automation engine.** An automation is still an `OsaurusEvent` whose `action` is `.workflow(WorkflowEventAction)`, created and edited through `EventManager.shared` (`create`, `update`, `setEnabled`, `delete`, `fireNow`). Storage stays `~/.osaurus/events/<id>.json`.
- **No new run ledger.** Runs come from `WorkflowRunStore` (workflow runs) and `EventManager.runs(eventId:limit:)` (automation fires). Tasks, History remains the canonical list of everything.
- **Settings, Automations stays.** It remains the full editor and the only place for agent-action automations, Ask a Model automations, queueing, filters and channel notes. The new UI is a simpler front door that covers the common cases and links there for the rest.
- **Share and publish already exist.** `Views/Template/ShareWorkflowSheet.swift`, `WorkflowShareService`, `WorkflowsRegistryAPIClient`, `WorkflowVisibility` (Public, Unlisted, Password, Workspace) and the review flow are kept. Screen 5 is a copy and layout pass on that sheet, not a new sheet.
- **Install from the store already exists.** Install links route through `TemplateImportRouter` and the setup wizard (`WorkflowSetupWizardView`). Reuse it for every "Add".
- **The Architect, drafts, run pages, setup wizard, hosted workflow links and workspaces keep working.** Section 5.1 says where each one lives in the new layout.

## 3. Rules for this repository

- Do not hard-code the mockup's hex colors, font sizes or spacing. The mockup was drawn in HTML to approximate the app. Use the design library tokens (`theme.space`, `theme.text`, `theme.surface`, `theme.border`, `theme.statusInk`, `theme.radius`, `theme.motion`) and the existing components in `Views/DesignSystem/`, `Views/Common/` and `Views/Management/SharedSidebarComponents.swift`.
- Column widths and breakpoints live in `Views/Chat/ChatShellLayout.swift` only. Extend it for the Workflows sidebar and extend `ChatShellLayoutTests`.
- `docs/design/shell-and-chat.md` is the source of truth for the window's information architecture. Its table says the sidebar belongs to the Chat destination. Update that document in the same pull request that gives Workflows a sidebar.
- All user-facing strings go through `L(...)`.
- Follow `AGENTS.md`: any user-facing setting that is added, moved or renamed needs its `SettingsSearchIndex` row, anchor id, guide update (`Resources/Guide/guide-workflows.md`, `guide-automations.md`) and `SettingsSearchSelfFindProbe` entry. The existing `workflows.*` and `automations.*` rows that describe the old header, tabs and row menus must be updated, not left stale.
- Update `docs/WORKFLOWS.md` and `docs/AUTOMATIONS.md` (their UI sections) in the pull request that changes the behavior they describe.
- Follow `docs/ACCESSIBILITY.md`. Status is never carried by color alone: every status dot or bar has a text or icon equivalent and an accessibility label.
- Tests: `make test`. Add unit tests for every pure model introduced below (sentence formatting, presets, sidebar list model, activity feed, health strip).
- Phases 1 to 5 in section 9 ship together in one pull request. Build them in order; each phase's "Done when" list is still checked on its own.

## 4. Vocabulary

Use these words in the UI. The code keeps its existing names.

| UI says | Code |
| --- | --- |
| Workflow | `InstalledWorkflow` |
| Automation, "runs on its own" | `OsaurusEvent` with `.workflow` action |
| Run by hand | A workflow with no enabled workflow-action event |
| Run | `WorkflowRun` |
| Activity | Projection of `WorkflowRunStore` and the event ledger |
| Pinned | New: `InstalledWorkflow.isPinned` |
| Osaurus Store | store.osaurus.ai, the registry |

Never show these words in the new surfaces: event, trigger, webhook, cron, ledger, lane, dedupe, payload. They may still appear under an explicit Advanced disclosure.

## 5. Screens

### 5.1 Sidebar (all Workflows screens)

The Workflows destination gets a sidebar in the same column the Chat destination uses. Build it from `SidebarContainer`, `SidebarSearchField`, `SidebarRowActionButton`, `SidebarRowBackground` and the section headers in `SidebarNavigation.swift`. Collapsing and compact-width behavior match the chat sidebar.

Contents, top to bottom:

1. Search field. Placeholder: `Search workflows`. Filters every list below by name and tags.
2. `Home` row.
3. `Activity` row. When any workflow-action automation's most recent run failed, or any is paused after a failure, show a badge: `1 issue`, `2 issues`.
4. Section `Pinned`. Hidden when nothing is pinned.
5. Section `All workflows`. Every installed workflow that is not pinned, sorted by name. Hosted workflow links (`HostedWorkflowLink`) appear here too, with the owner's name as the second line, as they do in the current list.
6. Section `Drafts`. Only while `WorkflowDraftStore` has drafts. A draft row opens the draft in the Architect, as the Drafts tab does today.
7. Section `Workspaces`. Only while this Mac belongs to a workspace. One row per workspace, opening the existing `WorkflowsWorkspacesTab` content in the content column.
8. Footer: `New workflow` button (existing New Workflow page, `WorkflowsPage.create`), then an `Osaurus Store` row with the second line `Workflows made by others` that opens `https://store.osaurus.ai/` in the default browser.

The old tabs (All, Drafts, Published, Workspaces) go away. Published is no longer a list: a published workflow shows a small published mark on its row and in its detail header (reuse the existing "Published. Click to manage." affordance). The existing "N published, M installs" line moves to the bottom of Home. Keep `WorkflowsTab` parsing so old `osaurus://workflows/<tab>` links still resolve: `all` and `published` go to Home, `drafts` scrolls the sidebar to Drafts, `workspaces` opens the workspace.

**Workflow row.** Two lines and two buttons.

- Status dot:
  - filled, positive: has at least one enabled automation and the latest automation run did not fail
  - filled, problem: latest automation run failed, an automation is paused after a failure, or the automation's target has a problem (`EventInspection.targetProblem`)
  - hollow: run by hand
  - a workflow with `needsSetup` uses the existing needs-setup treatment instead of a dot
- Line 1: workflow name.
- Line 2: the automation in a few words (section 6.1, short form). `Run by hand` when there is none. `Needs attention` in the problem state. With more than one automation: the first, then `+1 more`.
- Automate button (bolt icon). Accessibility label `Automate <name>`. Opens the popover in 5.4. Always visible, low emphasis.
- Run button (play icon). Accessibility label `Run <name> now`. Starts a run exactly as the current row's play button does (form first when the workflow needs input). Pinned rows use the filled style, others the outlined style.
- Clicking the row itself opens the workflow's detail (`WorkflowsPage.workflow(id)`).
- Context menu: Pin or Unpin, Run, Automate, Rename, Share, and the entries the current row menu already has (Publish or Manage Published, Save as File, Delete).

**Pinning.** New persisted fields on `InstalledWorkflow`: `isPinned: Bool` (decode with `decodeIfPresent`, default `false`) and `pinnedAt: Date?` for ordering (oldest pin first). Add `InstalledWorkflowStore.setPinned(_:id:)`. Not part of the template, never exported (same rule as `tags`). Add both to `CodingKeys` and to the round-trip tests.

Put the list logic in a pure, testable model in the style of `WorkflowListModel` in `WorkflowsPaneView.swift`: inputs are installed workflows, events, latest runs, drafts and the query; output is the sections and rows.

### 5.2 Home (`1-home.png`)

Home is `workflowsPath == []`. It answers three questions: is anything broken, what is running on its own, what else could I automate. It does not repeat the full workflow list. That is the sidebar's job.

First run (no workflows and no drafts) keeps today's behavior: the New Workflow page is the whole screen (`WorkflowsView.isFirstRun`).

Header: title `Workflows`. Subtitle is a count sentence built from state, for example `4 run on their own. 1 needs your attention.` Omit the second sentence when nothing needs attention. With no automations: `Nothing runs on its own yet.` Buttons: `Import` (existing import) and `New Workflow`.

Sections, in order. Hide a section when it has nothing to show.

1. **Running now.** The existing `WorkflowsRunningNow` view, unchanged, shown only while something is running or waiting on a form. (Not drawn in the mockup. Keep it.)
2. **Needs attention.** One banner per workflow in the problem state, most recent first, at most three, then `Show all in Activity`.
   - Title: `<Workflow> could not run <relative day>`.
   - Body: the plain-language failure sentence (section 6.3).
   - Primary button: the remedy from `WorkflowFailureRemedy` when there is one, with its existing title (`Open System Settings`, `Choose Folder`, `Choose a Model`), or the connection re-auth action when the failure is a connection (the detail page already has `Sign in again`). The mockup's "Reconnect mail" is an example of the connection case.
   - Secondary: `See what happened`, which opens Activity scrolled to that run, expanded.
3. **Pinned.** Subtitle `One click to run`. A grid of tiles, three per row at regular width. Each tile: name, the workflow's one-line description, last-run line (`Ran today, 8:00 AM`, `Failed yesterday`, `Not run yet`), and a `Run` button. Clicking the tile body opens the detail.
4. **Running on their own.** Subtitle `Your automations, and how the last 7 runs went`. Link on the right: `All activity`. One row per workflow-action event (enabled or not), grouped under their workflow's name when a workflow has several:
   - Icon for the trigger kind (the descriptor's `icon`).
   - Sentence: bold workflow name, then the long form from 6.1, for example `Morning Brief runs every weekday at 8:00 AM`.
   - Second line: next or last state. `Next: tomorrow at 8:00 AM` for schedules (from `ScheduleTiming`), `Watching. Last ran Friday` for folders, `Paused after a failed run yesterday` in the problem state, `Off` when disabled by the person.
   - Health strip: the last 7 settled runs of that event (6.2).
   - Switch bound to `EventManager.setEnabled`. Accessibility label `<Workflow> automation`.
   - Clicking the row opens the workflow's detail, scrolled to "When should this run?".
   - Below the list, when there are automations that run agents or prompts rather than workflows: `3 other automations run agents. Open Automations`, linking to Settings, Automations. Do not list them here.
5. **Ways to automate.** Subtitle `Pick a moment, then pick a workflow`. A grid of cards from the catalog in 6.4. Each card: icon, friendly title, one example line, and a state line: `On for 3 workflows` (count of enabled workflow-action events of that kind) or `Set up`. Clicking a card opens a picker of workflows, then the same inline editor as 5.3 for the chosen workflow and kind. Under the grid: `Building something custom? Webhooks and event streams live under Advanced.` The link opens Settings, Automations with the Add Automation picker.
6. **From the Store.** Phase 5. See 5.6.

### 5.3 Workflow detail (`2-workflow-detail.png`, and the empty state in `3-automate-popover.png`)

This reworks `Views/Workflow/Library/WorkflowDetailPage.swift`. Keep every capability it has today. Reorder so automations come first.

Header:
- Name and one-line description.
- Status line: `On. Next run tomorrow at 8:00 AM.` or `Only runs when you click Run. Not run yet.` or the problem sentence.
- Buttons: `Pin` or `Pinned` (toggle), `Edit` (opens in the Architect, existing), `Share` (existing share entry point, moved up from the footer), `Run now` (primary).

Body, two columns at regular width, one column when compact. Left column, in order:

1. **When should this run?** Helper: `Read it like a sentence. Click any word to change it.`
   - One card per workflow-action event for this workflow (`EventManager.events(forWorkflowID:)`).
   - Schedule card: `Every [weekday] at [8:00 AM]` where each bracketed word is a menu button. Day menu: every day, weekdays, one weekday (Monday to Sunday), every hour, every 30 minutes, first day of the month, `Custom…`. Time menu: a time picker. `Custom…` opens the existing `EventEditorSheet` for that event.
   - Folder card: `When a file shows up in [Downloads]`. The folder word opens the system folder picker (security-scoped bookmark, as `FolderSourceConfig` needs).
   - Feed card: `When [site] posts something new`. The word opens a field for the feed address.
   - Other kinds (run failed, app event, app webhooks): a fixed sentence from 6.1 and a `Change…` button that opens `EventEditorSheet`.
   - Every card has a switch (`setEnabled`) and a remove button (confirm, then `EventManager.delete`).
   - `Also run it` row: dashed chips `at another time`, `when Osaurus opens`, `when a file shows up`, `more ways`. A chip adds a new event with that kind's default from 6.5 and puts its card in edit state. `more ways` opens the catalog from 6.4 as a menu.
   - The "Or just say it" text field is Phase 6. Do not render it before then.
   - Empty state (no automations), replacing the cards: title `Want this to run on its own?`, helper `Pick a moment. You can change it or turn it off anytime.`, then three large choices: the suggested preset if there is one (6.5), `At a time I choose`, `When something happens`.
   - Workflows with required inputs: see 6.6.
2. **What it does.** The existing "You give", "Osaurus does", "You get" content, unchanged, under this one heading.
3. Everything else the page has today, unchanged and in its current order: what it needs before it runs, who can start it, tags, saved answers, stored data, Fix repeated failures automatically, Advanced.

Right column:

- **Recent runs.** Link `See all` opens Activity filtered to this workflow. Health strip of the last 14 settled runs and one summary line: `Everything is working. Last 14 runs all finished.` or `2 of the last 14 runs failed.` Then the five most recent runs: status icon, `Today, 8:00 AM`, how it started and duration (`On schedule, took 42 sec`, `You ran it, took 40 sec`), and `Open` (existing run page, `WorkflowsPage.run`). Live runs stay at the top as today. Empty state: `No runs yet. Try it once to see what you get.` with `Try it now`.
- **Share nudge.** Phase 5. See 5.6.

The mockup's "When it finishes" card (results to Inbox, notify me, pause on failure) is not in scope until Phase 6. Do not render it.

### 5.4 Automate popover (`3-automate-popover.png`)

Opened from a sidebar row's bolt button, anchored to the row (`Views/Common/AnchoredCardPresenter.swift`). The goal is one click from "manual" to "automated".

- Title `Run <name>…`, helper `One click and it is set.`
- When the workflow already has automations, list them first, each with its switch, then a divider and `Add another`.
- Up to three schedule presets from 6.5. The first is marked `Suggested` when a suggestion rule matched. The last is always `Pick a day and time…`, which closes the popover and opens the detail with a new schedule card in edit state.
- Divider, then: `When a file shows up in a folder…`, `When a site posts something new…`, `When an app has news…`. Each closes the popover and opens the detail with that card in edit state (folder goes straight to the folder picker).
- Footer link: `See all ways to automate`, which goes to Home and scrolls to that section.
- Choosing a preset creates the event immediately, closes the popover, updates the row's second line and shows a toast: `<Name> will run every weekday at 6:00 PM.` with `Undo` (deletes the event).
- The text field in the mockup is Phase 6.

### 5.5 Activity (`4-activity.png`)

New page: add `WorkflowsPage.activity` and a deep link `osaurus://workflows/activity`.

- Title `Activity`, subtitle `Everything your workflows did, newest first.`
- Filter chips: `All`, `Needs attention`, `Ran on their own`, `Run by me`. A menu `All workflows` filters to one workflow. Reuse `SettingsFilters` / `SettingsChips`.
- Rows grouped by day (`Today`, `Yesterday`, weekday name, then dates). Each row: status icon, time, workflow name, one line saying how it started and how it went, and `Open result` (run page).
- A failed run is expanded by default if it is the most recent run of its workflow and unresolved. Expanded content:
  - `What happened`: the plain-language sentence from 6.3.
  - The step list: each step with done, failed or skipped, using step names from the run (`WorkflowRun` node runs). The failed step shows its short reason.
  - Buttons: the remedy (as in 5.2), `Run again` (existing retry from the failed step), `Ask Osaurus to fix it` (opens the Architect on this workflow from the failed run, the path `workflow_test` `from_run` supports), and a quiet `Technical details` link that opens the existing run page.
- Feed model, pure and testable (`WorkflowActivityFeed`, modeled on `AutomationHistoryFeed`):
  - Source 1: `WorkflowRunStore.recentRuns` with test runs excluded (`WorkflowRun.isTest`), and runs whose `caller.kind` is `.workflow` (nested) excluded.
  - Source 2: `EventRun` rows for workflow-action events that ended `failed` without a workflow run id (admission-time failures such as a deleted target). Never show `filtered`, `duplicate` or `suppressed` rows.
  - "How it started" from `WorkflowCaller.Kind`: `.event` gives the trigger phrase (`Ran on schedule`, `A file was added to Downloads`), `.user` gives `You ran it`, `.agent` and `.orchestrator` give `<Agent name> ran it`.
  - `Ran on their own` is `.event`. `Run by me` is `.user`.
  - Page in batches of 50.
- Settings, Automations keeps its own History button (Tasks, History). Do not remove it.

### 5.6 Store (`5-share.png`, and the bottom of `1-home.png`)

Decision already made: browsing happens on the website in the default browser. No webview. The app handles adding, sharing and a small shelf natively.

- **Sidebar row** (Phase 1): opens `https://store.osaurus.ai/`.
- **Add** (exists): install links already open the setup wizard, which shows what a workflow does and what it can access. No change beyond making sure a link opened from the browser lands on the wizard with the new shell behind it.
- **Share entry points** (Phase 5): the `Share` button in the detail header and the row context menu open the existing `ShareWorkflowSheet`.
- **Share sheet copy pass** (Phase 5): add a two-panel summary above the visibility choice. Left, `What gets shared`: the steps (`The 4 steps it follows`), a suggested schedule if the workflow has one schedule automation (`A suggested schedule: weekdays at 8:00 AM`), and `What it needs access to: …` derived from the template requirements (`WorkflowRequirementsDeriver`). Right, `What stays on your Mac`: `Your results and run history`, `Your accounts and sign-ins`, `Your files, folders, and memory`. Sheet subtitle: `You share the recipe, never your data.` Each line must be true of what `TemplateExportSanitizer` actually exports. If a line cannot be guaranteed, drop that line rather than soften it. Keep all four `WorkflowVisibility` options and the existing review messaging. The mockup shows only two visibilities for brevity.
  - Open question for the owner: whether a suggested schedule should be exported with a template at all. If the template format has no place for it today, leave that line out and do not change the format in this project.
- **Share nudge** (Phase 5): a dismissible card at the bottom of Recent runs. Title `This one is working well`. Body `Others might want it too. Share the recipe to the Store. Your results and accounts stay on your Mac.` Link `Share to the Store`. Show it only when all are true:
  - the workflow was made on this Mac: `InstalledWorkflow.source == nil` and it is not a built-in starter (never nudge someone to republish another author's workflow)
  - it has no registry record (`WorkflowRegistryRecordStore`)
  - its last 10 non-test runs all completed, across at least 5 different days
  - the person has not dismissed it for this workflow (new persisted flag, per workflow, not exported)
  - at most one nudge is visible across the app per week
- **Home shelf** (Phase 5, needs backend): `From the Store`, subtitle `Shared by the people who made them`, link `Browse the Store`. Three listing cards (name, `by <author>`, `Add`) and a fourth dashed card: `Made something useful?` / `Share a workflow so others can use it.` / `How to share`. `Add` runs the existing install path for that listing. `WorkflowsRegistryAPIClient` has no browse or featured call today, so this needs a new public registry endpoint that returns a short featured list. Until that exists, ship only the dashed card and the `Browse the Store` link. Fetch at most once a day, cache the result, and render nothing while offline. No tracking parameters beyond what the registry already records on install.

## 6. Shared models and rules

### 6.1 Automation sentences

One pure formatter, `AutomationSentence`, with three outputs for an `OsaurusEvent`: short (sidebar line 2), long (Home rows, toasts) and editable parts (detail card). Unit test every row.

| Source | Short | Long, after the workflow name |
| --- | --- | --- |
| `.daily(h, m)` | `Daily at 8:00 AM` | `runs every day at 8:00 AM` |
| weekdays (see note) | `Weekdays at 8:00 AM` | `runs every weekday at 8:00 AM` |
| `.weekly(d, h, m)` | `Fridays at 4:00 PM` | `runs every Friday at 4:00 PM` |
| `.hourly(m)` | `Every hour` | `runs every hour` |
| `.everyNMinutes(n)` | `Every 30 min` | `runs every 30 minutes` |
| `.monthly(d, h, m)` | `Monthly on the 1st` | `runs on the 1st of every month at 9:00 AM` |
| `.yearly` | `Yearly on Mar 3` | `runs every year on March 3 at 9:00 AM` |
| `.once(date)` | `Once, Nov 20` | `runs once on November 20 at 9:00 AM` |
| other `.cron` | `Custom schedule` | `runs on a custom schedule` |
| `.folder` | `When Downloads changes` | `runs when a file is added to Downloads` |
| `.rss` | `When <site> posts` | `runs when <site> posts something new` |
| `.runFailed` | `When a run fails` | `runs when another workflow fails` |
| `.app` | `When Osaurus opens` | `runs when Osaurus opens` |
| `.webhook` with provider profile | `When GitHub has news` | `runs when GitHub has news` |
| `.webhook`, generic, and `.sse` | `Custom trigger` | `runs from a custom trigger` |

Notes:
- `ScheduleFrequency` has no weekday case. "Weekdays at H:M" is stored as `.cron(expression: "M H * * 1-5")`. The formatter must recognize that exact shape and render it as weekdays. Add a small recognizer for the cron shapes the presets write, and fall back to `Custom schedule` for everything else. Do not add a new enum case.
- Times and day names use the user's locale and 12 or 24 hour setting.
- Folder names show the last path component only.

### 6.2 Health strip

A pure function from `[EventRun]` (or `[WorkflowRun]` on the detail page) to up to N bars, oldest left.

- Count only settled attempts: succeeded, failed. Skip filtered, duplicate, suppressed, cancelled, queued, running, awaiting user.
- Fewer than N runs: pad on the left with empty slots.
- A failed bar differs from a succeeded bar in shape or height as well as color.
- The strip has one accessibility label summarizing it: `Last 7 runs all worked`, `Last run failed`, `2 of the last 7 runs failed`.

### 6.3 Plain-language failures

One pure function from a failed run to `(sentence, remedy?)`.

- Start from `WorkflowFailure.classify` and `WorkflowFailure.message`. Map each failure class to one calm sentence that says what Osaurus tried, what stopped it, and that nothing was lost when that is true. Example for an expired connection: `Osaurus tried to read your unread mail, but your mail account asked you to sign in again. Nothing was lost.`
- Unknown class: `<Step name> did not finish.` followed by the error's own message.
- Never show raw error codes, HTTP statuses or stack text outside `Technical details`.
- Remedy comes from `WorkflowFailureRemedy` or the connection re-auth action. No remedy means no primary button, only `Run again` and `Ask Osaurus to fix it`.

### 6.4 Ways to automate (catalog)

Built from `EventSourceRegistry` descriptors where `isOfferedInPicker` is true. Add two properties to `EventSourceDescriptor`, with defaults so existing kinds compile: `friendlyTitle` and `friendlyExample`. Settings, Automations keeps `displayName`.

| Kind | Friendly title | Example line | Where |
| --- | --- | --- | --- |
| `schedule` | At a set time | Every morning, every Friday, every hour. | Card |
| `folder` | When a file shows up | Watch a folder like Downloads or Desktop. | Card |
| `rss` | When a site posts something new | Follow a blog, a podcast, or a news feed. | Card |
| `webhook` with provider profiles | When an app has news | The provider names from `WebhookProviderProfile`, joined. | One card, then a provider picker |
| `runFailed` | When something goes wrong | Run a follow-up when another workflow fails. | Card |
| `app` | When Osaurus opens | Start the day with something ready for you. | Card |
| `webhook` generic, `sse` | not shown | | Advanced link only |
| `channelMessage`, `email` | not shown | | Channels owns these |

### 6.5 Presets and suggestions

Pure function from an `InstalledWorkflow` to an ordered list of presets. Each preset is a ready `OsaurusEvent` template: name `<Workflow name> schedule`, `.workflow` action with `inputMapping` from 6.6, delivery defaults from `EventDeliveryPolicy.defaults(for:)`.

Default schedule presets, in order: `Every weekday at 9:00 AM`, `Every day at 9:00 AM`, `Pick a day and time…`.

Suggestion rules, first match wins, and the match moves to the top marked `Suggested`:
1. The workflow came from a template or store listing that carries a suggested schedule: use it.
2. Name or description contains "morning": weekdays at 8:00 AM.
3. Contains "end of day", "evening" or "wrap": weekdays at 6:00 PM.
4. Contains "weekly" or "digest": Fridays at 4:00 PM.
5. Contains "download": folder preset on `~/Downloads` (needs the folder picker for the bookmark, so it is not one-click).

Keep the rules in one table so they are easy to edit and test. No model call here.

### 6.6 Workflows that need input

A scheduled run has nobody to fill in a form.

- If every required input has a default or a saved answer (`SavedAnswersStore`), one-click presets work: create the event with an empty `inputMapping`.
- If any required input has neither, the preset does not create the event immediately. Open the detail card in edit state with the existing `WorkflowInputBindingEditor` under the sentence, titled `What should it use each time?`, and enable the automation only when the required inputs are filled.
- Folder, feed and app triggers offer their payload fields through the same editor (it already does this).

### 6.7 State derivation

One observable, main-actor view model per window (`WorkflowsOverviewModel`) that the sidebar, Home and Activity badge all read, so they never disagree. It joins `InstalledWorkflowStore.shared.workflows`, `EventManager.shared` events filtered to `.workflow` actions, and the latest runs. It must not load full run history on the main thread: use `WorkflowRunStore.loadRecentRunsIfNeeded` and `EventManager.runs(eventId:limit:)` asynchronously and cache per event, refreshing on `.workflowRunFinished` and on event changes. Subscribe narrowly, as `WorkflowsRouteObserver` does, so chat activity does not re-render the Workflows window.

## 7. Routing

- `WorkflowsPage` gains `.activity`. Home stays `[]`. `.workflow(UUID)`, `.run`, `.create` are unchanged.
- The sidebar selection is derived from `workflowsPath.last`: Home, Activity, or the workflow whose page or run is on screen.
- With a sidebar present, the title bar back button still pops pushed pages (run page over detail). Selecting a sidebar row replaces the path rather than pushing onto it.
- New deep links: `osaurus://workflows/activity`, `osaurus://workflows/workflow/<id>`. Keep every existing link working.
- The chat inspector's Workflows lens (`WorkflowsPaneView`) is out of scope and unchanged.

## 8. Out of scope

- Any change to how automations execute, queue, dedupe or reply.
- Any change to Settings, Automations beyond updating search rows and guide text that point at moved things.
- Any change to the Architect, the run page, or the setup wizard's steps.
- A native store browser or any webview.
- Paid listings, wallet or credits in the store flows.
- Changing the template file format.
- Channel message automations.

## 9. Phases

Phases 1 to 5 are built in order and ship in one pull request. Phase 6 is not built.

**Phase 1: Sidebar and pinning.**
`isPinned` and `pinnedAt`, store method, the sidebar with all sections, row status and second line (needs `AutomationSentence` short form and `WorkflowsOverviewModel`), run button, context menu, Store row, tab removal with link compatibility, `ChatShellLayout` and shell doc updates. The bolt button is present and opens the workflow detail for now. Home shows the existing content minus the tabs.
Done when: every workflow, draft, hosted link and workspace reachable before is reachable now; a pin survives relaunch; old `osaurus://workflows/...` links resolve; layout tests pass at compact, regular and wide widths.

**Phase 2: Detail page with inline automations.**
Header changes, "When should this run?" with schedule, folder and feed cards, other kinds as fixed sentences, add chips, empty state, required-input handling, Recent runs column with the 14-run strip.
Done when: a person can create, change, turn off and remove a weekday schedule without leaving the page or seeing the word "cron"; the event written is identical in shape to one made in Settings, Automations and opens correctly there; an automation made in Settings shows up here.

**Phase 3: Automate popover and Home.**
Popover with presets, suggestions, toast with undo. Home sections 1 to 5, catalog descriptor properties.
Done when: from a manual workflow, two clicks produce a working schedule; Home counts match Settings, Automations for workflow-action automations; toggling a switch on Home is reflected in the sidebar and Settings at once.

**Phase 4: Activity.**
`WorkflowsPage.activity`, feed model, filters, expanded failures with plain-language text, remedies, Run again, Ask Osaurus to fix it, sidebar badge, Needs attention banners on Home.
Done when: a forced failure (for example a revoked folder grant) shows the banner on Home, the badge on Activity, an expanded row with a working remedy, and all three clear after a successful run.

**Phase 5: Store and sharing.**
Share button placement, share sheet copy pass, share nudge with its rules, Home shelf (dashed card and link first; listing cards once the registry endpoint exists).
Done when: the nudge never appears for a workflow installed from the store or already published; every "stays on your Mac" line is backed by the sanitizer's tests.

**Phase 6: Needs owner decisions before starting (do not build yet).**
- *Pause after a failure.* Today a failing automation keeps firing. Proposal: a per-event failure policy, default "pause and tell me" for automations created in the new UI and unchanged for existing ones, with a stored paused marker so the UI can tell "paused after failure" from "turned off by me". This touches `OsaurusEvent`, `EventManager.finalize`, declarative config (`ConfigEvents`) and migration, so it needs sign-off. Until it ships, the problem state is simply "the latest run failed", and the copy `Paused after a failed run` must not be used.
- *Say it in words.* A text field that turns "the first Monday of every month at 9" into a schedule. No parser exists in the repo. Proposal: a deterministic parser for common phrases first, a single tool-less model call as fallback, and always show the resulting sentence for confirmation before saving.
- *When it finishes.* Where results go and whether to notify. Depends on what the Inbox and notification settings support per workflow today.

## 10. Copy reference

Strings not already given above.

| Place | String |
| --- | --- |
| Sidebar search | `Search workflows` |
| Sidebar sections | `Pinned`, `All workflows`, `Drafts`, `Workspaces` |
| Sidebar footer | `New workflow`, `Osaurus Store`, `Workflows made by others` |
| Row, no automation | `Run by hand` |
| Row, problem | `Needs attention` |
| Home subtitle | `%d run on their own.` / `%d needs your attention.` / `Nothing runs on its own yet.` |
| Detail status | `On. Next run %@.` / `Only runs when you click Run.` / `Not run yet.` |
| Detail empty | `Want this to run on its own?` / `Pick a moment. You can change it or turn it off anytime.` |
| Add chips | `Also run it`, `at another time`, `when Osaurus opens`, `when a file shows up`, `more ways` |
| Input step | `What should it use each time?` |
| Popover | `Run %@…`, `One click and it is set.`, `Suggested`, `Pick a day and time…`, `See all ways to automate` |
| Toast | `%@ will run %@.` with `Undo` |
| Recent runs | `Everything is working. Last %d runs all finished.` / `%d of the last %d runs failed.` / `No runs yet. Try it once to see what you get.` |
| Activity | `Everything your workflows did, newest first.`, `All`, `Needs attention`, `Ran on their own`, `Run by me`, `All workflows`, `What happened`, `Run again`, `Ask Osaurus to fix it`, `Technical details`, `Open result` |

Plural forms must use the localization system's plural support, not string concatenation.

## 11. Edge cases to handle

- An automation whose workflow was deleted: not listed under any workflow. It stays visible in Settings, Automations, as today.
- A workflow with `needsSetup`: Run opens setup, automations can be created but show `Finish setup to run` instead of a next-run time.
- A hosted workflow link (runs on a teammate's Mac): can be pinned and run, cannot be automated or shared from here. Hide the bolt button and Share.
- A one-shot schedule that already fired: shown as off with `Ran once on <date>`.
- An event that is disabled by the person: listed with its switch off. It does not count toward "run on their own" and its workflow's dot is hollow unless another automation is on.
- Several automations on one workflow: sidebar shows the first plus `+N more`. The status dot is the worst state among them.
- Time zone change or daylight saving: next-run text comes from `ScheduleTiming`, never from a cached string.
- A very long workflow name: truncate in the sidebar with a tooltip, wrap to two lines in tiles and headers.
- Reduced motion and increased contrast: follow the existing design library behavior.
- Empty search: `SidebarNoResultsView`.

## 12. Verification

- Unit tests for: `AutomationSentence` (every row in 6.1, both clock styles), the cron recognizer, presets and suggestion rules, health strip, sidebar list model, activity feed merging and filters, failure sentence mapping, pin persistence round trip, nudge eligibility.
- `ChatShellLayoutTests` extended for the Workflows sidebar.
- `SettingsSearchSelfFindProbe` updated for every label that moved.
- Manual pass per phase following the "Done when" lines, in a fresh isolated build as `AGENTS.md` requires for user-facing lifecycle changes. Report anything unverified as partial rather than done.
