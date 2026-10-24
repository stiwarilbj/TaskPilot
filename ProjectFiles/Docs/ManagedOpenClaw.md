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
reconnect. Receipt reconciliation still owns dispatched desktop mutations;
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

Validation for this change: 753 Python tests and 582 Swift tests (one skipped),
mock setup integration, generated-contract checks, signed bundle verification,
and headless ACP image/JSON verification. The healthy probe succeeded on
3.5 Flash-Lite with one generation, zero repairs, and no model fallback.
The last headless client released its lease and its Gateway tree drained.
No fixer, Chrome interaction, live-control tester, or desktop task was run.
