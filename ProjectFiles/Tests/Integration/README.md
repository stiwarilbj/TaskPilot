# App control regression fixture

The automated Swift and Python suites exercise action validation, revision scope,
activation waits, restoration guards, mutation replay protection, and private
output diagnostics without controlling Chrome.

`test_app_control.py` is an explicitly opt-in native bridge fixture. It creates a
disposable AppKit app and uses the signed TaskPilot bundle's existing permissions.
It does not launch or control browsers, and its cleanup does not close discovered
apps. `--live-acp` adds one provider planning request against the disposable app.
Do not run it as part of ordinary builds or automated test discovery.

Validation performed during implementation:

- Five native button/double-click/text/scroll cycles, menu selection, disabled
  controls, and stale element IDs passed on the main display with no wrong-target
  or duplicate actions.
- A secondary display was unavailable, so that display path remains unverified.
- Live ACP returned a decision that failed the intended-target assertion; the
  action was not delivered. Prompt and observation refinements followed, but live
  model verification remains incomplete.
- Browser testing was stopped after reported Chrome instability. No further live
  browser or native-control tests were run after that request.

The final bundle is validated by compilation, automated suites, and signature
verification. These checks do not establish complete live app compatibility.

Response repair validation uses mocked ACP terminal responses and current-observation
fixtures. It covers strict parsing and native parameters, the shared one-call repair
budget, same-model retention, fallback, provider errors, cache identity, and request
counts. The Swift suite also checks compatibility with older diagnostic records.
No live-control tester, Chrome interaction, or live ACP check was run for this change;
live validation remains incomplete.

Screen settling now polls local observations after desktop actions and model-requested
waits. Mock fixtures cover stable dialogs, loading indicators, field readiness,
revision and foreground churn, screenshot-only changes, bounded waits, cancellation,
cleanup, and reuse of the final observation without duplicate actions or model calls.
Live-control validation remains incomplete; no Chrome or live fixture was used.
