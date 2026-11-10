# Schedules

Schedules are now **schedule automations**. See [AUTOMATIONS.md](AUTOMATIONS.md).

- Settings → Automations → Add Automation → **Schedule** (once, daily, weekly, monthly,
  yearly) with a workflow, an agent, or Ask a Model (one tool-less answer) as
  the action.
- On first launch each `~/.osaurus/schedules/*.json` became a schedule automation
  with the same id; its run history moved into the run ledger and the
  file was renamed `*.json.migrated`.
- History, pause/resume and export live on the automation: the **Runs** list,
  the enable toggle, and Settings → Automations → Import / Export.
- A slot missed while the app was closed runs once on the next launch, or is
  recorded as `missed_skipped` when the automation's missed-fire policy is *Skip*.
- `osaurus_config` still accepts a legacy `schedules:` section and folds it
  into `automations:`.
