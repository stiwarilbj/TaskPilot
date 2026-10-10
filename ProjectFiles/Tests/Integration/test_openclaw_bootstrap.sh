#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/orbit-openclaw-bootstrap-test.XXXXXX")"
cleanup() {
  rm -rf "$test_directory"
}
trap cleanup EXIT

mkdir -p "$test_directory/home/.openclaw"
touch "$test_directory/home/.openclaw/openclaw.json"
mock_log="$test_directory/openclaw-arguments.log"
mock_openclaw="$test_directory/mock-openclaw.sh"
cp "$root_directory/Tests/Fixtures/mock_openclaw.sh" "$mock_openclaw"
chmod +x "$mock_openclaw"
test_key="AIzaSyOrbitMockGeminiKey1234567890"
mock_runtime="$test_directory/mock-runtime.sh"
cat >"$mock_runtime" <<'PROBE'
#!/bin/bash
IFS= read -r configuration
printf 'runtime-check %s\n' "$*" >>"$ORBIT_MOCK_OPENCLAW_LOG"
[[ "$configuration" == *'"kind":"runtime_configuration"'* ]] || exit 1
key="${configuration##*gemini_api_key\":\"}"
key="${key%%\"*}"
printf 'credential-bytes=%s\n' "${#key}" >>"$ORBIT_MOCK_OPENCLAW_LOG"
if [[ -n "${ORBIT_MOCK_FAIL_MODEL:-}" ]]; then
  printf '{"kind":"model_checks","checks":[{"model":"google/gemini-3.1-flash-lite","state":"verified"}],"prompt_calls":2}\n'
else
  printf '{"kind":"model_checks","checks":[{"model":"google/gemini-3.5-flash-lite","state":"verified"}],"prompt_calls":1}\n'
fi
PROBE
chmod +x "$mock_runtime"

setup_output="$(
  printf '%s\n' "$test_key" | \
    HOME="$test_directory/home" \
    ORBIT_OPENCLAW_PATH="$mock_openclaw" \
    ORBIT_RUNTIME_CHECK_PATH="$mock_runtime" \
    ORBIT_MOCK_OPENCLAW_LOG="$mock_log" \
    /bin/bash "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh"
)"

if /usr/bin/grep -qF "$test_key" "$mock_log"; then
  echo "Gemini key leaked into OpenClaw arguments" >&2
  exit 1
fi

/usr/bin/grep -qF "credential-bytes=${#test_key}" "$mock_log"
/usr/bin/grep -qF "gateway install --force" "$mock_log"
/usr/bin/grep -qF "runtime-check --check-models --openclaw-path $mock_openclaw" "$mock_log"
if /usr/bin/grep -qE "^agent |gemini-probe" "$mock_log"; then
  echo "Setup duplicated generation outside TaskPilot ACP" >&2
  exit 1
fi
/usr/bin/grep -qF "ORBIT_SETUP|1.00|OpenClaw is configured and verified through TaskPilot with image input and JSON output." <<<"$setup_output"

failover_log="$test_directory/failover-openclaw-arguments.log"
failover_output="$(
  printf '%s\n' "$test_key" | \
    HOME="$test_directory/home" \
    ORBIT_OPENCLAW_PATH="$mock_openclaw" \
    ORBIT_RUNTIME_CHECK_PATH="$mock_runtime" \
    ORBIT_MOCK_OPENCLAW_LOG="$failover_log" \
    ORBIT_MOCK_FAIL_MODEL="google/gemini-3.5-flash-lite" \
    /bin/bash "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh"
)"
/usr/bin/grep -qF "runtime-check --check-models" "$failover_log"
if [[ $(/usr/bin/grep -cF "runtime-check" "$failover_log") -ne 1 ]]; then
  echo "Setup repeated the entire runtime check" >&2
  exit 1
fi
/usr/bin/grep -qF "ORBIT_SETUP|1.00|OpenClaw is configured and verified through TaskPilot with image input and JSON output." <<<"$failover_output"
if [[ $(/usr/bin/grep -cF 'gateway install --force' "$failover_log") -ne 1 ]]; then
  echo "Failover reinstalled the Gateway instead of reusing it" >&2
  exit 1
fi

no_key_home="$test_directory/no-key-home"
no_key_log="$test_directory/no-key-openclaw-arguments.log"
mkdir -p "$no_key_home/.openclaw"
touch "$no_key_home/.openclaw/openclaw.json"
set +e
no_key_output="$(
  printf '\n' | \
    HOME="$no_key_home" \
    ORBIT_OPENCLAW_PATH="$mock_openclaw" \
    ORBIT_MOCK_OPENCLAW_LOG="$no_key_log" \
    /bin/bash "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh"
)"
no_key_status=$?
set -e

if [[ $no_key_status -ne 10 ]]; then
  echo "Keyless OpenClaw installation returned $no_key_status instead of 10" >&2
  exit 1
fi
/usr/bin/grep -qF "ORBIT_SETUP|installed|OpenClaw and Node are installed." <<<"$no_key_output"
if /usr/bin/grep -qE 'models auth|models set|gateway install|agent --agent' "$no_key_log"; then
  echo "Keyless OpenClaw installation attempted Gemini or Gateway configuration" >&2
  exit 1
fi

echo "OpenClaw bootstrap mock integration passed"
