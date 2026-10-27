# TaskPilot-managed OpenClaw

TaskPilot provisions OpenClaw **2026.9.5** and Node **24.22.1** under
`~/Library/Application Support/Orbit Agent/ManagedOpenClaw`. The manifest and npm
lock in `Resources/OpenClaw/managed` pin official Node checksums and every npm
integrity. Provisioning stages, checks, seals, and then activates an installation.
Updates ship with TaskPilot; runtime provisioning never requests `latest`.

`managed_openclaw.py` owns installation, isolated configuration, supported
credential storage, descriptors, and tested rollback. It does not read shared
OpenClaw workspace/configuration or invoke doctor, Homebrew, Gateway service
installation, or service restart. Only TaskPilot's saved Gemini key and model
settings populate the private instance. The credential command writes the
current OpenClaw auth schema; writing a legacy JSON profile can produce an
otherwise healthy Gateway whose turns fail before calling a provider. The private
profile explicitly allows the bundled Google provider plugin. Configuration writes
use `config patch --stdin`: this release keeps authoritative configuration in its
private database, so replacing the exported JSON alone is insufficient.

`ManagedGatewayHost` is a headless mode of the native executable. App clients
register PID + birth identity leases. An exclusive flock owns the foreground
Gateway and its process tree until drainage; no login service is installed.
The root birth identity is recorded while the child is suspended. Recovery
never signals an unrelated port listener. A collision selects another private
endpoint, including spacing for OpenClaw's derived ports.

The runtime descriptor is shared by native task startup, Python ACP, readiness,
setup, dashboard, and session RPC. It identifies absolute executables,
configuration/state/workspace, token file, loopback endpoint, and instance and
installation fingerprints. Ambient OpenClaw/Node/provider settings cannot
redirect the managed environment.

Readiness separates installation integrity, configuration, authenticated health,
ACP handshake, and provider verification. The native host probes locally every
30 seconds, on wake/network notification, and on a coalesced runtime fault.
The normal readiness path reads the provider cache and makes no generation
requests. A new installation gets one activation verification through TaskPilot's
ACP client with a synthetic image and strict JSON response. Provider verification
is cached for ten minutes with instance/installation/credential/config identity.
Credential, quota, capacity, and pre-reply configuration failures remain explicit.

Recovery permits three local restarts in a rolling ten minutes, delayed by
1, 3, and 10 seconds, followed by a 60-second circuit and increasing local probe
intervals capped at five minutes. The budget survives host restarts and is not
cleared by healthy refreshes or new tasks. Unsupported ACP/configuration stops
restarts and reports repair or selects a verified compatible rollback. Gateway
output is continuously drained and discarded with bounded retention.

Python's recovering state permits no action, planning, or completion. A lost
reasoning transport first ends its ACP child, waits for private health, and
requires the Gateway's terminal abort acknowledgement before one reasoning
reconnect per interrupted request, capped at three reconnects per task in a rolling
ten minutes. Wrapper and direct-Node alternatives share that allowance. Receipt reconciliation still owns dispatched desktop mutations;
recovery does not replay them. Native instruction revisions, Pause, secure input,
and task ownership remain authoritative. Restarting the app starts no old task.

## Validation

Safe checks: Python unit/offline prompt regression suites, Swift tests, generated
contract checks, and `Tests/Integration/test_openclaw_bootstrap.sh` (mock setup).
`--managed-openclaw-check <descriptor> <runtime>` is a headless packaging check;
it runs no automation bridge or desktop action. It waits through the supervisor's
circuit, then uses the normal synthetic image/JSON model checker and closes its
client lease. It must never be replaced with the fixer or live-control tester.

The bundle is locally ad-hoc signed by the existing build script. This is distinct
from Developer ID signing/notarization. Desktop and visual accuracy validation
remain incomplete; offline checks and a successful provider probe cannot promise
service availability under external provider outages, revoked credentials, or
exhausted quota.

## Local drift checks and connection recovery

Both Swift and Python require fresh authenticated health (under 45 seconds),
matching instance/configuration/installation fingerprints, and live host and
Gateway birth identities. A dead or reused PID invalidates cached health before
native delivery. Configuration audits run on startup, relevant faults, and every
five minutes. They check the wrapper contents, Google
plugin, model catalog/defaults, private workspace/endpoint/token, supported CLI
configuration readback, and the private credential-store record. None generates
provider requests.

