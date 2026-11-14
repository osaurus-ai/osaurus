# Watchers

Watchers are now **folder automations**. See [AUTOMATIONS.md](AUTOMATIONS.md).

- Settings → Automations → Add Automation → **Folder** watches a folder (optionally
  with subfolders) and runs a workflow, an agent, or one model answer (Ask a
  Model) when files change.
- Responsiveness (Fast ~200 ms … Extended ~10 min), Merkle fingerprint change
  detection, the convergence loop (up to 5 passes, so an agent's own edits do
  not retrigger it) and nested-folder exclusion behave as before.
- A folder automation keeps one chat across fires, so a follow-up pass builds on
  the previous one.
- On first launch each `~/.osaurus/watchers/*.json` became a folder automation
  with the same id and the file was renamed `*.json.migrated`.
- `osaurus_config` still accepts a legacy `watchers:` section and folds it
  into `automations:`.
