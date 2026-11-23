# Remaining design and verification work

This is the October 28 workflow inventory. See the [final Beta 40 verification record](FINAL-BETA40-VERIFICATION.md) for the current handoff boundaries.

This package preserves existing functionality and the implemented UX. It is not a claim that every conditional app state has been redesigned or exercised.

## Existing screens still awaiting full design direction

- Workflow input/run form, progress, results, errors/retry and rerun.
- Sharing/publishing, sign-in requirements, publication settings, success/errors and published-workflow management.
- Starter/import preview and setup, including model/account/key requirements.
- Detailed step editors, graphs, examples, test-history/results and save/version/conflict states. The main authoring canvas and Design/Test layout have been updated; not every nested editor has a new design.
- Run history, output files, stored data, saved answers and conditional management dialogs.
- Connections and automation management remain available through Settings.

Workflow details now has a vertical What It Does layout, canvas-level sections, subtle borders and the shared actions menu. Do not treat the entire details page as undesigned.

## Known verification boundaries

- Upstream merge conflicts must be resolved and the resulting app checked before shipping.
- Normal app theme switching/imported themes, real account-dependent states, publishing/takedown and full end-to-end workflow execution are not certified by this packaging task.
- Some physical interactions and conditional states remain from earlier catalog checks; do not describe the entire catalog as fully manually verified.
- The native date/time popup remains native by design. The closed field is the styleable component.
- This handoff performs no broad visual sweep, per Neesh's requested scope. Use the walkthrough and Paper for design review.

## Workflow entry points retained

- Main Chat → Add to chat → Add Workflow → saved workflow run form in Workflows; empty state links to Workflows home.
- Workflows → New / a draft → its own Architect conversation and authoring canvas.
- Saved workflow → Play or menu Run → existing input/run flow. The card background is not a run button.
- Saved workflow menu → Edit with the Architect, Details & history, Set Up, share/export/publish, rename, version/update and uninstall as applicable.
- Ready to add → starter preview/setup; Import → existing import flow.
- Details & history → Recent Runs, conditional saved answers/data, availability and management controls.
- Settings → Vault / Accounts and Automations for connections and triggers.

Menus open on click. Existing actions and their visibility conditions remain; opening a route is distinct from verifying every external operation behind it.