Known defects get one persisted repair reservation per unchanged failure
fingerprint per ten minutes. Repair first tries a different, integrity-verified
working installation when code is damaged; otherwise it stages the same pinned
release. Configuration repair replaces managed settings while preserving unrelated
metadata and reads them back through `config get`. Missing private credentials
are restored through the supported auth command using TaskPilot's saved key.
An unsaved key being explicitly checked has a bounded grace period, then the saved
key becomes authoritative again. A failed check restores that saved key promptly.

`execution-repair.lock` separates complete native action lifetimes from offline
repair. The host waits for shared action permits before taking the exclusive
repair permit. New delivery checks the same gate immediately before side effects;
known rejections wait locally and refresh evidence. Dispatched or uncertain receipts
still require reconciliation and never authorize automatic mutation replay.
Explicit configuration writers use a birth-bound drain request/acknowledgement;
requester exit releases abandoned holds. ACP probes yield to these requests to
avoid configuration-lock inversion. Stop and existing Pause/correction/secure-input
boundaries remain authoritative.

Managed installation digests are cached in a private sidecar keyed by the
installation fingerprint, canonical directory identity, and integrity-manifest
digest. Each audit checks file identity and metadata; it rehashes changed files
against the immutable seal. Missing or invalid cache state triggers a full
verification. The Gateway host performs a full content audit at startup and
every 60 minutes using a monotonic clock. A failed or interrupted full audit does
not advance that deadline. Cache write or lock failures fall back to uncached
hash verification. The cache contains only sealed relative paths, digests, file
metadata, and audit timing; it cannot establish runtime or provider readiness.
Full content audits request macOS `F_NOCACHE` on each checked regular-file
descriptor before sequential reads, including uncached fallback audits. This is
a best-effort hint to reduce filesystem-cache pollution, not an integrity check.
Unsupported platforms, missing constants, and filesystem rejection use ordinary
reads with identical digest and before/after identity validation. Incremental
rehashes and initial sealing retain their existing cache policy; periodic full
audits and their successful-pass-only timestamp updates are unchanged.

ACP first uses the managed wrapper and explicit endpoint/token file. After the
failed child ends, it may try the sealed pinned Node executable and entry point,
with the same profile, endpoint, authentication, and contract. Session RPCs retain
the chosen method and use `--expect-url`; repairs refresh paths and cache identity.
Only an explicit unsupported ACP version means incompatibility. Timeout, refused
connection, malformed protocol, startup, and authentication remain distinct causes.
A confirmed `EADDRINUSE` alone permits endpoint relocation. Diagnostics contain
fixed causes, methods, timings and fingerprints, never task/provider payloads.

Offline validation covers real fake-ACP subprocess fallback, birth identity
rejection, private configuration/credential drift, failed repair throttling,
readback, action/repair exclusion, and supported drain acknowledgements, alongside
the existing execution, receipts, instruction-correction, and prompt regressions.
The packaging check uses only headless ACP image/JSON generation. No fixer, Chrome,
live-control tester, or desktop task is part of this workflow.

Delivery validation (2026-10-24): 769 Python tests passed; 584 Swift tests
passed with one skipped. Setup integration, generated-artifact checks, and
offline prompt regressions passed. The rebuilt signed bundle completed headless
ACP image/JSON verification using 3.5 Flash-Lite in one generation call, with
zero repairs or model fallback. Its Gateway stopped after the checker released
its client lease. Live desktop and visual validation remain incomplete.

The Gateway host keeps bounded vnode watches for the active sealed entry points,
integrity manifest, private descriptor/configuration/wrapper/token/fingerprint,
and their private parent directories. File write/replacement events dirty the
appropriate in-memory cache scope; directory events first compare relevant
children so health/process-ledger bookkeeping cannot trigger an audit loop.
Installation hints use the existing forced-full Python audit, bypassing digest
reuse while preserving the seal and cached inode baseline. Configuration hints
run the existing settings/credential validation. Hints coalesce for five seconds,
never establish readiness, and cannot reset recovery budgets. Changes arriving
during validation remain pending. Successful validation is followed by the
existing authenticated health path. Watches rearm after replacement and timed
audits, close with the host, follow no external paths, and perform no recursive
scans. Vnode delivery is not recursive or guaranteed: missing/unsupported watches
retain five-minute configuration checks, per-validation file metadata checks,
and hourly full integrity audits. No generation requests are added.

