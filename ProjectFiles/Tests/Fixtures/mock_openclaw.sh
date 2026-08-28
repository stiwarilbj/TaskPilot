#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$ORBIT_MOCK_OPENCLAW_LOG"
if [[ "${1:-}" == "models" && "${2:-}" == "auth" ]]; then
  mock_key=""
  IFS= read -r mock_key
  printf 'credential-bytes=%s\n' "${#mock_key}" >>"$ORBIT_MOCK_OPENCLAW_LOG"
fi
if [[ "${1:-}" == "agent" ]]; then
  printf '{"reply":"ORBIT_OPENCLAW_READY"}\n'
else
  printf '{}\n'
fi
