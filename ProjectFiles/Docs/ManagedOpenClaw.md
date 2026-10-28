# TaskPilot-managed OpenClaw

TaskPilot provisions OpenClaw **2026.9.5** and Node **24.22.1** under
`~/Library/Application Support/Orbit Agent/ManagedOpenClaw`. The manifest and npm
lock in `Resources/OpenClaw/managed` pin official Node checksums and every npm
integrity. Provisioning stages, checks, seals, and then activates an installation.
Updates ship with TaskPilot; runtime provisioning never requests `latest`.

Before extracting Node, the installer validates the entire tar namespace with
canonical Unicode decomposition and case folding, regardless of the staging
volume's case sensitivity. Both explicit members and implicit parent directories
participate. Duplicate entries, alternative case/Unicode spellings, and paths
used as both a non-directory and a parent are rejected in either archive order.
An implicit directory may be declared once later with the same spelling. Member
names are never rewritten; ambiguous packages fail before extraction or CLI
launch. Absolute and parent-traversal member paths are prohibited, link
targets must stay inside staging, and extraction retains Python's data filter.
Valid internal leaf links are supported. Failed validation discards only the
owned incomplete stage and preserves the active installation.

Offline namespace and installer fixtures run with
`python3 -m unittest Tests.Python.test_managed_archive_paths Tests.Python.test_managed_provisioning`
from `ProjectFiles`; they use tiny synthetic archives and no network or runtime.

## Interrupted provisioning

Provisioning keeps one bounded, versioned, mode-600 `provisioning.json` beside
the active descriptor, outside sealed installations. It records fixed phase
codes for staging, sealing, promotion, configuration/readback, and activation,
an opaque installation fingerprint, and an optional random stage identifier
with its device/inode. It contains no keys, settings, configuration contents,
task data, or executable paths. Phase writes use atomic replacement and sync
the file and parent directory before the corresponding work proceeds.

The existing installation/configuration locks serialize provisioning. A separate
kernel lease is explicitly inherited by provisioning CLI children, preventing
recovery while a surviving child still holds it after controller death. No PID
alone establishes abandonment. Recovery never scans for or deletes arbitrary
stage directories: it opens the one recorded private stage without following
symlinks, checks its identity, and removes contents relative to that descriptor.
The mkdir-before-identity crash window permits only empty-directory removal.
Unexpected replacements or malformed, unsafe, or oversized journals require
attention and preserve the active installation.

An interrupted incomplete stage is discarded and rebuilt. A matching sealed
stage can resume promotion only after a full seal verification; a phase marker
cannot prove integrity or readiness. Recovery also handles interruptions on
either side of the promotion rename. An existing verified target wins over a
duplicate stage, damaged targets retain the existing quarantine behavior, and
the last verified active installation is never deleted by journal cleanup.
No checkpoint requires a migration of older installations without a journal.

Configuration is read back through the supported CLI again after an interrupted
transaction, even if its exported JSON appears correct. Activation retains the
provider-verification obligation across an interrupted descriptor/flag update,
including a second interruption during recovery. A completed transaction clears
the marker. These checks add no provider generations, connections, or desktop
actions; ordinary health and provider checks retain their existing authority.

Offline reproduction (from `ProjectFiles`):

```sh
python3 -m unittest discover -s Tests/Python -p test_managed_provisioning.py
```

The fixture uses tiny local archives, injected phase/rename failures, and a
synthetic child process to test the surviving lease. It performs no download,
OpenClaw launch, provider request, or desktop interaction. Live provisioning
crash validation remains incomplete.

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

## Shared descriptor contract

`Contracts/runtime-descriptor.json` defines the existing version-1 wire format:
all required field names and Swift properties, strict 64-bit JSON integers,
nonempty strings, canonical lowercase instance UUIDs, port bounds, the exact
loopback endpoint, and private path/directory rules. Unknown fields remain
forward-compatible; they do not become configuration or execution authority.
Paths must be absolute, contain no parent traversal, and resolve strictly below
the descriptor's parent. Known private directory ancestors may not be symlinks.
Missing leaf files remain structurally valid: installation integrity, private
ownership/permissions, authenticated health, and provider readiness are separate
checks. A malformed descriptor cannot independently pass any of them.

The existing dependency-free generator emits the Swift Codable model and both
validators from that definition. Private directory topology is shared too;
ownership/mode checks and serialized repairs stay in their native implementations.
Duplicate keys, non-UTF-8 JSON, nonfinite values and oversized documents are
rejected before field validation. Errors use fixed field paths and reasons,
without descriptor values. Schema and generator fingerprints are embedded in
both generated artifacts. Descriptor changes also invalidate the existing bundled
contract fingerprint, so mixed components fail the existing startup compatibility
check. No wire field or installed-runtime migration is added.

