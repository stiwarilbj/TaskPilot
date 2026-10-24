#!/bin/bash
set -euo pipefail
# Never invoke the shared CLI or install a login service.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf 'TaskPilot manages its private OpenClaw runtime automatically.\nUse TaskPilot Settings to save or verify your Gemini key.\n'
exec /bin/bash "$script_dir/taskpilot-openclaw-bootstrap.sh" </dev/null
