#!/bin/bash
set -euo pipefail
root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/taskpilot-private-setup.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
cat > "$test_directory/runtime" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$1" == --managed-openclaw && "$2" == ensure && "$3" == --managed-resources ]]
IFS= read -r key || true
[[ "$key" == 'fixture-private-key' ]]
printf 'private-ensure\n' > "$TASKPILOT_FIXTURE_LOG"
MOCK
chmod +x "$test_directory/runtime"
output="$(printf 'fixture-private-key\n' | ORBIT_RUNTIME_CHECK_PATH="$test_directory/runtime" TASKPILOT_FIXTURE_LOG="$test_directory/log" /bin/bash "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh")"
[[ "$(cat "$test_directory/log")" == private-ensure ]]
[[ "$output" == *'ORBIT_SETUP|installed|'* ]]
[[ "$output" != *'fixture-private-key'* ]]
if rg -n 'gateway (install|restart)|doctor|brew|version latest|\.openclaw/' "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh" "$root_directory/Resources/OpenClaw/openclaw-setup.command"; then
  echo 'Setup touched shared OpenClaw or an unpinned installer' >&2; exit 1
fi
printf 'Private setup integration passed (no services, shared CLI, or generation).\n'