A private-root FSEvents subscription supplements vnode watches only for dropped
history, required rescans, event-ID wrap, root replacement, and mount changes.
Ordinary FSEvents do not alter the existing per-file/configuration paths. Watched
directory replacement or revocation also requests a full pass because individual
child changes may have been missed. These signals perform no directory scans.
The host latches the full-audit requirement until success, retaining its existing
failed-audit retry delay. Python persists a pending-full marker under the existing
cache lock before a forced pass, preserving the seal and prior inode baseline.
An interrupted or failed pass cannot reset the audit timestamp or clear that
marker; the next validator must hash every sealed file. Legacy caches remain
compatible. Unsupported notification delivery retains the timed audit fallback.

## Managed Node environment policy (version 1)

Swift launch construction and Python configuration/activation use the same
fixture-tested policy. Ambient `NODE_*`, `NPM_*`, `npm_*`, provider keys and
OpenClaw profile settings are removed before private settings are installed.
`LANG` and `LC_ALL` are `en_US.UTF-8`; other `LC_*` overrides and `LANGUAGE` are
removed. PATH contains the descriptor's pinned Node directory followed by
`/usr/bin:/bin:/usr/sbin:/sbin`; provisioning adds its staged Node explicitly.
No user shell is launched or sourced. The private wrapper also exports the
pinned PATH and UTF-8 locale. Existing configuration audits can repair an older
wrapper through the normal owned, drained repair path.

Explicit HTTP, HTTPS, ALL and NO proxy settings are preserved. Uppercase wins
when uppercase/lowercase aliases conflict (including an explicit empty value),
and both aliases receive that value. Proxy URLs, credentials, trust settings
and unrelated environment values are never written to environment diagnostics.
Other inherited settings, including existing certificate configuration, retain
their existing behavior; this is a small runtime policy, not a process sandbox.

The fixed diagnostic bitmask compares inherited versus effective categories:
1 = removed Node/npm overrides, 2 = normalized locale, 4 = normalized proxy
aliases, 8 = normalized executable search path. Swift emits only this numeric
code and policy version to the private ManagedEnvironment log category. Python
activation keeps only `{version, mismatch_code}` in a private mode-600
`environment-diagnostics.json`; unchanged records are not rewritten. Its audit
also includes the fixed environment record. These are launch comparisons,
not failures or Gateway/provider readiness claims. No variable names, values,
secret-derived hashes or task content are recorded. Diagnostic-write failure
cannot prevent activation. Existing health/recovery budgets and generation
counts are unchanged.

Offline reproduction: run `ManagedOpenClawTests` and
`python3 -m unittest discover -s ProjectFiles/Tests/Python -p test_managed_openclaw.py`.
The shared `managed-environment-cases.json` covers conflicts and idempotence;
synthetic child/wrapper tests inspect effective settings without launching
OpenClaw, a browser, or a desktop task.

## Private-directory startup preflight

Before reporting managed readiness, the lifecycle coordinator checks the scratch
root and known managed installation, instance, workspace, configuration and
credential-store directories. Each must be a real directory owned by the current
user with mode `0700`. The check walks only known paths, without directory scans
or generation requests. Installation validation also checks its sealed root's
owner and mode before using the integrity cache.

Known mode drift is repaired through the existing cross-process configuration
transaction and installation lock, after the owned Gateway drains. Repair uses
an opened, identity-checked directory descriptor and verifies the resulting mode.
It does not recursively chmod package contents or alter shared OpenClaw storage.
The audit reports `private_directory_permissions`; host repairs retain the existing
failure-fingerprint budget and do not reinstall a healthy runtime for mode drift.

Symlinks, unexpected ownership, identity changes and unavailable directories
produce classified `private_directory_*` attention conditions. They do not
trigger automatic replacement, chmod of the unexpected target, or reinstall.
Even a known directory remains blocked if it cannot be opened safely (for example,
mode `000` on macOS); no pathname-only chmod fallback is used. These are point-in-time
checks, not a claim to prevent unrelated processes from changing paths afterward.

Offline reproduction (from `ProjectFiles`):

```sh
python3 -m unittest discover -s Tests/Python -p test_managed_openclaw.py
swift test --filter 'TaskTemporaryResourcesTests|ManagedOpenClawTests'
```
