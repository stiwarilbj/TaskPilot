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

Decision-prompt regression fixtures check context-specific action examples, valid JSON
and fixture-bound validation, compact recovery references, preserved task evidence,
local credentials, completion rules, and one-call healthy decisions. Empty-observation
fixtures are capped at 4,000 characters. No Chrome interaction or live-control tester
was used; live accuracy validation remains incomplete.

Click preflight compares the observed app identity, Accessibility owner PID, window
identity/title/bounds, control label/role/subrole/bounds, and enabled state immediately
before AXPress or the first mouse-down. Pointer hit testing rejects another control
covering a known target. Coordinate clicks also check Core Graphics window IDs and
bind to an observed control when available; apps that expose no Accessibility control
still have only app/window metadata available for that part of the check.
Automated fixtures cover changed targets, replaced windows, rejected delivery,
cancellation, and fresh-observation replanning without replaying the rejected click.
These local checks make no model requests. No live-control tester or Chrome interaction
was run; live compatibility and accuracy validation remain incomplete.
