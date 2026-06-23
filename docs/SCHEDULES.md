# Schedules

Schedules run saved agent instructions on a calendar or cron cadence. Each
schedule stores a bounded local run history alongside its JSON configuration.

## Run History

The schedule store records a history entry when a schedule is selected for
execution and marks that entry complete when the run finishes successfully.
The Schedules tab also enriches that local history with matching `agent_runs`
audit records when the target agent has database run logging enabled. Those
audit records add terminal failures, cancellations, token counts, and error
messages when available.

History entries are matched to schedules through the schedule UUID carried as
the scheduled dispatch external session key.

## Next Run Preview

The preview uses the schedule's execution anchor (`lastTriggeredAt`, falling
back to `lastRunAt`) so missed or in-flight runs do not make the UI preview the
same slot as an upcoming run. Paused schedules show no next run. Completed
one-shot schedules show no upcoming run.

## Pause and Resume

Schedules can be paused and resumed from the Schedules tab action menu. Pausing
preserves existing history and switches the next-run preview to the paused
state; resuming recalculates the next run from the schedule's execution anchor.

## Export

Use the Schedules tab history menu to export a Markdown run summary. The export
includes schedule identity, frequency, enabled state, generated time, next-run
preview, the latest error diagnostic, and recent run rows with status, duration,
session ID, and error text when present.