Regenerate with `python3 Scripts/generate-action-contract.py` from `ProjectFiles`.
Its `--check` mode validates both contracts and rejects stale artifacts without
rewriting them. The shared `Tests/Fixtures/runtime-descriptor-cases.json` exercises
both readers, including exact error paths, optional unknown fields, numeric
coercion, path escapes, missing fields, and directory aliases. Reproduce offline:

```sh
python3 Scripts/generate-action-contract.py --check
python3 -m unittest discover -s Tests/Python -p test_runtime_descriptor.py
swift test --filter 'RuntimeDescriptorTests|ManagedOpenClawTests'
```

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

The private recovery record also carries a versioned boot-session UUID, uptime
restart timestamps and probe deadline, and a paired wall/uptime anchor. On the
same boot, admission and ten-minute expiry use uptime, including after a host
restart. A wall/uptime disagreement greater than five seconds adds a 60-second
probe hold without erasing spent attempts or shortening a later valid circuit.
Reboot, uptime regression, and invalid timing metadata rebase existing spent
attempts into one conservative ten-minute window and replace uncertain deadlines
with a 60-second hold. Repeated refreshes or host restarts on that boot do not
extend the hold. Local probes remain distinct from permission to launch another
Gateway; the three-attempt window still applies. A healthy empty budget gains no
reboot penalty. If the boot UUID cannot be read, a host-local opaque marker makes
cross-host timing uncertain rather than trusting another boot's uptime.

Legacy records still decode their wall fields and optional reservation flag;
their plausible ages/deadlines are translated once, with future or inconsistent
dates taking the conservative path. Changed timing is persisted before launch;
unchanged refreshes do not rewrite the record. Timing metadata contains no task,
provider, credential, command, or response contents. Offline clock fixtures run
with `swift test --filter 'GatewayRecoveryBudgetTests|ManagedOpenClawTests'`.

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

On macOS, preflight also inspects the directory descriptor for extended ACL
entries and access-affecting filesystem flags. Any extended ACL, unsupported ACL
inspection, immutable/append/no-unlink flag, or unrecognized flag is classified as
`private_directory_acl` or `private_directory_flags`. TaskPilot does not remove
ACL entries or clear flags because it cannot prove it created the exact item;
only ordinary mode drift on an identity-checked directory follows the existing
repair path. Hidden and no-dump flags are allowed because they do not grant access
or prevent safe operation.

Offline reproduction (from `ProjectFiles`):

```sh
python3 -m unittest discover -s Tests/Python -p test_managed_openclaw.py
swift test --filter 'TaskTemporaryResourcesTests|ManagedOpenClawTests'
```

## Provisioning disk headroom

The pinned manifest includes versioned conservative space estimates: 128 MiB
for the Node archive, 512 MiB for expanded Node, 512 MiB for package archives,
and 2 GiB for expanded packages. Provisioning adds a 256 MiB temporary-work
allowance and keeps a 512 MiB free-space reserve. Each check uses available
space on the installation volume and counts only remaining allocations:

| Boundary | Required free space |
| --- | --- |
| Before download | 3,968 MiB |
| Before Node extraction | 3,840 MiB |
| Before npm installation | 3,328 MiB |
| Before same-volume promotion | 512 MiB |

Checks run before starting the relevant work. The promotion check also runs
when resuming a sealed stage, before moving an existing installation aside.
An already valid installation bypasses these provisioning checks. Estimates
are not reservations: another application can still consume space afterward,
and ordinary write failures retain their existing handling. The working runtime
and descriptor remain intact on a rejected phase. Early failed stages are
discarded; a verified sealed stage remains resumable after a promotion refusal.

Insufficient capacity reports `local_resource_disk_space`; unavailable capacity
metadata reports `local_resource_disk_space_check`. Swift preserves fixed,
actionable storage explanations during provisioning cooldown and failed repair,
instead of suggesting a credential or network fault. These local conditions
cannot trigger provider capacity retries or model switching. Manifest estimates
participate in the existing bundled installation fingerprint; the previous
verified installation remains available through normal promotion and rollback.

## Unused private instance collection

`managed_profiles.py` records a bounded mode-600 ownership marker only when
TaskPilot creates an exclusive, canonical UUID directory directly under its
private `instances` directory. The marker contains the directory's device/inode,
creation and unreferenced times, and at most 16 process birth identities. Runtime
activation registers the invoking owner under the installation lock. Repeated
registration by the same owner does not rewrite the marker. Untracked legacy
profiles and uncertain or malformed ownership records are never adopted.

