#!/bin/bash
set -euo pipefail
# Setup is private and pinned. Key crosses stdin only; no services or shared files.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime="${ORBIT_RUNTIME_CHECK_PATH:-$script_dir/../AgentRuntime/orbit_openclaw_runtime}"
[[ -x "$runtime" ]] || { printf 'ORBIT_SETUP|error|The bundled runtime is missing. Reinstall TaskPilot.\n'; exit 1; }
printf 'ORBIT_SETUP|0.10|Preparing the pinned private OpenClaw installation.\n'
"$runtime" --managed-openclaw ensure --managed-resources "$script_dir/managed" >/dev/null
printf 'ORBIT_SETUP|installed|Private runtime installed. TaskPilot supervises its Gateway while the app is open.\n'
