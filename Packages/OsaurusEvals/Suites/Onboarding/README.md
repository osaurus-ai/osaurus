# Onboarding Eval Suite

Deterministic rows for the Onboarding agent's first run, through
`OnboardingEvalHarness` in OsaurusCore. No model, no network: each case
names one `check`, and every assertion it makes is one `PASS`/`FAIL` line in
the report. `Config/floors.json` pins the suite at 1.0.

The model rows live elsewhere: teammate routing and the name traps in
`Suites/Routing` (`routing.team-*`, `routing.trap-*`), the Keeper versus
Files worker choice per model in `Suites/Orchestrator`
(`orchestrator.team-*`), and the default workflows and prepared asks in
`Suites/Workflow` (`workflow.team-*`).

| Check | Pins |
| --- | --- |
| `opening` | The opening greets without guessing a name, says where it runs and what Osaurus does, and asks one thing; no hardware recital or team list. |
| `plan_from_state` | A committed model skips the brain step; the cards follow the team, with Osaurus last. |
| `zero_model_run` | Every path's buttons reach the first task with a panel and an authored line. |
| `step_control` | Back, a card's name, and skip words move the plan. |
| `no_self_completion` | A reply that claims a step is done never moves the plan. |
| `team_settings` | Each template's apps, switches, quick actions, and routing line. |
| `tool_budget` | Each teammate's real wrapper schema (a `.delegation` session in its folder): domain tools plus `capabilities` and `get_current_time`. |
| `isolation` | No teammate holds private data and a way out together; Scout holds no app, folder, or memory tool. |
| `bundled_references` | Every bundled step's `agent` is a teammate UUID and resolves to the renamed teammate. |
| `default_workflows` | Seven workflows, read only, no required input except Research Brief's topic, six steps at most. |
| `prepared_reads` | Each card ask is a fixed read under a teammate, dates from a code step, started by workflow id. |
| `held_on_bridge` | Personal asks wait on the bridge; a provider gets a disclosure; a denial links Settings. |
| `skip_setup` | Skip setup ends setup from every step, the walkthrough ends at the first task, and a stored plan with a retired step still settles. |
| `seeded_state` | The handover holds facts and leaves the walkthrough behind. |
| `wording` | No tool or role names, no request to go offline, one question per opening. |
| `prompt_budget` | The walkthrough prompt stays within its token budget over 20 long turns. |
| `discovery` | One new card a day, a dismissed card never returns, done items are done. |
| `bundled_contracts` | Every default workflow and prepared ask passes the strict validator, and each tool step sends only arguments its registered tool declares, with every required one. |

## Run

```bash
OSAURUS_EVALS_SCRIPTED_ONLY=1 OSAURUS_EVALS_DISABLE_WARMUP=1 \
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/Onboarding --fail-on-floor
```