The lifecycle host invokes best-effort collection after abandoned-tree drainage
and after its final owned Gateway/output drainage. It never stops a Gateway
for housekeeping. An exclusive native action permit, nonblocking configuration
and installation locks, the inherited provisioning lease, and a Gateway-owner
check prevent collection alongside owned work. Busy locks defer collection;
the helper has a five-second process bound. The scan considers at most 128
directory entries, checks a two-second monotonic work allowance, and removes
at most 512 child entries per pass. It starts no timer, model request, screenshot,
or global search.

Active, verified-working, and previous rollback descriptors protect all their
instance directories. An invalid descriptor aborts collection. Live or uncertain
process identities, including inaccessible birth metadata, retain their instance;
a reused PID alone cannot retain an exited owner. Owner-list overflow permanently
disables collection for that instance rather than forgetting a potentially live
owner. Nonempty or ambiguous workspaces are retained, preserving user outputs.
Shared profiles, installation directories, and paths outside this private UUID
namespace are outside the cleanup routine.

Eligible instances first receive an unreferenced timestamp. Deletion requires
seven days without a descriptor reference or live owner; observing either resets
that grace period. Clock regression restarts the interval. Cleanup opens the
recorded directory without following symlinks, checks identity, and removes
contents relative to retained directory descriptors with per-entry identity
checks. Symlink destinations are never traversed. A nonempty workspace remains
protected even if content arrives during cleanup. Partial bounded passes retain
the marker for another pass; unexpected replacements are left alone. These are
cooperative ownership and race-detection checks, not filesystem-wide exclusion
of unrelated applications. Only aggregate inspected/removed/deferred counts
are returned, without profile names, paths, credentials, or task contents.

Offline reproduction (from `ProjectFiles`):

```sh
python3 -m unittest discover -s Tests/Python -p 'test_managed*.py'
swift test --filter ManagedOpenClawTests
```

Fixtures inject capacity loss at each provisioning boundary, protected descriptors,
corrupt records, PID reuse, a real disposable child owner, directory replacements,
symlinks, concurrent workspace writes, lock contention, and work/grace limits.
They launch no OpenClaw, browser, or desktop task. Live provisioning and profile
retirement validation remain incomplete.

## Runtime, configuration and database checks

The pinned runtime manifest records supported process architectures and the
minimum macOS version for the Node bundle. Before npm begins, provisioning checks
the staged Node Mach-O slices and minimum OS, then executes the pinned Node
binary's version probe under TaskPilot's clean environment. That bounded launch
also verifies the Node binary's required dynamic libraries resolve on the host.
After package installation, a bounded walk inspects Mach-O `.node` modules for
the same architecture and OS compatibility. A failed check leaves the current
installation active; the staged bundle is not promoted.

Audits perform read-only `PRAGMA quick_check(1)` on the known private OpenClaw
databases, with a short SQLite busy timeout, a progress-handler deadline, and
an interrupt timer for statements stalled between virtual-machine steps. The
database's file identity and metadata must still match after inspection.
Locked, inaccessible, replaced, or over-budget checks are reported as
inconclusive and retried; they are not called corruption and do not trigger reconfiguration.
Malformed database files are reported as `database_corrupt`; the host leaves
them unchanged and requires inspection instead of an automatic destructive
repair. Database health diagnostics contain only fixed states and retry timing.

Configuration synchronization computes a nested delta from the known local
configuration and applies only differing TaskPilot-owned leaves through the
supported `config patch --stdin` interface. The model catalog is replaced as an
exact leaf when it differs, which removes retired entries without rewriting
unrelated settings. Repairs read back the managed settings. A state-directory
and configuration-file device/inode fence is captured around each CLI operation
and checked again before publishing the runtime descriptor. A changed identity
stops activation and leaves the prior descriptor in place.

## Gateway lifecycle wakeups

The Gateway host waits for coalesced vnode notifications on its client directory,
health/configuration request files, and runtime descriptor. The supervised
Gateway's parent-exit and complete-tree callbacks signal the same condition.
Unrelated health and process-ledger writes do not wake the host because it
compares only relevant metadata. A five-second bounded timeout remains the
fallback for lost, unsupported, or delayed notifications; health and recovery
budgets are unchanged.

Offline reproduction (from `ProjectFiles`):

```sh
python3 -m unittest Tests.Python.test_managed_provisioning Tests.Python.test_managed_profiles Tests.Python.test_managed_openclaw
swift test --filter ManagedOpenClawTests
```
