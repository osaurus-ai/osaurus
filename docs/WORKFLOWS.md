# Workflows

A workflow is a fixed, acyclic graph of steps with a typed input and a typed output. The **Architect** (a built-in agent) designs them in chat; a template installs one on a Mac; a tab, an agent, the Orchestrator, a background task, the HTTP API, or MCP runs it. Every step is declarative and reviewable — the person can read what a workflow does before it runs, and the runner records what it did.

Every workflow run is also a **Task** (`TaskWork.workflowRun`): automation-fired runs are admitted by the task scheduler, and every other run is recorded on the Default queue so the Tasks tab and Insights show it. See `docs/TASK_QUEUE.md`; the `WorkflowRun` stays the per-step record opened from the task.

This is the developer reference: the model, the trust rules, the Architect's tools, and where the code lives. The user-facing guide ships in the app as `Packages/OsaurusCore/Resources/Guide/guide-workflows.md` (Help → Workflows) and is the authority for on-screen behavior.

---

## Model

`WorkflowDefinition` (`Models/Workflow/WorkflowDefinition.swift`):

| Field | Meaning |
| --- | --- |
| `input_schema` / `output_schema` | JSON Schema. The input schema becomes the tool arguments when an agent calls the workflow. |
| `nodes` | `WorkflowNode`: `id`, `name`, `intent`, `kind` + spec, `input` (binding), `output_schema`, `timeout`, `retry {max_attempts, backoff_seconds}`, `on_error` (`fail` \| `continue` \| `skip`), `join` (`any` \| `all`). |
| `edges` | `WorkflowEdge`: `from`, `to`, optional `when` (a `WorkflowCondition` evaluated against the **source** step's output), `on` (`success` \| `error` \| `always`). |
| `output` | A binding that assembles the result from `{{nodes.<id>.output…}}`. |
| `examples` | Named example inputs; the first is what **Fill with Example** and `workflow_test` use. |
| `models`, `secrets`, `dependencies`, `folders` | Declared requirements (see Requirements). |

### Bindings

`{{input.x}}`, `{{nodes.<id>.output.x}}`, `{{run.id}}`, `{{run.workspace}}`, `{{caller.kind}}`, `{{caller.agent_id}}`, `{{caller.agent_name}}`, `{{folders.<key>}}`, and inside a `map` step `{{item}}` / `{{index}}`. A binding is a template string or an object of template strings (`WorkflowBinding`); `BindingRenderer` renders it. Mixed text interpolates objects and lists as compact JSON, except in dialog and reply messages, which people read: there `renderReadableText` lays them out as labelled lines and bullets. Content from earlier steps or from an agent-supplied input never enters a model's system prompt: the prompt gets a `[[ref:N]]` placeholder and the content travels in the user message inside `<untrusted_content>`.

### Node kinds

| Kind | Spec | Output | Executor |
| --- | --- | --- | --- |
| `inference` | `model_slot`, `instructions`, `mode` (`generate` \| `decide {options}` \| `agentic {tools, max_steps ≤ 12}`), `temperature` | JSON matching `output_schema` | `WorkflowNodeExecutor` / `AgenticNodeExecutor` |
| `dialog` | `title`, `message`, `fields[]` (text, choices, bool, files, folder, secret; `persistence` remembers answers) | the answers | `DialogNodeExecutor`, `DialogCoordinator` |
| `code` | `source`, `language` (`javascript` default \| `python`), `network[]`, `secrets[]`, `timeout` | whatever `run` returns | `CodeNodeExecutor` (sandboxed JS helper), `PythonCodeNodeExecutor` (workflow sandbox) |
| `tool` | `tool {name, server?, plugin?, agent?}`; the node's `input` is the arguments | the tool's JSON, or `{text}` | `ToolNodeExecutor` |
| `http` | see below | `{status, ok, headers, body}` (+ `pages`, `complete` when paginating) | `HTTPNodeExecutor` |
| `wait` | `seconds` or `until` (≤ 30 days; bindings allowed) | `{waited_seconds, resumed_at}` | `WaitNodeExecutor` |
| `map` | `items` (binding to an array), `step` (a node spec without id), `concurrency` (4, ≤ 16), `on_item_error` | `{items, count, failed}` | `WorkflowRunner` |
| `workflow` | `workflow` (an installed workflow's name) | that workflow's output | `SubworkflowNodeExecutor` (depth ≤ 8, no cycles) |
| `state` | `action` (`get` \| `set` \| `increment` \| `delete` \| `list` \| `clear`), `table` (default `vars`), `key`, `value`, `by`, `limit` | per action, e.g. `get → {exists, value, updated_at}` | `WorkflowStateStore` |
| `reply` | `text`, optional `file` and `caption` (templates) | `{sent, platform, room_id, thread_id, …}`; `sent: false` with a `reason` when no channel conversation started the run | `ReplyNodeExecutor` |
| `media` | `action` (`generate` \| `edit` \| `upscale` \| `video`), `model`, `prompt`, `sources`, size/steps/guidance/seed/count and sampler options | `{images, videos, model, backend, count, duration_ms}` | `MediaNodeExecutor` |
| `agent` | `agent` (a local agent's name, or a teammate's shared agent with `workspace`), `task` (template) | `{text, agent, session_id, needs_input, …}` | `AgentNodeExecutor` |

`WorkflowValidator` rejects what the runner would refuse (cycles, unknown bindings, bad schemas, credentials in headers or query parameters, private hosts, over-cap values) and `WorkflowRequirementsDeriver` derives what a definition needs from the graph.

### HTTP steps

`HTTPSpec`: `method` (GET default), `url` (template), `query` (name → template, percent-encoded), `headers`, `body` (string or JSON object), `auth`, `allowed_hosts`, `response` (`json` \| `text`), `fail_on_error`, `paginate`.

- **Auth** names declared secrets, never values: `{type: "connection", secret}` (a login declared with `declare_connection`, sent as Bearer), `bearer`, `basic {user_secret?, password_secret}`, `header {name, secret}`, `query {name, secret}`. The validator refuses `Authorization`, `Cookie`, and API-key headers set directly, and anything in a header or query parameter that looks like a pasted key. The runner redacts secret values from run records.
- **Reach**: the literal host in `url` plus `allowed_hosts`; https only (plain http for loopback); every redirect hop re-checked (`RedirectGuard`); private, link-local, carrier-NAT, and metadata addresses refused through `PluginHostContext.checkSSRF` even when listed. Bodies are capped at 4 MB; `Set-Cookie` is dropped from the output.
- **Pagination** (`HTTPPagination`): `mode` is `cursor` (`cursor_path` in the body → `cursor_param` on the query), `next_url` (`next_url_path`, relative URLs resolved against the page), `link` (`Link: <…>; rel="next"`), or `page` (`page_param` from `start_page`, ends at the first empty page). `items_path` names the array in each page (empty when the body is the array). `max_pages` defaults to 10 and is capped at 100; `max_items` caps at 10 000. A repeated page URL ends the walk. The output's `body` is the merged items; `pages` counts requests; `complete` is false when a cap stopped it; `status`, `ok`, `headers` are the last page's. A page without an array at `items_path` fails with kind `pagination_shape`.

---

## Requirements, templates, and setup

`TemplateRequirements` (`Models/Template/TemplateRequirements.swift`) lists `models` (slots with `preferred`, `strictness`, `locality`, `needs_tool_use`), `secrets`, `mcpServers`, `plugins`, `tools`, `permissions`, `network`, `dependencies`, `folders`. Most of it is **derived** from the graph by `WorkflowRequirementsDeriver.derive`; `reach(_:resolve:)` additionally follows `workflow` steps into installed children to count their hosts, tools, and MCP servers (children keep their own models and secrets, bound in their own setup).

A `Template` carries the definition and its requirements, is content-hashed and optionally signed, and travels as a `.osaurustemplate` file or through store.osaurus.ai.

Sharing (`Views/Template/ShareWorkflowSheet.swift`) offers two ways: save as a file, or publish to the registry through `WorkflowShareService` and `WorkflowsRegistryAPIClient` (EIP-191 signed requests with a nonce challenge). A published listing has a `WorkflowVisibility` (`public`, `hidden` = Unlisted, `password`; `X-Workflow-Visibility: hidden` on publish, `PUT /workflows/:id/visibility` afterward) and is remembered locally in `WorkflowRegistryRecordStore` with its cached install count, latest registry version, author handle, and taken-down state (`unpublish` keeps the record so the card reads Taken down and can Publish Again; `forget` removes it). Stats refresh two ways: `refreshStats` is unsigned (never prompts for the identity key; skips password listings; 5-minute freshness) and runs when the Workflows tab appears, while the published dashboard (`PublishedWorkflowDashboard`) calls `refreshOwned`, a signed `GET /workflows/:id` plus `GET /me/workflows` reconciliation that also rebuilds records for listings known to the library but missing locally. `WorkflowShareCardView` renders the 1200×630 share image. Agent templates use the same sheet, service, and record store: `AgentTemplateCard` offers Save as File and the publish actions for templates in the user's library (built-ins export as a file only), the registry stores the listing with `kind = agent` and pages it at `/a/<slug>`, bundled workflows travel inside the agent's signed file, and `WorkflowRegistryRecord.kind` keeps the Workflows page's published summary to workflows. An agent template installed from a registry link sends the same signed install receipt after `TemplateImportSheet` imports it. The Architect's `workflow_discover` `registry` action asks for `kind=workflow`. `format_version` is the lowest format that can carry the graph (`WorkflowDefinition.requiredFormatVersion`): 1 for the original feature set; 2 for a post-v1 feature (`http`, `wait`, `map`, `workflow`, `state`, `reply`, Python code, `on_error`, `join: all`, error/always edges, grouped or post-v1 condition operators; `usesPostV1Features`); 3 for a `media` step or a bypassed step; 4 for an `agent` step; 5 for a tool call that runs as a named agent (`tool.agent`). An older build refuses a newer format with "update to import"; older builds keep importing v1 files. Secrets, bindings, saved answers, run history, and absolute paths never travel.

### Secrets and connections

`SecretRequirement`: `key`, `label`, `help`, optional `oauth2` (`OAuth2Spec`: authorize/token URLs, scopes, client id, `requires_client_secret`, extra authorize parameters), optional `service` and `provider`.

- `declare_secret` declares a key or an OAuth sign-in by hand.
- `declare_connection {provider | service, key?, label?, help?, scopes?, sign_in?}` declares the person's **login to a service** as one secret. `ConnectionProviders` (`Models/Workflow/ConnectionProviders.swift`) is the catalog — GitHub, GitLab, Google, Microsoft, Slack, Linear, Notion, Dropbox, Spotify, Stripe — with each service's OAuth endpoints, default scopes, API hosts, and where a personal token or OAuth app comes from. `sign_in: false` asks for a token instead; a provider without tokens refuses it. An unknown `provider` is refused with the list of catalog ids.
- Values live in Keys (`WorkflowCredentials`, [CREDENTIALS.md](CREDENTIALS.md)), shared by name with any workflow, MCP server, or agent that uses the same key unless setup gave the workflow its own (**Use a separate value for this workflow**, `WorkflowCredentials.saveSeparate`), or under a shared **connection** (`WorkflowConnectionStore`, `connections.json` + Keychain). A connection is a pasted value or an OAuth 2.0 sign-in with refresh (`OAuth2ConnectionFlow`: PKCE, loopback redirect). Setup offers existing connections for the secret's `serviceHost` first; a secret declared as a connection keeps a pasted value as a connection by default. `WorkflowConnectionResolver` hands the run a live token.

### Setup

`SetupChecker.check(_:)` turns requirements into setup items (blocking or optional) against the live Mac: model slots, secrets (including expired or missing connections), MCP servers, plugins, tools, permissions, dependencies (installed into the workflow's own sandbox environment, `WorkflowSandboxEnvironment`), folders, and the setup state of every `workflow` step's child. Its `Environment` struct is the injection seam for tests. A workflow with blocking items reads **Needs setup**; a call to it fails with `needs_setup`.

---

## Running

`WorkflowRunService` starts and tracks runs; `WorkflowRunner` executes the graph (parallel branches, joins, retries, `on_error`, map fan-out, streaming of inference text into `NodeRun.streamed`); `WorkflowRunStore` keeps live runs and the SQLite history (`Storage/WorkflowRunDatabase.swift`, with `is_test` for Architect test and eval runs, which stay out of Recent Runs and badge averages). Runs survive relaunch (`WorkflowWorkModeResume`, `ParkedWorkflowSetupWatcher`); a failed run can be retried from the failed step in the same workspace.

Entry points:

- **Workflow tab** in a chat window (`Views/Workflow/WorkflowRunTabView.swift`), also `/` in chat.
- **Agent tools**: each workflow an agent has turned on is a tool `workflow_<slug>`; the Orchestrator uses `run_workflow` for workflows marked **Osaurus can run this for you** (`Tools/Workflow/WorkflowTools.swift`). While the call waits, `WorkflowCallFeed` registers a `SubagentFeed` under the tool-call id so the chat's tool card shows each step, the running model step's streamed text, and the outcome.
- **Background tasks** park on a form and resume with the result.
- **Automations** (`docs/AUTOMATIONS.md`): an automation (an *event* in code) whose action is a workflow starts it when its schedule, folder, webhook or channel message fires. `WorkflowRunWorker.workflowInput` evaluates the event's input mapping against the payload (`WorkflowInputMapper`, coercing to the schema's field types), validates it with `JSONSchemaValidator`, and starts the run with caller kind `event` (`isExternalSurface` for webhook and remote-channel fires, `isUnattendedDispatch` for local source fires). The event settles when the run ends; a run parked on a form frees the event's lane and the ledger row follows it. Channel events can reply with the output (`WorkflowRunWorker.replyText`).
- **HTTP / MCP**: a run that stops for a form returns `awaiting_user`; `GET /workflows/runs/{id}` returns the result (or the pending form); `GET /workflows/pending-dialogs` and `POST /workflows/runs/{id}/dialogs/{dialog}` answer forms. Off the Mac these need the Secure Channel.

Every run and step is recorded in Insights (`WorkflowActivityLogger`), with secret values replaced by `[REDACTED:KEY]`.

### Trust rules

- The workflow's steps, not the calling agent, authorize the tools they call; each tool's own permission (ask / allow) still applies during the run.
- File and shell steps work in the calling agent's folder or the run's workspace; anything else needs a declared folder, a picked folder, or a grant card (`WorkflowFolderGrantCoordinator`).
- Tool and agentic steps cannot call workflow tools (compose with a `workflow` step) or chat-only tools.
- Network: see HTTP steps. Code steps reach only hosts in their `network` list through `ctx.fetch`.

---

## The Architect

The Architect is `Agent.architectId` with `ArchitectSystemPromptBuilder` as its prompt and these tools (`Tools/Workflow/`), gated to Architect chats by `ArchitectToolGate`:

| Tool | Purpose |
| --- | --- |
| `workflow_draft` | `get` (the draft, its validation `issues`, `setup`, and `risks`), `patch` (ops below), `tools` (search callable tools), `media_models`. |
| `workflow_test` | Runs the draft with an input or saved examples; `from_node` re-runs from a step with the last test's outputs reused, `from_run` re-tests from a failed run with finished steps pinned. |
| `workflow_propose_save` | Proposes saving as a template; refused without passing test evidence on the declared models after a graph change (`WorkflowDraftSaver`). |
| `workflow_discover` | `mcp` (the Osaurus directory), `docs` (OpenAPI/Swagger only), `registry`, `templates`, `adopt`, `models`. |
| `workflow_runs` | Reads saved workflows' runs, steps, logs, and tool calls; repeated-failure detection. |
| `architect_handoff` | The Orchestrator's tool (not the Architect's): it hands a brief to the Architect. |

The Architect also gets `clarify` and `osaurus_inspect` limited to the `models`, `mcp`, and `plugins` scopes.

**Draft ops** (`WorkflowDraftOp`): `plan_placeholder`, `update_node`, `remove_node`, `add_edge`, `remove_edge`, `set_schemas`, `set_output`, `set_info`, `declare_slot`, `declare_secret`, `declare_connection`, `declare_dependency`, `declare_folder`, `add_example`, `declare_server`, `detach`. Every patch records a `WorkflowDiff` entry (nodes, edges, schemas, dependencies, folders, servers) for the draft's **Changes** list and the sidebar's Undo.

**Model contract**: a slot's `strictness` is `always` (the `preferred` model is a prerequisite: the validator requires it, `SetupChecker.resolvedModel` resolves only to it, setup blocks any other binding, and the wizard's picker is locked) or `preferred` (a suggestion: the person's choice, then the suggested model, then their default). A `needs_tool_use` slot bound to a model that cannot call tools blocks setup. Save evidence counts a test only when its inference steps ran on the declared models (`NodeRun.model`).

**Self-heal**: `WorkflowSelfHealMonitor` (opt-in per workflow) drafts a fix in a background Architect chat when the same step fails the same way three runs in a row; nothing saves without the person's review.

---

## Code map

| Area | Files |
| --- | --- |
| Model | `Models/Workflow/WorkflowDefinition.swift`, `WorkflowValidator.swift`, `WorkflowRequirementsDeriver.swift`, `BindingRenderer.swift`, `JSONSchemaValidator.swift`, `WorkflowRun.swift`, `WorkflowDraft.swift`, `WorkflowSessionCompiler.swift`, `ConnectionProviders.swift`, `InstalledWorkflow.swift` |
| Templates | `Models/Template/Template.swift`, `TemplateRequirements.swift`, `Services/Template/SetupChecker.swift`, `MCPServerResolution.swift` |
| Runtime | `Services/Workflow/WorkflowRunner.swift`, `WorkflowRunService.swift`, `WorkflowRunStore.swift`, `WorkflowNodeExecutor.swift` and the per-kind executors, `WorkflowStateStore.swift`, `WorkflowConnections.swift`, `WorkflowCallFeed.swift`, `WorkflowTrust.swift`, `Storage/WorkflowRunDatabase.swift` |
| Architect | `Services/Chat/ArchitectSystemPromptBuilder.swift`, `Services/Workflow/WorkflowDraftStore.swift`, `WorkflowDraftSaver.swift`, `WorkflowDraftTester.swift`, `WorkflowSelfHealMonitor.swift`, `WorkflowRepetitionDetector.swift`, `Tools/Workflow/*` |
| UI | `Views/Workflow/` (run tab, run view, detail sheet, setup wizard, connections sheet, Architect sidebar and graph) |
| Keychain | `Services/Credentials/Consumers/WorkflowCredentials.swift`; `Services/Keychain/WorkflowSecretsKeychain.swift` (legacy values, read until imported) |

## Tests and evals

Unit suites live under `Packages/OsaurusCore/Tests/Workflow/` (`WorkflowModelTests`, `WorkflowEngineExpressivenessTests`, `WorkflowStreamingTests`, `WorkflowIntegrationSynthesisTests`, `WorkflowFromBehaviorTests`, `WorkflowTrustSurfaceTests`, `WorkflowObserveRepairTests`, `WorkflowStateTests`, `ArchitectDraftTests`, …). Run them scoped:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test OSU_MODELS_DIR=/tmp/osaurus-test-models \
swift test --package-path Packages/OsaurusCore --filter "WorkflowEngineExpressivenessTests"
```

Deterministic end-to-end cases are in `Packages/OsaurusEvals/Suites/Workflow/` (node kinds, error edges, map, wait + state joins, retries, condition routing, pagination-free HTTP failure paths) and the Architect lane in `Suites/Architect/`:

```bash
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/Workflow MODEL=foundation
make evals-architect                                  # xai/grok-4.7 by default, three repeats
make evals-architect ARCHITECT_MODEL=<model id> FILTER="paged-issue|vague-brief"
```

The Architect lane is hermetic: each case can declare a loopback fixture API (`fixtureAPI`: bearer auth, cursor or Link pagination, fail-first retries, per-key routing), in-memory test secrets, scripted answers to the Architect's questions, a seeded saved workflow to edit or a failed run to repair, and structural and post-save run checks. A frontier model needs its API key in the shell environment (for xAI, `XAI_API_KEY`); it is never written to disk.

Code steps need the JS host: set `OSAURUS_JS_HOST_PATH` to the built `osaurus-js-host` or rows that use them are reported as blocked.
